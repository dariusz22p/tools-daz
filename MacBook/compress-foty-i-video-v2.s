
#!/usr/bin/env bash

# Script metadata
SCRIPT_URL="https://raw.githubusercontent.com/dariusz22p/tools-daz/main/MacBook/compress-foty-i-video-v2.s"
SCRIPT_NAME="compress-foty-i-video-v2.s"
SCRIPT_VERSION="2.1.0"  # Update this when making changes

# Auto-update: Try to pull latest version from GitHub
auto_update() {
  local temp_script
  temp_script=$(mktemp)
  
  echo "🔍 Checking for updates..." >&2
  echo "   Local version: $SCRIPT_VERSION" >&2
  echo "   Running from: $0" >&2
  echo "   Checking: $SCRIPT_URL" >&2
  
  # Try to download latest version
  if curl -fsSL --connect-timeout 5 "$SCRIPT_URL" -o "$temp_script" 2>/dev/null; then
    echo "   ✓ Successfully connected to GitHub" >&2
    
    # Verify it's a valid bash script (check shebang and that it's not HTML)
    if head -1 "$temp_script" | grep -q '^#!/' && ! grep -q '<html\|<HTML\|<!DOCTYPE' "$temp_script" 2>/dev/null; then
      echo "   ✓ Downloaded valid script" >&2
      
      # Extract remote version
      local remote_version
      remote_version=$(grep -m1 '^SCRIPT_VERSION=' "$temp_script" | cut -d'"' -f2 || echo "unknown")
      echo "   Remote version: $remote_version" >&2
      
      # Check if there are actual changes
      if ! diff -q "$0" "$temp_script" >/dev/null 2>&1; then
        echo "   📥 New version available! Updating..." >&2
        chmod +x "$temp_script"
        mv "$temp_script" "$0"
        echo "   ✅ Updated from $SCRIPT_VERSION to $remote_version" >&2
        echo "   🔄 Restarting with new version..." >&2
        echo "" >&2
        exec "$0" "$@"
      else
        echo "   ✅ Already running latest version ($SCRIPT_VERSION)" >&2
        rm -f "$temp_script"
      fi
    else
      echo "   ⚠️  Downloaded file is not a valid script (likely HTML error page)" >&2
      rm -f "$temp_script"
    fi
  else
    echo "   ✗ Cannot connect to GitHub (offline or connection failed)" >&2
    
    # No internet or download failed - install to user bin if not already there
    local user_bin="$HOME/bin"
    local installed_path="$user_bin/$SCRIPT_NAME"
    
    if [[ ! -f "$installed_path" || "$0" != "$installed_path" ]]; then
      echo "   📁 Installing current version to $user_bin/" >&2
      
      # Create bin directory if it doesn't exist
      mkdir -p "$user_bin"
      
      # Copy script to bin
      cp "$0" "$installed_path"
      chmod +x "$installed_path"
      
      echo "   ✅ Script installed to $installed_path" >&2
      
      # Check if bin is in PATH
      if [[ ":$PATH:" != *":$user_bin:"* ]]; then
        echo "" >&2
        echo "   ⚠️  Note: $user_bin is not in your PATH" >&2
        echo "      Add this line to your ~/.zshrc or ~/.bash_profile:" >&2
        echo "      export PATH=\"\$HOME/bin:\$PATH\"" >&2
        echo "" >&2
      fi
      
      # If we just installed it and we're not running from there, switch to installed version
      if [[ "$0" != "$installed_path" ]]; then
        echo "   🔄 Switching to installed version..." >&2
        exec "$installed_path" "$@"
      fi
    else
      echo "   ✓ Script already installed in $user_bin/" >&2
    fi
    rm -f "$temp_script"
  fi
  echo "" >&2
}

# Run auto-update unless explicitly disabled
if [[ "${SKIP_AUTO_UPDATE:-}" != "1" ]]; then
  auto_update "$@"
fi

# Auto-upgrade to a modern bash if available (macOS ships 3.2 in /bin/bash)
if [[ -z "$BASH_VERSION" || ${BASH_VERSINFO[0]:-0} -lt 4 ]]; then
  for cand in /usr/local/bin/bash /opt/homebrew/bin/bash; do
    if [[ -x $cand ]]; then
      exec "$cand" "$0" "$@"
    fi
  done
  echo "ERROR: Need bash >=4. Install with: brew install bash" >&2
  echo "Then re-run: /usr/local/bin/bash $0 [options]" >&2
  exit 3
fi

dry_run=false
jobs=$(sysctl -n hw.ncpu 2>/dev/null || echo 4)
jobs=$(( jobs>0 ? jobs : 4 ))
quiet_ffmpeg=true
recursive=false
force=false
show_skip_messages=true
terse=false
progress_style="pct" # future: could allow different styles
start_time=$(date +%s)
original_start_time=$start_time
completed_count=0
completed_images=0
completed_videos=0
interleaved=false
color_enabled=false
ema_overall=0
ema_img=0
ema_vid=0
ema_alpha=0.2       # smoothing factor for EMA
eta_suppress_sec=1  # dynamic: only hide if elapsed <1s
eta_min_items=0     # no item-count threshold now
eta_force=false
eta_job_threshold=3  # only print ETA parts on DONE lines if job runtime >3s (unless --eta-always)

quarantine_dir=""          # directory where originals are moved instead of deletion
planned_process_bytes=0     # total bytes of originals that will be processed (for naming)
quarantine_prefix="to-be-deleted"  # default prefix, overridable via --quarantine-prefix
finalize_dir=""

# Enable color by default if stdout is a TTY
if [[ -t 1 ]]; then
  color_enabled=true
fi

format_duration() {
  local seconds="$1" h m s
  (( seconds < 0 )) && seconds=0
  h=$(( seconds/3600 ))
  m=$(( (seconds%3600)/60 ))
  s=$(( seconds%60 ))
  printf '%02d:%02d:%02d' "$h" "$m" "$s"
}

human_size() {
  local bytes=$1
  awk -v b="$bytes" 'function human(x){
    s[0]="B";s[1]="K";s[2]="M";s[3]="G";s[4]="T";s[5]="P";s[6]="E";s[7]="Z";s[8]="Y";
    i=0;while(x>=1024 && i<8){x/=1024;i++}; printf("%.2f%s", x, s[i]);
  } BEGIN{ if(b+0<0){b=0}; human(b) }'
}

update_ema() {
  local current="$1" prev="$2"
  awk -v c="$current" -v p="$prev" -v a="$ema_alpha" 'BEGIN{ if(p==0){print c}else{printf "%f", (a*c)+((1-a)*p)} }'
}

compute_eta() {
  local kind="$1" done="$2" total="$3" # kind: overall|img|vid
  local now elapsed remaining avg_per
  now=$(date +%s)
  elapsed=$(( now - start_time ))
  # Sanitize numeric inputs (strip non-digits & quotes)
  done=${done//[^0-9]/}
  total=${total//[^0-9]/}
  if [[ -z "$done" || -z "$total" ]]; then
    echo "ETA: --"
    return
  fi
  if ! $eta_force && (( elapsed < eta_suppress_sec )); then
    echo "ETA: --"
    return
  fi
  case "$kind" in
    img) avg_per="$ema_img" ;;
    vid) avg_per="$ema_vid" ;;
    *)   avg_per="$ema_overall" ;;
  esac
  if awk -v v="$avg_per" 'BEGIN{exit (v>0)?0:1}'; then :; else
    avg_per=$(awk -v e="$elapsed" -v d="$done" 'BEGIN{ if(d==0) print 0; else printf "%f", e/d }')
  fi
  remaining=$(awk -v a="$avg_per" -v t="$total" -v d="$done" 'BEGIN{ printf "%d", (t-d)*a }')
  printf 'ETA: %s' "$(format_duration "$remaining")"
}

show_help() {
  cat <<EOF
Usage: $0 [options]

Options:
  -d, --dry-run          Show what would be processed without modifying files
  -j, --jobs N           Number of parallel jobs (default: detected CPU count: $jobs)
  -r, --recursive        Recurse into subdirectories
  -f, --force            Recompress even if *_compressed output already exists
      --no-skip-messages Suppress reporting of skipped files (still counted in summary)
      --no-quiet-ffmpeg  Show ffmpeg output (progress/stats)
      --interleaved      Interleave image & video processing (old behavior)
      --eta-always       Show ETA immediately (disable <1s suppression)
    --color            Force ANSI color output (on by default if TTY)
    --no-color         Disable ANSI color output
    --terse            Minimal output (no START lines, only DONE/ERROR + skips if enabled)
      --delete-originals  Permanently delete originals after successful compression (default: move to quarantine dir)
      --quarantine-prefix NAME  Use custom prefix instead of 'to-be-deleted' for quarantine directory
      --finalize DIR      Delete a quarantine directory (DIR) safely, then exit (no processing)
  -h, --help             Show this help

Notes:
  Parallel mode launches background jobs; summary waits for all to finish.
  HEIC/HEIF images converted to JPEG with _compressed suffix.
  Videos re-encoded with libx265 (CRF 28, medium preset, AAC 128k).
  Default is non-recursive; use -r to include subdirectories.
  ETA uses an exponential moving average (EMA) per media type and overall.
  ETA printed on DONE lines only if that job took >3s, or always with --eta-always (which disables suppression & threshold).
EOF
}

require_tool() {
  local name="$1" hint="$2"
  if ! command -v "$name" >/dev/null 2>&1; then
    echo "Missing required dependency: $name" >&2
    [[ -n "$hint" ]] && echo "  Install: $hint" >&2
    return 1
  fi
  return 0
}

check_dependencies() {
  local ok=true
  # ImageMagick can be 'magick' (new) or 'convert' (older). Need at least one.
  if ! command -v magick >/dev/null 2>&1; then
    if ! command -v convert >/dev/null 2>&1; then
      echo "Missing ImageMagick (magick/convert)." >&2
      echo "  Install (macOS with Homebrew): brew install imagemagick" >&2
      ok=false
    else
      # Fallback to convert if magick absent
      magick() { command convert "$@"; }
    fi
  fi
  require_tool ffmpeg "brew install ffmpeg" || ok=false
  if [[ $ok == false ]]; then
    echo "One or more required tools are missing. Aborting." >&2
    exit 2
  fi
}

check_dependencies

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    -d|--dry-run) dry_run=true; shift ;;
    -j|--jobs)
      shift
      [[ -n "$1" && "$1" =~ ^[0-9]+$ ]] || { echo "Error: --jobs requires numeric value" >&2; exit 1; }
      jobs=$1; shift ;;
    -r|--recursive) recursive=true; shift ;;
    -f|--force) force=true; shift ;;
    --no-skip-messages) show_skip_messages=false; shift ;;
    --no-quiet-ffmpeg) quiet_ffmpeg=false; shift ;;
    --interleaved) interleaved=true; shift ;;
  --color) color_enabled=true; shift ;;
  --no-color) color_enabled=false; shift ;;
  --terse) terse=true; shift ;;
  --eta-always) eta_force=true; eta_suppress_sec=0; eta_min_items=0; eta_job_threshold=0; shift ;;
    --delete-originals) delete_originals=true; shift ;;
    --quarantine-prefix)
      shift
      [[ -n "$1" ]] || { echo "Error: --quarantine-prefix requires a value" >&2; exit 1; }
      quarantine_prefix="$1"; shift ;;
    --finalize)
      shift
      [[ -n "$1" ]] || { echo "Error: --finalize requires a directory argument" >&2; exit 1; }
      finalize_dir="$1"; shift ;;
    -h|--help) show_help; exit 0 ;;
    *) echo "Unknown option: $1" >&2; show_help; exit 1 ;;
  esac
done

if $recursive; then
  shopt -s globstar nullglob
else
  shopt -s nullglob
fi

# Color codes
if $color_enabled; then
  BOLD=$'\e[1m'; DIM=$'\e[2m'; RED=$'\e[31m'; GREEN=$'\e[32m'; YELLOW=$'\e[33m'; BLUE=$'\e[34m'; MAGENTA=$'\e[35m'; CYAN=$'\e[36m'; RESET=$'\e[0m'
else
  BOLD=""; DIM=""; RED=""; GREEN=""; YELLOW=""; BLUE=""; MAGENTA=""; CYAN=""; RESET=""
fi

# finalize helper: if --finalize provided, safely delete dir then exit
if [[ -n "$finalize_dir" ]]; then
  # Safety checks
  if [[ ! -d "$finalize_dir" ]]; then
    echo "Finalize error: '$finalize_dir' is not a directory" >&2; exit 1;
  fi
  case "$finalize_dir" in
    */*|*..*) echo "Finalize error: directory must be a simple name in current directory" >&2; exit 1;;
  esac
  if [[ ! "$finalize_dir" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "Finalize error: directory name contains unsafe characters" >&2; exit 1;
  fi
  # Extra safeguard: must start with default or custom quarantine prefix
  if [[ "$finalize_dir" != ${quarantine_prefix}-* && "$finalize_dir" != to-be-deleted-* ]]; then
    echo "Finalize error: '$finalize_dir' does not look like a quarantine directory" >&2; exit 1;
  fi
  echo "Deleting quarantine directory '$finalize_dir'..."
  rm -rf -- "$finalize_dir" || { echo "Failed to delete '$finalize_dir'" >&2; exit 1; }
  echo "Done."; exit 0
fi

search_pattern_image() {
  local ext="$1"
  if $recursive; then
    echo **/*.${ext}
  else
    echo *.${ext}
  fi
}

search_pattern_video() {
  local ext="$1"
  if $recursive; then
    echo **/*.${ext}
  else
    echo *.${ext}
  fi
}

# All common image formats
image_exts=(
  "jpg" "JPG" "jpeg" "JPEG"
  "png" "PNG"
  "gif" "GIF"
  "bmp" "BMP"
  "tiff" "TIFF" "tif" "TIF"
  "heic" "HEIC" "heif" "HEIF"
  "webp" "WEBP"
  "svg" "SVG"
  "ico" "ICO"
  "psd" "PSD"
  "raw" "RAW" "cr2" "CR2" "nef" "NEF" "arw" "ARW" "dng" "DNG"
  "exr" "EXR"
  "jp2" "JP2" "j2k" "J2K"
  "jxr" "JXR"
  "avif" "AVIF"
)
video_exts=("mp4" "MP4" "mkv" "MKV" "mov" "MOV" "avi" "AVI" "flv" "FLV" "wmv" "WMV" "webm" "WEBM" "mpg" "MPG" "mpeg" "MPEG")

processed_images=()
processed_videos=()
orig_sizes=()
comp_sizes=()

# Graceful interrupt tracking
interrupted=false
handle_interrupt() {
  echo "\nInterrupt received. Finishing in-flight jobs..." >&2
  interrupted=true
  # Stop launching new jobs; just wait for current to finish
  wait_all_jobs
  print_summary
  exit 130
}
trap handle_interrupt INT TERM

# Temp workspace
tmp_dir=$(mktemp -d -t compress_parallel_XXXX)
trap 'rm -rf "$tmp_dir"' EXIT INT TERM

img_list="$tmp_dir/images.txt"
vid_list="$tmp_dir/videos.txt"
size_orig="$tmp_dir/orig_sizes.txt"
size_comp="$tmp_dir/comp_sizes.txt"
skipped_img_file="$tmp_dir/skipped_images.txt"
skipped_vid_file="$tmp_dir/skipped_videos.txt"
forced_img_file="$tmp_dir/forced_images.txt"
forced_vid_file="$tmp_dir/forced_videos.txt"
mkdir -p "$tmp_dir"
# Ensure files exist to avoid mapfile errors in dry-run mode
> "$img_list"; > "$vid_list"; > "$size_orig"; > "$size_comp"; > "$skipped_img_file"; > "$skipped_vid_file"; > "$forced_img_file"; > "$forced_vid_file"

job_pids=()

enqueue_job() {
  # Limit number of concurrent jobs
  while (( ${#job_pids[@]} >= jobs )); do
    for i in "${!job_pids[@]}"; do
      if ! kill -0 "${job_pids[i]}" 2>/dev/null; then
        unset 'job_pids[i]'
      fi
    done
    job_pids=("${job_pids[@]}")
    sleep 0.2
  done
  "$@" &
  job_pids+=("$!")
}

wait_all_jobs() {
  for pid in "${job_pids[@]}"; do
    wait "$pid" 2>/dev/null
  done
  job_pids=()
}

record_stats() {
  local orig="$1" comp="$2" type="$3"
  local orig_size comp_size
  orig_size=$(stat -f "%z" "$orig" 2>/dev/null || echo 0)
  comp_size=$(stat -f "%z" "$comp" 2>/dev/null || echo 0)
  [[ -f "$comp" ]] || return 0
  if [[ "$type" == image ]]; then
    printf '%s\n' "$orig" >> "$img_list"
  else
    printf '%s\n' "$orig" >> "$vid_list"
  fi
  printf '%s\n' "$orig_size" >> "$size_orig"
  printf '%s\n' "$comp_size" >> "$size_comp"
}

process_image() {
  local idx="$1" total="$2" file="$3"
  local op_start=$(date +%s)
  local pct
  if (( total > 0 )); then
    pct=$(awk -v i="$idx" -v t="$total" 'BEGIN{printf "%5.1f", (i*100)/t}')
  else
    pct="  0.0"
  fi
  local output="${file%.*}_compressed.jpg"
  
  # Check if file exists
  if [[ ! -f "$file" ]]; then
    $show_skip_messages && printf '%b\n' "${DIM}IMG $idx/$total (${pct}%): SKIP  $file (file not found)${RESET}"
    return 0
  fi
  
  # Skip already compressed files
  if [[ "$file" == *_compressed.jpg ]]; then
    $show_skip_messages && printf '%b\n' "${DIM}IMG $idx/$total (${pct}%): SKIP  $file (already compressed)${RESET}"
    return 0
  fi
  
  # Skip if output exists and not forcing
  if [[ -f "$output" && $force == false ]]; then
    echo "$file" >> "$skipped_img_file"
    $show_skip_messages && printf '%b\n' "${DIM}IMG $idx/$total (${pct}%): SKIP  $file (output exists, use -f to force)${RESET}"
    return 0
  fi
  if $dry_run; then
    if [[ -f "$output" && $force == true ]]; then
  printf '%b\n' "${CYAN}IMG $idx/$total (${pct}%): DRY-RUN FORCE $file -> $output${RESET}"
    else
  printf '%b\n' "${CYAN}IMG $idx/$total (${pct}%): DRY-RUN $file -> $output${RESET}"
    fi
    return 0
  fi
  if [[ -f "$output" && $force == true ]]; then
    echo "$file" >> "$forced_img_file"
  printf '%b\n' "${MAGENTA}IMG $idx/$total (${pct}%): FORCE removing existing output: $output${RESET}"
    rm -f "$output"
  fi
  if ! $terse; then
    printf '%b\n' "${YELLOW}IMG $idx/$total (${pct}%): START $file -> $output${RESET}"
  fi
  local timestamp orig_size
  timestamp=$(stat -f '%m' "$file" 2>/dev/null)
  orig_size=$(stat -f '%z' "$file" 2>/dev/null)
  if magick "$file" -strip -interlace Plane -gaussian-blur 0.05 -quality 85 "$output"; then
    [[ -n "$timestamp" && -f "$output" ]] && touch -t "$(date -r "$timestamp" '+%Y%m%d%H%M.%S')" "$output"
    out_size=$(stat -f '%z' "$output" 2>/dev/null || echo 0)
    if (( out_size <= 0 )); then
      printf '%b\n' "${RED}IMG $idx/$total (${pct}%): ERROR zero-size output, keeping original${RESET}"
      [[ -f "$output" ]] && rm -f "$output" 2>/dev/null
      return 1
    fi
    # Record stats only after integrity check
    record_stats "$file" "$output" image
    completed_count=$((completed_count+1))
    completed_images=$((completed_images+1))
    now_ts=$(date +%s); elapsed=$(( now_ts - start_time ))
    current_avg_overall=$(awk -v e="$elapsed" -v d="$completed_count" 'BEGIN{ if(d==0) print 0; else printf "%f", e/d }')
    current_avg_img=$(awk -v e="$elapsed" -v d="$completed_images" 'BEGIN{ if(d==0) print 0; else printf "%f", e/d }')
    ema_overall=$(update_ema "$current_avg_overall" "$ema_overall")
    ema_img=$(update_ema "$current_avg_img" "$ema_img")
    job_elapsed=$(( $(date +%s) - op_start ))
    action_note=""
    if $delete_originals; then
      action_note="deleting original"
    else
      if [[ -n "$quarantine_dir" ]]; then
        if move_err=$(mv -- "$file" "$quarantine_dir/" 2>&1); then :; else action_note="MOVE-ERROR($move_err)"; fi
        action_note="moved original -> $quarantine_dir"
      else
        action_note="original retained"
      fi
    fi
    if $eta_force || (( job_elapsed > eta_job_threshold )); then
  printf '%b\n' "${GREEN}IMG $idx/$total (${pct}%): DONE  $output (${action_note}) $(compute_eta img $completed_images $total_images) | Overall $(compute_eta overall $completed_count $total_overall_denominator)${RESET}"
    else
  printf '%b\n' "${GREEN}IMG $idx/$total (${pct}%): DONE  $output (${action_note})${RESET}"
    fi
  else
  printf '%b\n' "${RED}IMG $idx/$total (${pct}%): ERROR failed to compress $file${RESET}"
    [[ -f "$output" ]] && rm -f "$output" 2>/dev/null
  fi
}

process_video() {
  local idx="$1" total="$2" file="$3"
  local op_start=$(date +%s)
  local pct
  if (( total > 0 )); then
    pct=$(awk -v i="$idx" -v t="$total" 'BEGIN{printf "%5.1f", (i*100)/t}')
  else
    pct="  0.0"
  fi
  local out_vid="${file%.*}_compressed.mp4"
  
  # Check if file exists
  if [[ ! -f "$file" ]]; then
    $show_skip_messages && printf '%b\n' "${DIM}VID $idx/$total (${pct}%): SKIP  $file (file not found)${RESET}"
    return 0
  fi
  
  # Skip already compressed videos
  if [[ "$file" == *_compressed.mp4 ]]; then
    $show_skip_messages && printf '%b\n' "${DIM}VID $idx/$total (${pct}%): SKIP  $file (already compressed)${RESET}"
    return 0
  fi
  
  # Skip if output exists and not forcing
  if [[ -f "$out_vid" && $force == false ]]; then
    echo "$file" >> "$skipped_vid_file"
    $show_skip_messages && printf '%b\n' "${DIM}VID $idx/$total (${pct}%): SKIP  $file (output exists, use -f to force)${RESET}"
    return 0
  fi
  if $dry_run; then
    if [[ -f "$out_vid" && $force == true ]]; then
  printf '%b\n' "${CYAN}VID $idx/$total (${pct}%): DRY-RUN FORCE $file -> $out_vid${RESET}"
    else
  printf '%b\n' "${CYAN}VID $idx/$total (${pct}%): DRY-RUN $file -> $out_vid${RESET}"
    fi
    return 0
  fi
  if [[ -f "$out_vid" && $force == true ]]; then
    echo "$file" >> "$forced_vid_file"
  printf '%b\n' "${MAGENTA}VID $idx/$total (${pct}%): FORCE removing existing output: $out_vid${RESET}"
    rm -f "$out_vid"
  fi
  if ! $terse; then
    printf '%b\n' "${YELLOW}VID $idx/$total (${pct}%): START $file -> $out_vid${RESET}"
  fi
  local timestamp orig_size
  timestamp=$(stat -f '%m' "$file" 2>/dev/null)
  orig_size=$(stat -f '%z' "$file" 2>/dev/null)
  if $quiet_ffmpeg; then
    ffmpeg -loglevel error -i "$file" -c:v libx265 -crf 28 -preset medium -c:a aac -b:a 128k "$out_vid" -y >/dev/null 2>&1
  else
    ffmpeg -i "$file" -c:v libx265 -crf 28 -preset medium -c:a aac -b:a 128k "$out_vid" -y
  fi
  if [[ -f "$out_vid" ]]; then
    [[ -n "$timestamp" ]] && touch -t "$(date -r "$timestamp" '+%Y%m%d%H%M.%S')" "$out_vid"
    out_size=$(stat -f '%z' "$out_vid" 2>/dev/null || echo 0)
    if (( out_size <= 0 )); then
      printf '%b\n' "${RED}VID $idx/$total (${pct}%): ERROR zero-size output, keeping original${RESET}"
      rm -f "$out_vid" 2>/dev/null
      return 1
    fi
    record_stats "$file" "$out_vid" video
    completed_count=$((completed_count+1))
    completed_videos=$((completed_videos+1))
    now_ts=$(date +%s); elapsed=$(( now_ts - start_time ))
    current_avg_overall=$(awk -v e="$elapsed" -v d="$completed_count" 'BEGIN{ if(d==0) print 0; else printf "%f", e/d }')
    current_avg_vid=$(awk -v e="$elapsed" -v d="$completed_videos" 'BEGIN{ if(d==0) print 0; else printf "%f", e/d }')
    ema_overall=$(update_ema "$current_avg_overall" "$ema_overall")
    ema_vid=$(update_ema "$current_avg_vid" "$ema_vid")
    job_elapsed=$(( $(date +%s) - op_start ))
    action_note=""
    if $delete_originals; then
      action_note="deleting original"
    else
      if [[ -n "$quarantine_dir" ]]; then
        if move_err=$(mv -- "$file" "$quarantine_dir/" 2>&1); then :; else action_note="MOVE-ERROR($move_err)"; fi
        action_note="moved original -> $quarantine_dir"
      else
        action_note="original retained"
      fi
    fi
    if $eta_force || (( job_elapsed > eta_job_threshold )); then
  printf '%b\n' "${GREEN}VID $idx/$total (${pct}%): DONE  $out_vid (${action_note}) $(compute_eta vid $completed_videos $total_videos) | Overall $(compute_eta overall $completed_count $total_overall_denominator)${RESET}"
    else
  printf '%b\n' "${GREEN}VID $idx/$total (${pct}%): DONE  $out_vid (${action_note})${RESET}"
    fi
  else
  printf '%b\n' "${RED}VID $idx/$total (${pct}%): ERROR failed to compress $file${RESET}"
    [[ -f "$out_vid" ]] && rm -f "$out_vid" 2>/dev/null
  fi
}

declare -a image_candidates=()
declare -a video_candidates=()
declare -A seen_image
declare -A seen_video

# Collect image candidates
for ext in "${image_exts[@]}"; do
  for file in $(search_pattern_image "$ext"); do
    [ -f "$file" ] || continue
    [[ "$file" == *_compressed.jpg ]] && continue
    [[ -n "${seen_image[$file]}" ]] && continue
    seen_image[$file]=1
    # Check if ImageMagick can handle this format
    if ! magick identify -- "$file" >/dev/null 2>&1; then
      $show_skip_messages && printf '%b\n' "${YELLOW}WARN: Cannot identify image format for $file (unsupported or corrupt)${RESET}"
      continue
    fi
    image_candidates+=("$file")
  done
done

# Collect video candidates
for ext in "${video_exts[@]}"; do
  for file in $(search_pattern_video "$ext"); do
    [ -f "$file" ] || continue
    [[ "$file" == *_compressed.mp4 ]] && continue
    [[ -n "${seen_video[$file]}" ]] && continue
    seen_video[$file]=1
    # Check if ffmpeg can handle this format
    if ! ffmpeg -v error -i -- "$file" -f null - >/dev/null 2>&1; then
      $show_skip_messages && printf '%b\n' "${YELLOW}WARN: Cannot read video format for $file (unsupported or corrupt)${RESET}"
      continue
    fi
    video_candidates+=("$file")
  done
done

total_images=${#image_candidates[@]}
total_videos=${#video_candidates[@]}
total_overall_denominator=$(( total_images + total_videos ))

# Determine total size & create quarantine dir (performed after enumeration now)
delete_originals=${delete_originals:-false}
if ! $dry_run; then
  planned_process_bytes=0
  for f in "${image_candidates[@]}"; do
    [ -f "$f" ] || continue
    out="${f%.*}_compressed.jpg"
    if [[ -f "$out" && $force == false ]]; then continue; fi
    sz=$(stat -f '%z' "$f" 2>/dev/null || echo 0)
    planned_process_bytes=$(( planned_process_bytes + sz ))
  done
  for f in "${video_candidates[@]}"; do
    [ -f "$f" ] || continue
    out="${f%.*}_compressed.mp4"
    if [[ -f "$out" && $force == false ]]; then continue; fi
    sz=$(stat -f '%z' "$f" 2>/dev/null || echo 0)
    planned_process_bytes=$(( planned_process_bytes + sz ))
  done
  if ! $delete_originals && (( planned_process_bytes > 0 )); then
    stamp=$(date +%Y%m%d)
    quarantine_dir="${quarantine_prefix}-${stamp}-${planned_process_bytes}"
    mkdir -p -- "$quarantine_dir" 2>/dev/null || quarantine_dir=""
  fi
fi

if $dry_run; then
  echo "Discovered $total_images image(s) and $total_videos video(s)."
fi

if $interleaved; then
  printf '%b\n' "${BOLD}${CYAN}--- Phase: Images & Videos (interleaved) ---${RESET}"
  for i in "${!image_candidates[@]}"; do
    idx=$(( i + 1 ))
    enqueue_job process_image "$idx" "$total_images" "${image_candidates[i]}"
  done
  for i in "${!video_candidates[@]}"; do
    idx=$(( i + 1 ))
    enqueue_job process_video "$idx" "$total_videos" "${video_candidates[i]}"
  done
  wait_all_jobs
else
  printf '%b\n' "${BOLD}${CYAN}--- Phase 1/2: Images ---${RESET}"
  for i in "${!image_candidates[@]}"; do
    idx=$(( i + 1 ))
    enqueue_job process_image "$idx" "$total_images" "${image_candidates[i]}"
  done
  wait_all_jobs

  printf '%b\n' "${BOLD}${CYAN}--- Phase 2/2: Videos ---${RESET}"
  # Reset ETA baseline for video phase (so video time estimates are not biased by faster image ops)
  # Keep cumulative image counters; only zero per-phase overall counters. If this causes confusion
  # (ETA showing as -- for much of video phase), use --eta-always to force immediate display.
  start_time=$(date +%s)
  completed_count=0
  ema_overall=0; ema_vid=0; ema_img=0
  total_overall_denominator=$total_videos
  for i in "${!video_candidates[@]}"; do
    idx=$(( i + 1 ))
    enqueue_job process_video "$idx" "$total_videos" "${video_candidates[i]}"
  done
  wait_all_jobs
fi

print_summary() {
  # Aggregate stats from temp files (idempotent)
  mapfile -t processed_images < <(sort -u "$img_list" 2>/dev/null || true)
  mapfile -t processed_videos < <(sort -u "$vid_list" 2>/dev/null || true)
  mapfile -t orig_sizes < "$size_orig" 2>/dev/null || true
  mapfile -t comp_sizes < "$size_comp" 2>/dev/null || true
  mapfile -t skipped_imgs < <(sort -u "$skipped_img_file" 2>/dev/null || true)
  mapfile -t skipped_vids < <(sort -u "$skipped_vid_file" 2>/dev/null || true)
  mapfile -t forced_imgs < <(sort -u "$forced_img_file" 2>/dev/null || true)
  mapfile -t forced_vids < <(sort -u "$forced_vid_file" 2>/dev/null || true)

  printf '%b\n' "\n${BOLD}--- Summary ---${RESET}"
  (( ${#processed_images[@]} )) && {
    echo "Images processed:"; for img in "${processed_images[@]}"; do echo "  $img"; done
  }
  (( ${#processed_videos[@]} )) && {
    echo "Videos processed:"; for vid in "${processed_videos[@]}"; do echo "  $vid"; done
  }

  # Counts line
  local img_proc vid_proc img_skip vid_skip img_force vid_force
  img_proc=${#processed_images[@]}; vid_proc=${#processed_videos[@]}
  img_skip=${#skipped_imgs[@]}; vid_skip=${#skipped_vids[@]}
  img_force=${#forced_imgs[@]}; vid_force=${#forced_vids[@]}
  if (( img_proc || vid_proc || img_skip || vid_skip || img_force || vid_force )); then
    echo "Counts:"
    printf '  Images: processed=%d forced=%d skipped=%d\n' "$img_proc" "$img_force" "$img_skip"
    printf '  Videos: processed=%d forced=%d skipped=%d\n' "$vid_proc" "$vid_force" "$vid_skip"
  fi

  if (( ${#orig_sizes[@]} )); then
    total_orig=0; total_comp=0
    for i in "${!orig_sizes[@]}"; do
      total_orig=$((total_orig + orig_sizes[i]))
      total_comp=$((total_comp + comp_sizes[i]))
    done
    if (( total_orig > 0 )); then
      ratio=$(awk "BEGIN {printf \"%.2f\", $total_comp/$total_orig}")
      saved=$(( total_orig - total_comp ))
      saved_pct=$(awk -v s="$saved" -v o="$total_orig" 'BEGIN{ if(o==0) printf "0"; else printf "%.2f", (s*100)/o }')
      echo "Total original size: $total_orig bytes ($(human_size $total_orig))"
      echo "Total compressed size: $total_comp bytes ($(human_size $total_comp))"
      echo "Space saved: $saved bytes ($(human_size $saved)) (${saved_pct}% reduction)"
      echo "Compression ratio (compressed/original): $ratio"
    fi
  fi

  if (( ! ${#processed_images[@]} && ! ${#processed_videos[@]} )); then
    if (( img_skip || vid_skip )); then
      echo "No new files processed (all were skipped)."
    else
      echo "No files were processed. Current directory content:"
      ls -l
    fi
  fi
  # Total elapsed time
  end_ts=$(date +%s)
  total_elapsed=$(( end_ts - original_start_time ))
  echo "Elapsed time: $(format_duration "$total_elapsed")"
  if [[ -n "$quarantine_dir" && -d "$quarantine_dir" && ! $delete_originals ]]; then
    qcount=$(find "$quarantine_dir" -type f 2>/dev/null | wc -l | tr -d ' ')
    qsize=$(du -sk "$quarantine_dir" 2>/dev/null | awk '{print $1*1024}')
    echo "Quarantined originals: $qcount file(s) in $quarantine_dir (approx $(human_size $qsize))"
  fi
    if (( completed_count > 0 && total_elapsed > 0 )); then
      tp=$(awk -v c="$completed_count" -v e="$total_elapsed" 'BEGIN{ if(e==0) print 0; else printf "%.2f", c/e }')
      echo "Throughput: $tp items/sec"
    fi
  $interrupted && echo "(Run again to continue; existing *_compressed files will be skipped)"
}

print_summary