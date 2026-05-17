#!/usr/bin/env bash
# Version: 1.2.2

SCRIPT_VERSION="1.2.2"
export YTDLP_JSRUNTIMES="node"

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
ARCHIVE="$SCRIPT_DIR/../archive.txt"
SEEN="$SCRIPT_DIR/seen_playlists.txt"
QUEUE="$SCRIPT_DIR/playlist_queue.txt"
DOWNLOAD_DIR="${DOWNLOAD_DIR:-$REPO_DIR/downloads/yt}"
REQUIREMENTS_CACHE="$SCRIPT_DIR/.yt-dlp-script-auto-playlist.requirements.cache"
RETRY_COUNT="${RETRY_COUNT:-3}"
RETRY_BACKOFF_SECONDS="${RETRY_BACKOFF_SECONDS:-5}"
MIN_YTDLP_VERSION="${MIN_YTDLP_VERSION:-2025.01.15}"
HEALTH_CHECK_INTERVAL_SECONDS="${HEALTH_CHECK_INTERVAL_SECONDS:-120}"
MIN_FREE_SPACE_MB="${MIN_FREE_SPACE_MB:-2048}"

get_available_disk_mb() {
  local target_dir="$1"
  local available_kb

  available_kb="$(df -Pk "$target_dir" | awk 'NR==2 {print $4}')"
  [[ "$available_kb" =~ ^[0-9]+$ ]] || return 1

  printf '%s\n' $((available_kb / 1024))
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

    echo "Health check: memory used ${used_mb}MB / ${total_mb}MB, free ${free_mb}MB"
    return 0
  fi

  if command -v free >/dev/null 2>&1; then
    free -m | awk 'NR==2 {printf "Health check: memory used %sMB / %sMB, free %sMB\n", $3, $2, $7}'
    return 0
  fi

  echo "Health check: memory stats unavailable on this system"
}

run_health_check() {
  local target_dir="$1"
  local state_file="$2"
  local now
  local last_run=0
  local interval
  local available_mb

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

  echo "Health check: flushing writes for $target_dir"
  sync

  available_mb="$(get_available_disk_mb "$target_dir")" || {
    echo "Error: unable to determine free disk space for $target_dir" >&2
    return 1
  }

  echo "Health check: disk free ${available_mb}MB at $target_dir"
  print_memory_health

  if [[ "${MIN_FREE_SPACE_MB:-2048}" =~ ^[0-9]+$ ]] && (( available_mb < MIN_FREE_SPACE_MB )); then
    echo "Error: free disk space ${available_mb}MB is below safety threshold ${MIN_FREE_SPACE_MB}MB at $target_dir" >&2
    return 1
  fi
}

create_health_check_hook() {
  local hook_script="$1"

  cat > "$hook_script" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

get_available_disk_mb() {
  local target_dir="$1"
  local available_kb

  available_kb="$(df -Pk "$target_dir" | awk 'NR==2 {print $4}')"
  [[ "$available_kb" =~ ^[0-9]+$ ]] || return 1

  printf '%s\n' $((available_kb / 1024))
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

    echo "Health check: memory used ${used_mb}MB / ${total_mb}MB, free ${free_mb}MB"
    return 0
  fi

  if command -v free >/dev/null 2>&1; then
    free -m | awk 'NR==2 {printf "Health check: memory used %sMB / %sMB, free %sMB\n", $3, $2, $7}'
    return 0
  fi

  echo "Health check: memory stats unavailable on this system"
}

run_health_check() {
  local target_dir="$1"
  local state_file="$2"
  local now
  local last_run=0
  local interval
  local available_mb

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

  echo "Health check: flushing writes for $target_dir"
  sync

  available_mb="$(get_available_disk_mb "$target_dir")" || {
    echo "Error: unable to determine free disk space for $target_dir" >&2
    exit 1
  }

  echo "Health check: disk free ${available_mb}MB at $target_dir"
  print_memory_health

  if [[ "${MIN_FREE_SPACE_MB:-2048}" =~ ^[0-9]+$ ]] && (( available_mb < MIN_FREE_SPACE_MB )); then
    echo "Error: free disk space ${available_mb}MB is below safety threshold ${MIN_FREE_SPACE_MB}MB at $target_dir" >&2
    exit 1
  fi
}

run_health_check "${DOWNLOAD_DIR:?}" "${HEALTH_CHECK_STATE_FILE:?}"
EOF

  chmod +x "$hook_script"
}

normalize_playlist_url() {
  local input_url="$1"
  local list_regex='[?&]list=([^&]+)'

  if [[ "$input_url" =~ $list_regex ]]; then
    printf 'https://www.youtube.com/playlist?list=%s\n' "${BASH_REMATCH[1]}"
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

  yt_dlp_version="$(yt-dlp --version 2>/dev/null)"
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

  mkdir -p "$DOWNLOAD_DIR"
  temp_dir="$(mktemp -d)"
  health_hook="$temp_dir/yt-dlp-health-check.sh"
  health_state_file="$temp_dir/yt-dlp-health-check.state"
  create_health_check_hook "$health_hook"

  trap 'rm -rf "$temp_dir"' RETURN

  while [[ $attempt -le $RETRY_COUNT ]]; do
    DOWNLOAD_DIR="$DOWNLOAD_DIR" \
    HEALTH_CHECK_INTERVAL_SECONDS="$HEALTH_CHECK_INTERVAL_SECONDS" \
    HEALTH_CHECK_STATE_FILE="$health_state_file" \
    MIN_FREE_SPACE_MB="$MIN_FREE_SPACE_MB" \
    yt-dlp --js-runtimes node --yes-playlist -x --audio-format mp3 \
      -o "$DOWNLOAD_DIR/%(playlist_index)s - %(title)s.%(ext)s" \
      --exec "after_move:$health_hook" \
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
