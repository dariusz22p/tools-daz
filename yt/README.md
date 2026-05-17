# YouTube Playlist Downloader

`yt-dlp-script-auto-playlist.sh` downloads audio from YouTube playlists, keeps a queue of related playlists, and periodically runs health checks while it is processing files.

## What it does

- Downloads playlist entries as MP3 files with `yt-dlp`
- Stores files in the current working directory by default
- Keeps a JSON index of completed downloads in `yt-dlp-download-index.json`
- Tracks processed playlists in `seen_playlists.txt`
- Stores queued playlists in `playlist_queue.txt`
- Flushes writes and prints periodic health stats
- Warns when the destination is on a removable drive on macOS
- Stops if free disk space drops below the configured safety threshold

## Requirements

The script checks for these tools before downloading:

- `yt-dlp`
- `jq`
- `node`

Minimum supported `yt-dlp` version: `2025.01.15`

## Usage

Run from the directory where you want the MP3 files to be written:

```bash
cd /path/to/output
/path/to/repo/yt/yt-dlp-script-auto-playlist.sh 'https://www.youtube.com/playlist?list=YOUR_PLAYLIST_ID'
```

Show the script version:

```bash
./yt/yt-dlp-script-auto-playlist.sh --version
```

## Files created

- `*.mp3` in the current working directory by default
- `yt-dlp-download-index.json` with download metadata and counters
- `seen_playlists.txt` in the `yt/` directory
- `playlist_queue.txt` in the `yt/` directory
- `.yt-dlp-script-auto-playlist.requirements.cache` in the `yt/` directory

## Health checks

By default, the script performs a health check every 120 seconds while files are being completed.

Each health check:

- Runs `sync` to flush pending writes
- Prints free disk space for the target directory
- Prints memory usage
- Prints how many files were downloaded
- Prints how many regular files are in the target directory
- Prints total runtime
- Warns if the target is a removable macOS volume
- Aborts if free space is below the configured threshold

## Environment variables

- `DOWNLOAD_DIR`: default current working directory. Where downloaded MP3 files are written.
- `DOWNLOAD_INDEX_FILE`: default `$DOWNLOAD_DIR/yt-dlp-download-index.json`. JSON index file for completed downloads.
- `RETRY_COUNT`: default `3`. Number of download attempts per playlist.
- `RETRY_BACKOFF_SECONDS`: default `5`. Linear retry backoff multiplier.
- `MIN_YTDLP_VERSION`: default `2025.01.15`. Minimum supported `yt-dlp` version.
- `HEALTH_CHECK_INTERVAL_SECONDS`: default `120`. Minimum time between full health checks.
- `MIN_FREE_SPACE_MB`: default `2048`. Minimum free disk space before aborting.
- `SCRIPT_START_EPOCH`: default current epoch at launch. Used to calculate runtime in health output.

## Tests

Run the focused test file for this script with:

```bash
bats tests/yt/test_yt_dlp_script_auto_playlist.bats
```
