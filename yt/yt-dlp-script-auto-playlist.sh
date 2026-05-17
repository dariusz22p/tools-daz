#!/usr/bin/env bash
# Version: 1.1.1

SCRIPT_VERSION="1.1.1"
export YTDLP_JSRUNTIMES="node"

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ARCHIVE="$SCRIPT_DIR/../archive.txt"
SEEN="$SCRIPT_DIR/seen_playlists.txt"
QUEUE="$SCRIPT_DIR/playlist_queue.txt"

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

if [[ "${1:-}" == "--version" ]]; then
  echo "$SCRIPT_NAME $SCRIPT_VERSION"
  exit 0
fi

for command in jq node yt-dlp; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "Error: required command '$command' is not installed or not in PATH." >&2
    exit 1
  fi
done

echo "$SCRIPT_NAME $SCRIPT_VERSION"

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

  yt-dlp --js-runtimes node -x --audio-format mp3 \
    -o "%(playlist_index)s - %(title)s.%(ext)s" \
    --download-archive "$ARCHIVE" \
    "$PL"

  status=$?
  if [[ $status -ne 0 ]]; then
    echo "Error: yt-dlp failed for playlist: $PL" >&2
    echo "The playlist was left at the front of the queue for retry." >&2
    exit "$status"
  fi

  printf '%s\n' "$PL" >> "$SEEN"
  remove_first_queue_item

  # IMPORTANT FIX: get REAL related playlists via video info page
  yt-dlp --js-runtimes node -J "$PL" \
    | jq -r '
        .entries[]?.id
      ' \
    | head -n 10 \
    | while read -r VID; do

        REL=$(yt-dlp --js-runtimes node -J \
          "https://www.youtube.com/watch?v=$VID" \
          2>/dev/null \
          | jq -r '.related_playlists.uploads // empty')

        if [[ -n "$REL" ]]; then
          printf '%s\n' "https://www.youtube.com/playlist?list=$REL" >> "$QUEUE"
        fi
      done

  sort -u "$QUEUE" -o "$QUEUE"

done
