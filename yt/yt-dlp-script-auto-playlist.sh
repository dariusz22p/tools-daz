#!/usr/bin/env bash
# Version: 1.7.0

SCRIPT_VERSION="1.7.0"
SCRIPT_BUILD_DATE="2026-06-19"
export YTDLP_JSRUNTIMES="node"

PRINT_EXIT_FOOTER=1
PRINT_RUN_SUMMARY=0

SCRIPT_NAME="$(basename "$0")"
SCRIPT_PATH="${BASH_SOURCE[0]}"
while [[ -L "$SCRIPT_PATH" ]]; do
  SCRIPT_LINK_DIR="$(cd -- "$(dirname -- "$SCRIPT_PATH")" && pwd)"
  SCRIPT_PATH="$(readlink "$SCRIPT_PATH")"
  [[ "$SCRIPT_PATH" == /* ]] || SCRIPT_PATH="$SCRIPT_LINK_DIR/$SCRIPT_PATH"
done
SCRIPT_DIR="$(cd -- "$(dirname -- "$SCRIPT_PATH")" && pwd)"
REPO_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
ARCHIVE="$SCRIPT_DIR/../archive.txt"
SEEN="$SCRIPT_DIR/seen_playlists.txt"
QUEUE="$SCRIPT_DIR/playlist_queue.txt"
DOWNLOAD_DIR="${DOWNLOAD_DIR:-$PWD}"
DOWNLOAD_INDEX_FILE="${DOWNLOAD_INDEX_FILE:-$DOWNLOAD_DIR/yt-dlp-download-index.json}"
MASTER_DOWNLOAD_INDEX_FILE="${MASTER_DOWNLOAD_INDEX_FILE:-${HOME:-$SCRIPT_DIR}/.yt-dlp-download-index.json}"
DIRECTORY_MODE="${DIRECTORY_MODE:-flat}"
MAX_FILES_PER_DIR="${MAX_FILES_PER_DIR:-0}"
REQUIREMENTS_CACHE="$SCRIPT_DIR/.yt-dlp-script-auto-playlist.requirements.cache"
RETRY_COUNT="${RETRY_COUNT:-3}"
RETRY_BACKOFF_SECONDS="${RETRY_BACKOFF_SECONDS:-5}"
MIN_YTDLP_VERSION="${MIN_YTDLP_VERSION:-2025.01.15}"
HEALTH_CHECK_INTERVAL_SECONDS="${HEALTH_CHECK_INTERVAL_SECONDS:-120}"
MIN_FREE_SPACE_MB="${MIN_FREE_SPACE_MB:-2048}"
HEALTH_CHECK_FAILURE_EXIT_CODE="${HEALTH_CHECK_FAILURE_EXIT_CODE:-20}"
HEALTH_LOG_PREFIX="${HEALTH_LOG_PREFIX:-@@@@}"
SCRIPT_START_EPOCH="${SCRIPT_START_EPOCH:-$(date +%s)}"
DOWNLOAD_MODE="audio"
PLAYLIST_INPUT=""
PLAYLISTS_COMPLETED=0
PARTIAL_FAILURES_SKIPPED=0
FATAL_FAILURES=0

health_timestamp() {
  date '+%F %T'
}

health_log() {
  echo "${HEALTH_LOG_PREFIX} $(health_timestamp) HEALTH: $*"
}

health_warn() {
  echo "${HEALTH_LOG_PREFIX} $(health_timestamp) HEALTH WARNING: $*"
}

health_error() {
  echo "${HEALTH_LOG_PREFIX} $(health_timestamp) HEALTH ERROR: $*" >&2
}

script_identity() {
  printf '%s %s (built %s)' "$SCRIPT_NAME" "$SCRIPT_VERSION" "$SCRIPT_BUILD_DATE"
}

print_index_file_status() {
  local phase="$1"
  local label="$2"
  local index_file="$3"
  local stats
  local download_count
  local playlist_count
  local updated_at

  [[ -n "$index_file" ]] || return 0

  if [[ ! -f "$index_file" ]]; then
    echo "$phase index [$label]: $index_file (not created yet)" >&2
    return 0
  fi

  if ! command -v jq >/dev/null 2>&1; then
    echo "$phase index [$label]: $index_file (jq unavailable; stats skipped)" >&2
    return 0
  fi

  stats="$(jq -r '
      [
        (.download_count // (.downloads | length) // 0),
        ((.downloads // []) | map(.playlist_url // empty) | unique | length),
        (.updated_at // .created_at // "unknown")
      ]
      | @tsv
    ' "$index_file" 2>/dev/null || true)"

  if [[ -z "$stats" ]]; then
    echo "$phase index [$label]: $index_file (unable to read stats)" >&2
    return 0
  fi

  download_count="${stats%%$'\t'*}"
  stats="${stats#*$'\t'}"
  playlist_count="${stats%%$'\t'*}"
  updated_at="${stats#*$'\t'}"

  echo "$phase index [$label]: $index_file (downloads $download_count, playlists $playlist_count, updated $updated_at)" >&2
}

print_configured_index_statuses() {
  local phase="$1"

  print_index_file_status "$phase" local "$DOWNLOAD_INDEX_FILE"

  if [[ -n "${MASTER_DOWNLOAD_INDEX_FILE:-}" && "${MASTER_DOWNLOAD_INDEX_FILE}" != "$DOWNLOAD_INDEX_FILE" ]]; then
    print_index_file_status "$phase" master "$MASTER_DOWNLOAD_INDEX_FILE"
  fi
}

print_exit_footer() {
  local exit_code="$?"

  if [[ "${PRINT_RUN_SUMMARY:-0}" -eq 1 ]]; then
    echo "Summary: playlists completed $PLAYLISTS_COMPLETED, partial failures skipped $PARTIAL_FAILURES_SKIPPED, fatal failures $FATAL_FAILURES" >&2
    print_configured_index_statuses "Final"
  fi

  if [[ "${PRINT_EXIT_FOOTER:-1}" -eq 1 ]]; then
    echo "$(script_identity) exit $exit_code" >&2
  fi
}

trap 'print_exit_footer' EXIT

describe_git_update_status() {
  local git_root
  local branch
  local upstream
  local counts
  local ahead
  local behind
  local dirty_suffix=""

  if ! command -v git >/dev/null 2>&1; then
    printf 'unavailable (git is not installed)'
    return 0
  fi

  if ! git_root="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null)"; then
    printf 'unavailable (script is not in a git worktree)'
    return 0
  fi

  branch="$(git -C "$git_root" rev-parse --abbrev-ref HEAD 2>/dev/null || printf 'HEAD')"

  if ! git -C "$git_root" diff --quiet --ignore-submodules -- || ! git -C "$git_root" diff --cached --quiet --ignore-submodules --; then
    dirty_suffix='; working tree has local changes'
  fi

  if ! upstream="$(git -C "$git_root" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null)"; then
    printf 'branch %s has no upstream configured%s' "$branch" "$dirty_suffix"
    return 0
  fi

  counts="$(git -C "$git_root" rev-list --left-right --count HEAD...@{upstream} 2>/dev/null || printf '0 0')"
  ahead="${counts%% *}"
  behind="${counts##* }"

  if ! [[ "$ahead" =~ ^[0-9]+$ && "$behind" =~ ^[0-9]+$ ]]; then
    printf 'unable to compare branch %s with %s%s' "$branch" "$upstream" "$dirty_suffix"
    return 0
  fi

  if (( ahead == 0 && behind == 0 )); then
    printf 'branch %s is up to date with %s (based on local refs)%s' "$branch" "$upstream" "$dirty_suffix"
    return 0
  fi

  if (( behind > 0 && ahead == 0 )); then
    printf 'branch %s is behind %s by %s commit(s); pull recommended (run: git -C %s pull --ff-only)%s' "$branch" "$upstream" "$behind" "$git_root" "$dirty_suffix"
    return 0
  fi

  if (( ahead > 0 && behind == 0 )); then
    printf 'branch %s is ahead of %s by %s commit(s)%s' "$branch" "$upstream" "$ahead" "$dirty_suffix"
    return 0
  fi

  printf 'branch %s has diverged from %s (ahead %s, behind %s)%s' "$branch" "$upstream" "$ahead" "$behind" "$dirty_suffix"
}

show_help() {
  cat <<EOF
$(script_identity)

Usage:
  $SCRIPT_NAME [--video|-v] <playlist-url>
  $SCRIPT_NAME [--audio|-a] <playlist-url>
  $SCRIPT_NAME <playlist-url>
  $SCRIPT_NAME --rebuild-local-index [download-dir]
  $SCRIPT_NAME --help
  $SCRIPT_NAME --version

Description:
  Download a YouTube playlist as MP3 by default, record results in archive.txt, and enqueue related playlists.

Git status:
  $(describe_git_update_status)

Options:
  --video, -v  Download video (best available video+audio, merged as mp4 when needed).
  --audio, -a  Download/extract audio as MP3 (default).
  --rebuild-local-index [dir]
               Rebuild the local non-authoritative index for dir from the master index.
  --help       Print this help text and exit.
  --version    Print only the script version and exit.

Environment:
  DOWNLOAD_DIR                    Target directory for output files. Default: current directory.
  DOWNLOAD_INDEX_FILE             JSON download index path. Default: \$DOWNLOAD_DIR/yt-dlp-download-index.json
  MASTER_DOWNLOAD_INDEX_FILE      Master JSON download index path. Default: \$HOME/.yt-dlp-download-index.json
  DIRECTORY_MODE                  flat or playlist. Default: flat.
  MAX_FILES_PER_DIR               Per-directory file cap before creating batch-NNN folders. Default: 0.
  RETRY_COUNT                     Playlist retry attempts. Default: 3.
  RETRY_BACKOFF_SECONDS           Retry backoff multiplier in seconds. Default: 5.
  HEALTH_CHECK_INTERVAL_SECONDS   Health-check interval after downloads. Default: 120.
  MIN_FREE_SPACE_MB               Minimum free disk space threshold. Default: 2048.
  HEALTH_CHECK_FAILURE_EXIT_CODE  Exit code reserved for health-check failures. Default: 20.
  HEALTH_LOG_PREFIX               Diagnostic prefix for health messages. Default: @@@@.

Examples:
  $SCRIPT_NAME --video 'https://www.youtube.com/playlist?list=PLxxxxxxxxxxxxxxxx'
  $SCRIPT_NAME 'https://www.youtube.com/playlist?list=PLxxxxxxxxxxxxxxxx'
  $SCRIPT_NAME --rebuild-local-index /Users/daz/Music/Polskie
  DOWNLOAD_DIR=/Volumes/MP3-64GB $SCRIPT_NAME 'https://www.youtube.com/playlist?list=PLxxxxxxxxxxxxxxxx'
  DIRECTORY_MODE=playlist $SCRIPT_NAME 'https://www.youtube.com/watch?v=VIDEO_ID&list=RDVIDEO_ID&start_radio=1'

Notes:
  - With a playlist argument, the script verifies jq, node, and yt-dlp before downloading.
  - Use --video/-v to keep video instead of extracting MP3 audio.
  - yt-dlp exit code 1 is treated as a partial playlist failure and the queue continues.
  - Refresh git remote refs with git fetch before relying on the Git status line above.
EOF
}

parse_main_args() {
  PLAYLIST_INPUT=""
  local rebuild_target=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --version)
        PRINT_EXIT_FOOTER=0
        echo "$(script_identity)"
        exit 0
        ;;
      --help|-h)
        show_help
        exit 0
        ;;
      --video|-v)
        DOWNLOAD_MODE="video"
        shift
        ;;
      --audio|-a)
        DOWNLOAD_MODE="audio"
        shift
        ;;
      --rebuild-local-index)
        if [[ $# -ge 2 && "${2:-}" != -* ]]; then
          rebuild_target="$2"
          shift 2
        else
          rebuild_target="$DOWNLOAD_DIR"
          shift
        fi
        if [[ $# -gt 0 ]]; then
          echo "Error: unexpected argument '$1' after --rebuild-local-index." >&2
          show_help >&2
          exit 2
        fi
        rebuild_local_index_from_master "$rebuild_target" || exit 1
        exit 0
        ;;
      --)
        shift
        break
        ;;
      -*)
        echo "Error: unknown option '$1'." >&2
        show_help >&2
        exit 2
        ;;
      *)
        if [[ -n "$PLAYLIST_INPUT" ]]; then
          echo "Error: unexpected extra argument '$1'." >&2
          show_help >&2
          exit 2
        fi
        PLAYLIST_INPUT="$1"
        shift
        ;;
    esac
  done

  if [[ $# -gt 0 ]]; then
    if [[ -n "$PLAYLIST_INPUT" ]]; then
      echo "Error: unexpected extra argument '$1'." >&2
      show_help >&2
      exit 2
    fi
    PLAYLIST_INPUT="$1"
    shift
  fi

  if [[ $# -gt 0 ]]; then
    echo "Error: unexpected extra argument '$1'." >&2
    show_help >&2
    exit 2
  fi

  if [[ -z "$PLAYLIST_INPUT" ]]; then
    show_help
    exit 0
  fi
}

resolve_index_role() {
  local index_file="$1"

  if [[ -n "${MASTER_DOWNLOAD_INDEX_FILE:-}" && "$index_file" == "$MASTER_DOWNLOAD_INDEX_FILE" ]]; then
    printf 'master\ttrue\n'
    return 0
  fi

  printf 'local\tfalse\n'
}

rebuild_local_index_from_master() {
  local target_dir="$1"
  local rebuilt_at
  local local_index_file
  local temp_file

  rebuilt_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  if [[ -z "$target_dir" ]]; then
    target_dir="$DOWNLOAD_DIR"
  fi

  target_dir="$(cd "$target_dir" 2>/dev/null && pwd)" || {
    echo "Error: unable to resolve download directory for rebuild: $1" >&2
    return 1
  }

  if ! command -v jq >/dev/null 2>&1; then
    echo "Error: required command 'jq' is not installed or not in PATH." >&2
    return 1
  fi

  if [[ ! -f "$MASTER_DOWNLOAD_INDEX_FILE" ]]; then
    echo "Error: master index file not found: $MASTER_DOWNLOAD_INDEX_FILE" >&2
    return 1
  fi

  local_index_file="$target_dir/yt-dlp-download-index.json"
  DOWNLOAD_DIR="$target_dir"
  DOWNLOAD_INDEX_FILE="$local_index_file"

  mkdir -p "$(dirname "$local_index_file")"
  temp_file="$local_index_file.tmp"

  jq -n \
    --arg target_dir "$target_dir" \
    --arg script_version "$SCRIPT_VERSION" \
    --arg rebuilt_at "$rebuilt_at" \
    --arg master_index_file "$MASTER_DOWNLOAD_INDEX_FILE" \
    --slurpfile master "$MASTER_DOWNLOAD_INDEX_FILE" \
    '
      ($master[0].downloads // []) as $all_downloads
      | ($all_downloads | map(select((.path // "") | startswith($target_dir + "/")))) as $filtered
      | {
          index_scope: "local",
          authoritative: false,
          download_dir: $target_dir,
          source_master_index: $master_index_file,
          script_version: $script_version,
          created_at: ($master[0].created_at // $rebuilt_at),
          rebuilt_at: $rebuilt_at,
          updated_at: $rebuilt_at,
          download_count: ($filtered | length),
          downloads: $filtered
        }
    ' > "$temp_file"

  mv "$temp_file" "$local_index_file"
  echo "Rebuilt local index from master: $local_index_file" >&2
  print_configured_index_statuses "Final"
}

get_available_disk_mb() {
  local target_dir="$1"
  local available_kb

  available_kb="$(df -Pk "$target_dir" | awk 'NR==2 {print $4}')"
  [[ "$available_kb" =~ ^[0-9]+$ ]] || return 1

  printf '%s\n' $((available_kb / 1024))
}

count_regular_files_in_dir() {
  local target_dir="$1"
  local count=0
  local candidate

  for candidate in "$target_dir"/* "$target_dir"/.[!.]* "$target_dir"/..?*; do
    [[ -f "$candidate" ]] || continue
    count=$((count + 1))
  done

  printf '%s\n' "$count"
}

count_regular_files_in_tree() {
  local target_dir="$1"

  if [[ ! -d "$target_dir" ]]; then
    printf '0\n'
    return 0
  fi

  find "$target_dir" -type f | wc -l | awk '{print $1}'
}

select_batch_dir() {
  local root_dir="$1"
  local batch_index=1
  local candidate_dir
  local file_count

  if ! [[ "${MAX_FILES_PER_DIR:-0}" =~ ^[0-9]+$ ]] || (( MAX_FILES_PER_DIR <= 0 )); then
    printf '%s\n' "$root_dir"
    return 0
  fi

  while true; do
    candidate_dir="$root_dir/batch-$(printf '%03d' "$batch_index")"
    mkdir -p "$candidate_dir"
    file_count="$(count_regular_files_in_tree "$candidate_dir")"

    if [[ "$file_count" =~ ^[0-9]+$ ]] && (( file_count < MAX_FILES_PER_DIR )); then
      printf '%s\n' "$candidate_dir"
      return 0
    fi

    batch_index=$((batch_index + 1))
  done
}

build_output_template() {
  local root_dir="$1"
  local target_root
  local relative_template='%(playlist_index)s - %(title)s.%(ext)s'

  target_root="$(select_batch_dir "$root_dir")"

  if [[ "$DIRECTORY_MODE" == "playlist" ]]; then
    relative_template='%(playlist_title)s/%(playlist_index)s - %(title)s.%(ext)s'
  fi

  printf '%s/%s\n' "$target_root" "$relative_template"
}

format_duration() {
  local seconds="$1"
  local hours
  local minutes

  if ! [[ "$seconds" =~ ^[0-9]+$ ]]; then
    seconds=0
  fi

  hours=$((seconds / 3600))
  minutes=$(((seconds % 3600) / 60))
  seconds=$((seconds % 60))

  printf '%02d:%02d:%02d\n' "$hours" "$minutes" "$seconds"
}

get_download_count() {
  local index_file="$1"

  if [[ -f "$index_file" ]]; then
    jq -r '.download_count // (.downloads | length) // 0' "$index_file" 2>/dev/null || printf '0\n'
    return 0
  fi

  printf '0\n'
}

print_removable_drive_warning() {
  local target_dir="$1"
  local device
  local disk_info
  local volume_name
  local protocol

  [[ "$(uname -s)" == "Darwin" ]] || return 0
  command -v diskutil >/dev/null 2>&1 || return 0

  device="$(df -P "$target_dir" | awk 'NR==2 {print $1}')"
  [[ -n "$device" ]] || return 0

  disk_info="$(diskutil info "$device" 2>/dev/null || true)"
  [[ -n "$disk_info" ]] || return 0

  if ! grep -Eq '^[[:space:]]*Ejectable:[[:space:]]*Yes|^[[:space:]]*Removable Media:[[:space:]]*Removable' <<< "$disk_info"; then
    return 0
  fi

  volume_name="$(awk -F: '/Volume Name/ {sub(/^[[:space:]]+/, "", $2); print $2; exit}' <<< "$disk_info")"
  protocol="$(awk -F: '/Protocol/ {sub(/^[[:space:]]+/, "", $2); print $2; exit}' <<< "$disk_info")"

  health_warn "$target_dir is on a removable drive${volume_name:+ ($volume_name)}${protocol:+ via $protocol}. Wait for the health check flush before unplugging it."
}

resolve_index_role() {
  local index_file="$1"

  if [[ -n "${MASTER_DOWNLOAD_INDEX_FILE:-}" && "$index_file" == "$MASTER_DOWNLOAD_INDEX_FILE" ]]; then
    printf 'master\ttrue\n'
    return 0
  fi

  printf 'local\tfalse\n'
}

update_download_index() {
  local index_file="$1"
  local downloaded_file="$2"
  local playlist_url="$3"
  local downloaded_at
  local file_name
  local size_bytes=0
  local temp_file
  local index_role
  local index_authoritative
  local role_data

  downloaded_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  file_name="$(basename "$downloaded_file")"
  temp_file="$index_file.tmp"
  role_data="$(resolve_index_role "$index_file")"
  index_role="${role_data%%$'\t'*}"
  index_authoritative="${role_data##*$'\t'}"

  mkdir -p "$(dirname "$index_file")"

  if [[ -f "$downloaded_file" ]]; then
    size_bytes="$(stat -f%z "$downloaded_file" 2>/dev/null || stat -c%s "$downloaded_file" 2>/dev/null || printf '0')"
  fi

  jq \
    --arg download_dir "$DOWNLOAD_DIR" \
    --arg index_role "$index_role" \
    --arg script_version "$SCRIPT_VERSION" \
    --arg downloaded_at "$downloaded_at" \
    --arg downloaded_file "$downloaded_file" \
    --arg file_name "$file_name" \
    --arg playlist_url "$playlist_url" \
    --argjson size_bytes "$size_bytes" \
    --argjson authoritative "$index_authoritative" \
    '
      (. // {
        index_scope: $index_role,
        authoritative: $authoritative,
        download_dir: $download_dir,
        script_version: $script_version,
        created_at: $downloaded_at,
        download_count: 0,
        downloads: []
      })
      | .index_scope = $index_role
      | .authoritative = $authoritative
      | .download_dir = $download_dir
      | .script_version = $script_version
      | .updated_at = $downloaded_at
      | .downloads += [{
          downloaded_at: $downloaded_at,
          path: $downloaded_file,
          file_name: $file_name,
          size_bytes: $size_bytes,
          playlist_url: $playlist_url
        }]
      | .download_count = (.downloads | length)
    ' \
    "$index_file" > "$temp_file" 2>/dev/null || jq -n \
      --arg download_dir "$DOWNLOAD_DIR" \
      --arg index_role "$index_role" \
      --arg script_version "$SCRIPT_VERSION" \
      --arg downloaded_at "$downloaded_at" \
      --arg downloaded_file "$downloaded_file" \
      --arg file_name "$file_name" \
      --arg playlist_url "$playlist_url" \
      --argjson size_bytes "$size_bytes" \
      --argjson authoritative "$index_authoritative" \
      '{
        index_scope: $index_role,
        authoritative: $authoritative,
        download_dir: $download_dir,
        script_version: $script_version,
        created_at: $downloaded_at,
        updated_at: $downloaded_at,
        download_count: 1,
        downloads: [{
          downloaded_at: $downloaded_at,
          path: $downloaded_file,
          file_name: $file_name,
          size_bytes: $size_bytes,
          playlist_url: $playlist_url
        }]
      }' > "$temp_file"

  mv "$temp_file" "$index_file"
}

print_memory_health() {
  if command -v vm_stat >/dev/null 2>&1; then
    local page_size
    local pages_free
    local pages_speculative
    local pages_active
    local pages_inactive
    local pages_wired
    local free_mb
    local used_mb
    local total_mb

    page_size="$(vm_stat | awk '/page size of/ {gsub(/[^0-9]/, "", $8); print $8; exit}')"
    pages_free="$(vm_stat | awk -F: '/Pages free/ {gsub(/[^0-9]/, "", $2); print $2; exit}')"
    pages_speculative="$(vm_stat | awk -F: '/Pages speculative/ {gsub(/[^0-9]/, "", $2); print $2; exit}')"
    pages_active="$(vm_stat | awk -F: '/Pages active/ {gsub(/[^0-9]/, "", $2); print $2; exit}')"
    pages_inactive="$(vm_stat | awk -F: '/Pages inactive/ {gsub(/[^0-9]/, "", $2); print $2; exit}')"
    pages_wired="$(vm_stat | awk -F: '/Pages wired down/ {gsub(/[^0-9]/, "", $2); print $2; exit}')"

    page_size="${page_size:-4096}"
    pages_free="${pages_free:-0}"
    pages_speculative="${pages_speculative:-0}"
    pages_active="${pages_active:-0}"
    pages_inactive="${pages_inactive:-0}"
    pages_wired="${pages_wired:-0}"

    free_mb=$(((pages_free + pages_speculative) * page_size / 1024 / 1024))
    used_mb=$(((pages_active + pages_inactive + pages_wired) * page_size / 1024 / 1024))
    total_mb=$((free_mb + used_mb))

    health_log "memory used ${used_mb}MB / ${total_mb}MB, free ${free_mb}MB"
    return 0
  fi

  if command -v free >/dev/null 2>&1; then
    free -m | awk -v prefix="$HEALTH_LOG_PREFIX" 'NR==2 {printf "%s HEALTH: memory used %sMB / %sMB, free %sMB\n", prefix, $3, $2, $7}'
    return 0
  fi

  health_log "memory stats unavailable on this system"
}

run_health_check() {
  local target_dir="$1"
  local state_file="$2"
  local index_file="$3"
  local start_epoch="$4"
  local now
  local last_run=0
  local interval
  local available_mb
  local download_count
  local directory_file_count
  local runtime_seconds
  local runtime_display

  interval="${HEALTH_CHECK_INTERVAL_SECONDS:-120}"
  if ! [[ "$interval" =~ ^[0-9]+$ ]]; then
    interval=120
  fi

  now="$(date +%s)"
  if [[ -f "$state_file" ]]; then
    last_run="$(cat "$state_file" 2>/dev/null)"
  fi

  if [[ "$last_run" =~ ^[0-9]+$ ]] && (( interval > 0 )) && (( now - last_run < interval )); then
    return 0
  fi

  printf '%s\n' "$now" > "$state_file"

  health_log "flushing writes for $target_dir"
  sync

  available_mb="$(get_available_disk_mb "$target_dir")" || {
    health_error "unable to determine free disk space for $target_dir"
    return "$HEALTH_CHECK_FAILURE_EXIT_CODE"
  }

  health_log "disk free ${available_mb}MB at $target_dir"
  print_removable_drive_warning "$target_dir"
  print_memory_health

  download_count="$(get_download_count "$index_file")"
  directory_file_count="$(count_regular_files_in_dir "$target_dir")"
  runtime_seconds=$((now - start_epoch))
  runtime_display="$(format_duration "$runtime_seconds")"
  health_log "downloaded ${download_count} files, directory contains ${directory_file_count} files, runtime ${runtime_display}"

  if [[ "${MIN_FREE_SPACE_MB:-2048}" =~ ^[0-9]+$ ]] && (( available_mb < MIN_FREE_SPACE_MB )); then
    health_error "free disk space ${available_mb}MB is below safety threshold ${MIN_FREE_SPACE_MB}MB at $target_dir"
    return "$HEALTH_CHECK_FAILURE_EXIT_CODE"
  fi
}

create_health_check_hook() {
  local hook_script="$1"

  cat > "$hook_script" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

health_log() {
  echo "${HEALTH_LOG_PREFIX:-@@@@} $(date '+%F %T') HEALTH: $*"
}

health_warn() {
  echo "${HEALTH_LOG_PREFIX:-@@@@} $(date '+%F %T') HEALTH WARNING: $*"
}

health_error() {
  echo "${HEALTH_LOG_PREFIX:-@@@@} $(date '+%F %T') HEALTH ERROR: $*" >&2
}

get_available_disk_mb() {
  local target_dir="$1"
  local available_kb

  available_kb="$(df -Pk "$target_dir" | awk 'NR==2 {print $4}')"
  [[ "$available_kb" =~ ^[0-9]+$ ]] || return 1

  printf '%s\n' $((available_kb / 1024))
}

count_regular_files_in_dir() {
  local target_dir="$1"
  local count=0
  local candidate

  for candidate in "$target_dir"/* "$target_dir"/.[!.]* "$target_dir"/..?*; do
    [[ -f "$candidate" ]] || continue
    count=$((count + 1))
  done

  printf '%s\n' "$count"
}

count_regular_files_in_tree() {
  local target_dir="$1"

  if [[ ! -d "$target_dir" ]]; then
    printf '0\n'
    return 0
  fi

  find "$target_dir" -type f | wc -l | awk '{print $1}'
}

format_duration() {
  local seconds="$1"
  local hours
  local minutes

  if ! [[ "$seconds" =~ ^[0-9]+$ ]]; then
    seconds=0
  fi

  hours=$((seconds / 3600))
  minutes=$(((seconds % 3600) / 60))
  seconds=$((seconds % 60))

  printf '%02d:%02d:%02d\n' "$hours" "$minutes" "$seconds"
}

get_download_count() {
  local index_file="$1"

  if [[ -f "$index_file" ]]; then
    jq -r '.download_count // (.downloads | length) // 0' "$index_file" 2>/dev/null || printf '0\n'
    return 0
  fi

  printf '0\n'
}

print_removable_drive_warning() {
  local target_dir="$1"
  local device
  local disk_info
  local volume_name
  local protocol

  [[ "$(uname -s)" == "Darwin" ]] || return 0
  command -v diskutil >/dev/null 2>&1 || return 0

  device="$(df -P "$target_dir" | awk 'NR==2 {print $1}')"
  [[ -n "$device" ]] || return 0

  disk_info="$(diskutil info "$device" 2>/dev/null || true)"
  [[ -n "$disk_info" ]] || return 0

  if ! grep -Eq '^[[:space:]]*Ejectable:[[:space:]]*Yes|^[[:space:]]*Removable Media:[[:space:]]*Removable' <<< "$disk_info"; then
    return 0
  fi

  volume_name="$(awk -F: '/Volume Name/ {sub(/^[[:space:]]+/, "", $2); print $2; exit}' <<< "$disk_info")"
  protocol="$(awk -F: '/Protocol/ {sub(/^[[:space:]]+/, "", $2); print $2; exit}' <<< "$disk_info")"

  health_warn "$target_dir is on a removable drive${volume_name:+ ($volume_name)}${protocol:+ via $protocol}. Wait for the health check flush before unplugging it."
}

resolve_index_role() {
  local index_file="$1"

  if [[ -n "${MASTER_DOWNLOAD_INDEX_FILE:-}" && "$index_file" == "$MASTER_DOWNLOAD_INDEX_FILE" ]]; then
    printf 'master\ttrue\n'
    return 0
  fi

  printf 'local\tfalse\n'
}

update_download_index() {
  local index_file="$1"
  local downloaded_file="$2"
  local playlist_url="$3"
  local downloaded_at
  local file_name
  local size_bytes=0
  local temp_file
  local index_role
  local index_authoritative
  local role_data

  downloaded_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  file_name="$(basename "$downloaded_file")"
  temp_file="$index_file.tmp"
  role_data="$(resolve_index_role "$index_file")"
  index_role="${role_data%%$'\t'*}"
  index_authoritative="${role_data##*$'\t'}"

  mkdir -p "$(dirname "$index_file")"

  if [[ -f "$downloaded_file" ]]; then
    size_bytes="$(stat -f%z "$downloaded_file" 2>/dev/null || stat -c%s "$downloaded_file" 2>/dev/null || printf '0')"
  fi

  jq \
    --arg download_dir "$DOWNLOAD_DIR" \
    --arg index_role "$index_role" \
    --arg script_version "$SCRIPT_VERSION" \
    --arg downloaded_at "$downloaded_at" \
    --arg downloaded_file "$downloaded_file" \
    --arg file_name "$file_name" \
    --arg playlist_url "$playlist_url" \
    --argjson size_bytes "$size_bytes" \
    --argjson authoritative "$index_authoritative" \
    '
      (. // {
        index_scope: $index_role,
        authoritative: $authoritative,
        download_dir: $download_dir,
        script_version: $script_version,
        created_at: $downloaded_at,
        download_count: 0,
        downloads: []
      })
      | .index_scope = $index_role
      | .authoritative = $authoritative
      | .download_dir = $download_dir
      | .script_version = $script_version
      | .updated_at = $downloaded_at
      | .downloads += [{
          downloaded_at: $downloaded_at,
          path: $downloaded_file,
          file_name: $file_name,
          size_bytes: $size_bytes,
          playlist_url: $playlist_url
        }]
      | .download_count = (.downloads | length)
    ' \
    "$index_file" > "$temp_file" 2>/dev/null || jq -n \
      --arg download_dir "$DOWNLOAD_DIR" \
      --arg index_role "$index_role" \
      --arg script_version "$SCRIPT_VERSION" \
      --arg downloaded_at "$downloaded_at" \
      --arg downloaded_file "$downloaded_file" \
      --arg file_name "$file_name" \
      --arg playlist_url "$playlist_url" \
      --argjson size_bytes "$size_bytes" \
      --argjson authoritative "$index_authoritative" \
      '{
        index_scope: $index_role,
        authoritative: $authoritative,
        download_dir: $download_dir,
        script_version: $script_version,
        created_at: $downloaded_at,
        updated_at: $downloaded_at,
        download_count: 1,
        downloads: [{
          downloaded_at: $downloaded_at,
          path: $downloaded_file,
          file_name: $file_name,
          size_bytes: $size_bytes,
          playlist_url: $playlist_url
        }]
      }' > "$temp_file"

  mv "$temp_file" "$index_file"
}

print_memory_health() {
  if command -v vm_stat >/dev/null 2>&1; then
    local page_size
    local pages_free
    local pages_speculative
    local pages_active
    local pages_inactive
    local pages_wired
    local free_mb
    local used_mb
    local total_mb

    page_size="$(vm_stat | awk '/page size of/ {gsub(/[^0-9]/, "", $8); print $8; exit}')"
    pages_free="$(vm_stat | awk -F: '/Pages free/ {gsub(/[^0-9]/, "", $2); print $2; exit}')"
    pages_speculative="$(vm_stat | awk -F: '/Pages speculative/ {gsub(/[^0-9]/, "", $2); print $2; exit}')"
    pages_active="$(vm_stat | awk -F: '/Pages active/ {gsub(/[^0-9]/, "", $2); print $2; exit}')"
    pages_inactive="$(vm_stat | awk -F: '/Pages inactive/ {gsub(/[^0-9]/, "", $2); print $2; exit}')"
    pages_wired="$(vm_stat | awk -F: '/Pages wired down/ {gsub(/[^0-9]/, "", $2); print $2; exit}')"

    page_size="${page_size:-4096}"
    pages_free="${pages_free:-0}"
    pages_speculative="${pages_speculative:-0}"
    pages_active="${pages_active:-0}"
    pages_inactive="${pages_inactive:-0}"
    pages_wired="${pages_wired:-0}"

    free_mb=$(((pages_free + pages_speculative) * page_size / 1024 / 1024))
    used_mb=$(((pages_active + pages_inactive + pages_wired) * page_size / 1024 / 1024))
    total_mb=$((free_mb + used_mb))

    health_log "memory used ${used_mb}MB / ${total_mb}MB, free ${free_mb}MB"
    return 0
  fi

  if command -v free >/dev/null 2>&1; then
    free -m | awk -v prefix="${HEALTH_LOG_PREFIX:-@@@@}" 'NR==2 {printf "%s HEALTH: memory used %sMB / %sMB, free %sMB\n", prefix, $3, $2, $7}'
    return 0
  fi

  health_log "memory stats unavailable on this system"
}

run_health_check() {
  local downloaded_file="$1"
  local state_file="$2"
  local index_file="$3"
  local start_epoch="$4"
  local target_dir
  local now
  local last_run=0
  local interval
  local available_mb
  local download_count
  local directory_file_count
  local runtime_seconds
  local runtime_display

  target_dir="$(dirname "$downloaded_file")"

  interval="${HEALTH_CHECK_INTERVAL_SECONDS:-120}"
  if ! [[ "$interval" =~ ^[0-9]+$ ]]; then
    interval=120
  fi

  now="$(date +%s)"
  if [[ -f "$state_file" ]]; then
    last_run="$(cat "$state_file" 2>/dev/null)"
  fi

  if [[ "$last_run" =~ ^[0-9]+$ ]] && (( interval > 0 )) && (( now - last_run < interval )); then
    exit 0
  fi

  printf '%s\n' "$now" > "$state_file"

  health_log "flushing writes for $target_dir"
  sync

  available_mb="$(get_available_disk_mb "$target_dir")" || {
    health_error "unable to determine free disk space for $target_dir"
    exit "${HEALTH_CHECK_FAILURE_EXIT_CODE:-20}"
  }

  health_log "disk free ${available_mb}MB at $target_dir"
  print_removable_drive_warning "$target_dir"
  print_memory_health

  download_count="$(get_download_count "$index_file")"
  directory_file_count="$(count_regular_files_in_dir "$target_dir")"
  runtime_seconds=$((now - start_epoch))
  runtime_display="$(format_duration "$runtime_seconds")"
  health_log "downloaded ${download_count} files, directory contains ${directory_file_count} files, runtime ${runtime_display}"

  if [[ "${MIN_FREE_SPACE_MB:-2048}" =~ ^[0-9]+$ ]] && (( available_mb < MIN_FREE_SPACE_MB )); then
    health_error "free disk space ${available_mb}MB is below safety threshold ${MIN_FREE_SPACE_MB}MB at $target_dir"
    exit "${HEALTH_CHECK_FAILURE_EXIT_CODE:-20}"
  fi
}

update_download_index "${DOWNLOAD_INDEX_FILE:?}" "${1:-}" "${CURRENT_PLAYLIST_URL:-}"
if [[ -n "${MASTER_DOWNLOAD_INDEX_FILE:-}" && "${MASTER_DOWNLOAD_INDEX_FILE}" != "${DOWNLOAD_INDEX_FILE:?}" ]]; then
  update_download_index "${MASTER_DOWNLOAD_INDEX_FILE}" "${1:-}" "${CURRENT_PLAYLIST_URL:-}"
fi
run_health_check "${1:-}" "${HEALTH_CHECK_STATE_FILE:?}" "${DOWNLOAD_INDEX_FILE:?}" "${SCRIPT_START_EPOCH:-0}"
EOF

  chmod +x "$hook_script"
}

normalize_playlist_url() {
  local input_url="$1"
  local list_regex='[?&]list=([^&]+)'
  local radio_regex='(^|[?&])start_radio=1($|&)'
  local list_id

  if [[ "$input_url" =~ $radio_regex ]]; then
    printf '%s\n' "$input_url"
    return 0
  fi

  if [[ "$input_url" =~ $list_regex ]]; then
    list_id="${BASH_REMATCH[1]}"

    if [[ "$list_id" == RD* ]]; then
      printf '%s\n' "$input_url"
      return 0
    fi

    printf 'https://www.youtube.com/playlist?list=%s\n' "$list_id"
    return 0
  fi

  printf '%s\n' "$input_url"
}

remove_first_queue_item() {
  tail -n +2 "$QUEUE" > "$QUEUE.tmp" && mv "$QUEUE.tmp" "$QUEUE"
}

version_at_least() {
  local current_version="$1"
  local minimum_version="$2"
  local normalized_current
  local normalized_minimum

  normalize_version() {
    local raw_version="$1"
    local sanitized_version
    local part_a=0
    local part_b=0
    local part_c=0
    local part_d=0
    local IFS='.'
    local version_parts=()

    sanitized_version="${raw_version//[^0-9]/.}"
    read -r -a version_parts <<< "$sanitized_version"

    part_a="${version_parts[0]:-0}"
    part_b="${version_parts[1]:-0}"
    part_c="${version_parts[2]:-0}"
    part_d="${version_parts[3]:-0}"

    part_a="$((10#${part_a}))"
    part_b="$((10#${part_b}))"
    part_c="$((10#${part_c}))"
    part_d="$((10#${part_d}))"

    printf '%04d%04d%04d%04d\n' "$part_a" "$part_b" "$part_c" "$part_d"
  }

  normalized_current="$(normalize_version "$current_version")"
  normalized_minimum="$(normalize_version "$minimum_version")"

  [[ "$normalized_current" == "$normalized_minimum" || "$normalized_current" > "$normalized_minimum" ]]
}

requirements_cache_is_fresh() {
  local today

  today="$(date +%F)"

  [[ -f "$REQUIREMENTS_CACHE" ]] || return 1
  grep -Fxq "date=$today" "$REQUIREMENTS_CACHE" || return 1
  grep -Fxq "script_version=$SCRIPT_VERSION" "$REQUIREMENTS_CACHE" || return 1
}

write_requirements_cache() {
  local yt_dlp_version="$1"
  local today

  today="$(date +%F)"

  cat > "$REQUIREMENTS_CACHE" <<EOF
date=$today
script_version=$SCRIPT_VERSION
yt_dlp_version=$yt_dlp_version
EOF
}

verify_requirements() {
  local yt_dlp_version
  local yt_dlp_version_output
  local yt_dlp_version_status

  if requirements_cache_is_fresh; then
    echo "Using cached requirement check for $(date +%F)."
    return 0
  fi

  for command_name in jq node yt-dlp; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
      echo "Error: required command '$command_name' is not installed or not in PATH." >&2
      return 1
    fi
  done

  yt_dlp_version_output="$(yt-dlp --version 2>&1)"
  yt_dlp_version_status=$?
  yt_dlp_version="$(printf '%s\n' "$yt_dlp_version_output" | tail -n 1)"

  if [[ $yt_dlp_version_status -ne 0 ]]; then
    echo "Error: unable to determine yt-dlp version." >&2
    if [[ -n "$yt_dlp_version_output" ]]; then
      echo "yt-dlp --version output: $yt_dlp_version_output" >&2
    fi
    return 1
  fi

  if [[ -z "$yt_dlp_version" ]]; then
    echo "Error: unable to determine yt-dlp version." >&2
    return 1
  fi

  if ! version_at_least "$yt_dlp_version" "$MIN_YTDLP_VERSION"; then
    echo "Error: yt-dlp $yt_dlp_version is too old. Minimum supported version is $MIN_YTDLP_VERSION." >&2
    return 1
  fi

  write_requirements_cache "$yt_dlp_version"
  echo "Requirement check passed with yt-dlp $yt_dlp_version."
}

download_playlist() {
  local playlist_url="$1"
  local attempt=1
  local exit_code=0
  local sleep_seconds
  local temp_dir
  local health_hook
  local health_state_file
  local output_template
  local -a yt_dlp_env
  local -a yt_dlp_cmd

  mkdir -p "$DOWNLOAD_DIR"
  temp_dir="$(mktemp -d)"
  health_hook="$temp_dir/yt-dlp-health-check.sh"
  health_state_file="$temp_dir/yt-dlp-health-check.state"
  create_health_check_hook "$health_hook"
  output_template="$(build_output_template "$DOWNLOAD_DIR")"
  yt_dlp_env=(
    "DOWNLOAD_DIR=$DOWNLOAD_DIR"
    "DOWNLOAD_INDEX_FILE=$DOWNLOAD_INDEX_FILE"
    "MASTER_DOWNLOAD_INDEX_FILE=$MASTER_DOWNLOAD_INDEX_FILE"
    "DIRECTORY_MODE=$DIRECTORY_MODE"
    "MAX_FILES_PER_DIR=$MAX_FILES_PER_DIR"
    "HEALTH_CHECK_INTERVAL_SECONDS=$HEALTH_CHECK_INTERVAL_SECONDS"
    "HEALTH_CHECK_STATE_FILE=$health_state_file"
    "HEALTH_CHECK_FAILURE_EXIT_CODE=$HEALTH_CHECK_FAILURE_EXIT_CODE"
    "HEALTH_LOG_PREFIX=$HEALTH_LOG_PREFIX"
    "MIN_FREE_SPACE_MB=$MIN_FREE_SPACE_MB"
    "SCRIPT_START_EPOCH=$SCRIPT_START_EPOCH"
    "SCRIPT_VERSION=$SCRIPT_VERSION"
    "CURRENT_PLAYLIST_URL=$playlist_url"
  )
  yt_dlp_cmd=(
    yt-dlp
    --js-runtimes node
    --yes-playlist
  )

  if [[ "$DOWNLOAD_MODE" == "video" ]]; then
    yt_dlp_cmd+=(
      -f "bv*+ba/b"
      --merge-output-format mp4
    )
  else
    yt_dlp_cmd+=(
      -x
      --audio-format mp3
    )
  fi

  yt_dlp_cmd+=(
    -o "$output_template"
    --exec "after_move:$health_hook {}"
    --download-archive "$ARCHIVE"
    "$playlist_url"
  )

  trap 'rm -rf "$temp_dir"' RETURN

  while [[ $attempt -le $RETRY_COUNT ]]; do
    env "${yt_dlp_env[@]}" "${yt_dlp_cmd[@]}"

    exit_code=$?
    if [[ $exit_code -eq 0 ]]; then
      return 0
    fi

    if [[ $attempt -ge $RETRY_COUNT ]]; then
      break
    fi

    sleep_seconds=$((RETRY_BACKOFF_SECONDS * attempt))
    echo "Retry $attempt/$RETRY_COUNT failed with exit code $exit_code. Waiting ${sleep_seconds}s before retrying..." >&2
    sleep "$sleep_seconds"
    attempt=$((attempt + 1))
  done

  return "$exit_code"
}

enqueue_related_playlists() {
  local playlist_url="$1"
  local related_playlist
  local related_playlist_url
  local enqueued_count=0

  while read -r video_id; do
    [[ -n "$video_id" ]] || continue

    related_playlist=$(yt-dlp --js-runtimes node -J \
      "https://www.youtube.com/watch?v=$video_id" \
      2>/dev/null \
      | jq -r '
          .related_playlists // {}
          | [ .uploads ]
            + [ .[]? | if type == "string" then . elif type == "array" then .[] else empty end ]
          | map(select(type == "string" and length > 0))
          | unique
          | (map(select(startswith("RD")))
             + map(select(startswith("PL") or startswith("UU") or startswith("OLAK5uy_"))))
          | .[0] // empty')

    if [[ -n "$related_playlist" ]]; then
      if [[ "$related_playlist" == RD* ]]; then
        related_playlist_url="https://www.youtube.com/watch?v=$video_id&list=$related_playlist&start_radio=1"
      else
        related_playlist_url="https://www.youtube.com/playlist?list=$related_playlist"
      fi

      normalize_playlist_url "$related_playlist_url" >> "$QUEUE"
      enqueued_count=$((enqueued_count + 1))
    fi
  done < <(
    yt-dlp --js-runtimes node --flat-playlist -J "$playlist_url" \
      | jq -r '.entries[]?.id' \
      | head -n 10
  )

  (( enqueued_count > 0 ))
}

parse_main_args "$@"

echo "$(script_identity)"
PRINT_RUN_SUMMARY=1

verify_requirements || exit 1
print_configured_index_statuses "Startup"

touch "$SEEN"
touch "$QUEUE"

# Seed queue from the first argument when one is provided.
if [[ -n "${PLAYLIST_INPUT:-}" ]]; then
  normalize_playlist_url "$PLAYLIST_INPUT" > "$QUEUE"
fi

while true; do
  PL=$(head -n 1 "$QUEUE")

  # if empty, stop
  if [[ -z "$PL" ]]; then
    echo "✅ Queue empty. Done."
    break
  fi

  PL=$(normalize_playlist_url "$PL")

  # skip duplicates
  if grep -Fxq "$PL" "$SEEN"; then
    remove_first_queue_item
    continue
  fi

  echo "▶ Playlist: $PL"

  download_playlist "$PL"
  status=$?
  if [[ $status -ne 0 ]]; then
    if [[ $status -eq 1 ]]; then
      PARTIAL_FAILURES_SKIPPED=$((PARTIAL_FAILURES_SKIPPED + 1))
      echo "Warning: yt-dlp reported partial failures for playlist: $PL (exit code 1)" >&2
      echo "Continuing to the next playlist because exit code 1 usually means one or more playlist entries failed." >&2
    else
      FATAL_FAILURES=$((FATAL_FAILURES + 1))
      echo "Error: yt-dlp failed for playlist: $PL (exit code $status)" >&2
      echo "Likely cause: at least one playlist item failed or a post-download health check returned an error. Review the yt-dlp output above for the first error line." >&2
      echo "The playlist was left at the front of the queue for retry." >&2
      exit "$status"
    fi
  fi

  if [[ $status -eq 0 ]]; then
    PLAYLISTS_COMPLETED=$((PLAYLISTS_COMPLETED + 1))
  fi

  printf '%s\n' "$PL" >> "$SEEN"
  remove_first_queue_item

  if ! enqueue_related_playlists "$PL"; then
    echo "Info: no related or recommended playlist was discovered from the first 10 entries of $PL." >&2
  fi

  sort -u "$QUEUE" -o "$QUEUE"

done
