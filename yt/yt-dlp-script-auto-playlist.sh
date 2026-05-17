#!/usr/bin/env bash
# Version: 1.3.0

SCRIPT_VERSION="1.3.0"
export YTDLP_JSRUNTIMES="node"

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
ARCHIVE="$SCRIPT_DIR/../archive.txt"
SEEN="$SCRIPT_DIR/seen_playlists.txt"
QUEUE="$SCRIPT_DIR/playlist_queue.txt"
DOWNLOAD_DIR="${DOWNLOAD_DIR:-$PWD}"
DOWNLOAD_INDEX_FILE="${DOWNLOAD_INDEX_FILE:-$DOWNLOAD_DIR/yt-dlp-download-index.json}"
DIRECTORY_MODE="${DIRECTORY_MODE:-flat}"
MAX_FILES_PER_DIR="${MAX_FILES_PER_DIR:-0}"
REQUIREMENTS_CACHE="$SCRIPT_DIR/.yt-dlp-script-auto-playlist.requirements.cache"
RETRY_COUNT="${RETRY_COUNT:-3}"
RETRY_BACKOFF_SECONDS="${RETRY_BACKOFF_SECONDS:-5}"
MIN_YTDLP_VERSION="${MIN_YTDLP_VERSION:-2025.01.15}"
HEALTH_CHECK_INTERVAL_SECONDS="${HEALTH_CHECK_INTERVAL_SECONDS:-120}"
MIN_FREE_SPACE_MB="${MIN_FREE_SPACE_MB:-2048}"
HEALTH_LOG_PREFIX="${HEALTH_LOG_PREFIX:-@@@@}"
SCRIPT_START_EPOCH="${SCRIPT_START_EPOCH:-$(date +%s)}"

health_log() {
  echo "${HEALTH_LOG_PREFIX} HEALTH: $*"
}

health_warn() {
  echo "${HEALTH_LOG_PREFIX} HEALTH WARNING: $*"
}

health_error() {
  echo "${HEALTH_LOG_PREFIX} HEALTH ERROR: $*" >&2
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

update_download_index() {
  local index_file="$1"
  local downloaded_file="$2"
  local playlist_url="$3"
  local downloaded_at
  local file_name
  local size_bytes=0
  local temp_file

  downloaded_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  file_name="$(basename "$downloaded_file")"
  temp_file="$index_file.tmp"

  if [[ -f "$downloaded_file" ]]; then
    size_bytes="$(stat -f%z "$downloaded_file" 2>/dev/null || stat -c%s "$downloaded_file" 2>/dev/null || printf '0')"
  fi

  jq \
    --arg download_dir "$DOWNLOAD_DIR" \
    --arg script_version "$SCRIPT_VERSION" \
    --arg downloaded_at "$downloaded_at" \
    --arg downloaded_file "$downloaded_file" \
    --arg file_name "$file_name" \
    --arg playlist_url "$playlist_url" \
    --argjson size_bytes "$size_bytes" \
    '
      (. // {
        download_dir: $download_dir,
        script_version: $script_version,
        created_at: $downloaded_at,
        download_count: 0,
        downloads: []
      })
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
      --arg script_version "$SCRIPT_VERSION" \
      --arg downloaded_at "$downloaded_at" \
      --arg downloaded_file "$downloaded_file" \
      --arg file_name "$file_name" \
      --arg playlist_url "$playlist_url" \
      --argjson size_bytes "$size_bytes" \
      '{
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
    return 1
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
    return 1
  fi
}

create_health_check_hook() {
  local hook_script="$1"

  cat > "$hook_script" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

health_log() {
  echo "${HEALTH_LOG_PREFIX:-@@@@} HEALTH: $*"
}

health_warn() {
  echo "${HEALTH_LOG_PREFIX:-@@@@} HEALTH WARNING: $*"
}

health_error() {
  echo "${HEALTH_LOG_PREFIX:-@@@@} HEALTH ERROR: $*" >&2
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

update_download_index() {
  local index_file="$1"
  local downloaded_file="$2"
  local playlist_url="$3"
  local downloaded_at
  local file_name
  local size_bytes=0
  local temp_file

  downloaded_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  file_name="$(basename "$downloaded_file")"
  temp_file="$index_file.tmp"

  if [[ -f "$downloaded_file" ]]; then
    size_bytes="$(stat -f%z "$downloaded_file" 2>/dev/null || stat -c%s "$downloaded_file" 2>/dev/null || printf '0')"
  fi

  jq \
    --arg download_dir "$DOWNLOAD_DIR" \
    --arg script_version "$SCRIPT_VERSION" \
    --arg downloaded_at "$downloaded_at" \
    --arg downloaded_file "$downloaded_file" \
    --arg file_name "$file_name" \
    --arg playlist_url "$playlist_url" \
    --argjson size_bytes "$size_bytes" \
    '
      (. // {
        download_dir: $download_dir,
        script_version: $script_version,
        created_at: $downloaded_at,
        download_count: 0,
        downloads: []
      })
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
      --arg script_version "$SCRIPT_VERSION" \
      --arg downloaded_at "$downloaded_at" \
      --arg downloaded_file "$downloaded_file" \
      --arg file_name "$file_name" \
      --arg playlist_url "$playlist_url" \
      --argjson size_bytes "$size_bytes" \
      '{
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
    exit 1
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
    exit 1
  fi
}

update_download_index "${DOWNLOAD_INDEX_FILE:?}" "${1:-}" "${CURRENT_PLAYLIST_URL:-}"
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

  mkdir -p "$DOWNLOAD_DIR"
  temp_dir="$(mktemp -d)"
  health_hook="$temp_dir/yt-dlp-health-check.sh"
  health_state_file="$temp_dir/yt-dlp-health-check.state"
  create_health_check_hook "$health_hook"
  output_template="$(build_output_template "$DOWNLOAD_DIR")"

  trap 'rm -rf "$temp_dir"' RETURN

  while [[ $attempt -le $RETRY_COUNT ]]; do
    DOWNLOAD_DIR="$DOWNLOAD_DIR" \
    DOWNLOAD_INDEX_FILE="$DOWNLOAD_INDEX_FILE" \
    DIRECTORY_MODE="$DIRECTORY_MODE" \
    MAX_FILES_PER_DIR="$MAX_FILES_PER_DIR" \
    HEALTH_CHECK_INTERVAL_SECONDS="$HEALTH_CHECK_INTERVAL_SECONDS" \
    HEALTH_CHECK_STATE_FILE="$health_state_file" \
    HEALTH_LOG_PREFIX="$HEALTH_LOG_PREFIX" \
    MIN_FREE_SPACE_MB="$MIN_FREE_SPACE_MB" \
    SCRIPT_START_EPOCH="$SCRIPT_START_EPOCH" \
    SCRIPT_VERSION="$SCRIPT_VERSION" \
    CURRENT_PLAYLIST_URL="$playlist_url" \
    yt-dlp --js-runtimes node --yes-playlist -x --audio-format mp3 \
      -o "$output_template" \
      --exec "after_move:$health_hook {}" \
      --download-archive "$ARCHIVE" \
      "$playlist_url"

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

  yt-dlp --js-runtimes node --flat-playlist -J "$playlist_url" \
    | jq -r '.entries[]?.id' \
    | head -n 10 \
    | while read -r video_id; do
        [[ -n "$video_id" ]] || continue

        related_playlist=$(yt-dlp --js-runtimes node -J \
          "https://www.youtube.com/watch?v=$video_id" \
          2>/dev/null \
          | jq -r '.related_playlists.uploads // empty')

        if [[ -n "$related_playlist" ]]; then
          normalize_playlist_url "https://www.youtube.com/playlist?list=$related_playlist" >> "$QUEUE"
        fi
      done
}

if [[ "${1:-}" == "--version" ]]; then
  echo "$SCRIPT_NAME $SCRIPT_VERSION"
  exit 0
fi

echo "$SCRIPT_NAME $SCRIPT_VERSION"

verify_requirements || exit 1

touch "$SEEN"
touch "$QUEUE"

# Seed queue from the first argument when one is provided.
if [[ -n "${1:-}" ]]; then
  normalize_playlist_url "$1" > "$QUEUE"
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
    echo "Error: yt-dlp failed for playlist: $PL" >&2
    echo "The playlist was left at the front of the queue for retry." >&2
    exit "$status"
  fi

  printf '%s\n' "$PL" >> "$SEEN"
  remove_first_queue_item

  enqueue_related_playlists "$PL"

  sort -u "$QUEUE" -o "$QUEUE"

done
