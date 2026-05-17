#!/usr/bin/env bash
# Version: 1.1.0

SCRIPT_VERSION="1.1.0"
export YTDLP_JSRUNTIMES="node"

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ARCHIVE="$SCRIPT_DIR/../archive.txt"
SEEN="$SCRIPT_DIR/seen_playlists.txt"
QUEUE="$SCRIPT_DIR/playlist_queue.txt"

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
  printf '%s\n' "$1" > "$QUEUE"
fi

while true; do
  PL=$(head -n 1 "$QUEUE")

  # if empty, stop
  if [[ -z "$PL" ]]; then
    echo "✅ Queue empty. Done."
    break
  fi

  # remove first item
  tail -n +2 "$QUEUE" > "$QUEUE.tmp" && mv "$QUEUE.tmp" "$QUEUE"

  # skip duplicates
  if grep -Fxq "$PL" "$SEEN"; then
    continue
  fi

  echo "▶ Playlist: $PL"
  printf '%s\n' "$PL" >> "$SEEN"

  yt-dlp --js-runtimes node -x --audio-format mp3 \
    -o "%(playlist_index)s - %(title)s.%(ext)s" \
    --download-archive "$ARCHIVE" \
    "$PL"

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
