#!/usr/bin/env bats

setup() {
    TEST_DIR="$(mktemp -d)"
    BIN_DIR="$TEST_DIR/bin"
    YT_DIR="$TEST_DIR/yt"
    OUTPUT_DIR="$TEST_DIR/output"
    SCRIPT_SOURCE="$BATS_TEST_DIRNAME/../../yt/yt-dlp-script-auto-playlist.sh"
    SCRIPT="$YT_DIR/yt-dlp-script-auto-playlist.sh"
    SCRIPT_VERSION="$(grep -m1 '^SCRIPT_VERSION=' "$SCRIPT_SOURCE" | cut -d'"' -f2)"
    SCRIPT_BUILD_DATE="$(grep -m1 '^SCRIPT_BUILD_DATE=' "$SCRIPT_SOURCE" | cut -d'"' -f2)"
    SCRIPT_IDENTITY="yt-dlp-script-auto-playlist.sh $SCRIPT_VERSION (built $SCRIPT_BUILD_DATE)"
    SYSTEM_JQ="$(command -v jq)"

    mkdir -p "$BIN_DIR" "$YT_DIR" "$OUTPUT_DIR"
    cp "$SCRIPT_SOURCE" "$SCRIPT"
    chmod +x "$SCRIPT"

    cat > "$BIN_DIR/node" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

    ln -s "$SYSTEM_JQ" "$BIN_DIR/jq"

    chmod +x "$BIN_DIR/node"
}

teardown() {
    rm -rf "$TEST_DIR"
}

@test "yt auto-playlist: version flag prints script version" {
    run "$SCRIPT" --version

    [ "$status" -eq 0 ]
    [ "$output" = "$SCRIPT_IDENTITY" ]
}

@test "yt auto-playlist: no arguments print help and version info" {
    run env PATH="$BIN_DIR:$PATH" "$SCRIPT"

    [ "$status" -eq 0 ]
    grep -F "$SCRIPT_IDENTITY" <<< "$output"
    grep -F 'Usage:' <<< "$output"
    grep -F 'Git status:' <<< "$output"
    grep -F 'unavailable (script is not in a git worktree)' <<< "$output"
    grep -F -- '--rebuild-local-index [dir]' <<< "$output"
    grep -F "$SCRIPT_IDENTITY exit 0" <<< "$output"
}

@test "yt auto-playlist: help resolves git status through a symlinked entrypoint" {
    REPO_ROOT="$TEST_DIR/repo"
    REAL_SCRIPT="$REPO_ROOT/yt/yt-dlp-script-auto-playlist.sh"
    SYMLINK_SCRIPT="$TEST_DIR/bin/yt-auto-playlist"

    mkdir -p "$REPO_ROOT/yt"
    cp "$SCRIPT_SOURCE" "$REAL_SCRIPT"
    chmod +x "$REAL_SCRIPT"

    git init -b main "$REPO_ROOT" >/dev/null
    git -C "$REPO_ROOT" config user.name 'Test User'
    git -C "$REPO_ROOT" config user.email 'test@example.com'
    git -C "$REPO_ROOT" add yt/yt-dlp-script-auto-playlist.sh
    git -C "$REPO_ROOT" commit -m 'Add script fixture' >/dev/null

    ln -s "$REAL_SCRIPT" "$SYMLINK_SCRIPT"

    run env PATH="$BIN_DIR:$PATH" "$SYMLINK_SCRIPT"

    [ "$status" -eq 0 ]
    grep -F 'Git status:' <<< "$output"
    grep -F 'branch main has no upstream configured' <<< "$output"
}

@test "yt auto-playlist: yt-dlp version check surfaces command failure details" {
    cat > "$BIN_DIR/yt-dlp" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "--version" ]]; then
    echo "bad interpreter: /missing/python" >&2
    exit 126
fi
exit 0
EOF
    chmod +x "$BIN_DIR/yt-dlp"

    run env PATH="$BIN_DIR:$PATH" RETRY_COUNT=1 RETRY_BACKOFF_SECONDS=0 "$SCRIPT" 'https://www.youtube.com/playlist?list=PLBROKEN'

    [ "$status" -eq 1 ]
    grep -F 'Error: unable to determine yt-dlp version.' <<< "$output"
    grep -F 'yt-dlp --version output: bad interpreter: /missing/python' <<< "$output"
}

@test "yt auto-playlist: failed download stays queued for retry" {
    cat > "$BIN_DIR/yt-dlp" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "--version" ]]; then
    echo "2026.03.17"
    exit 0
fi
if [[ "$1" == "--js-runtimes" ]]; then
    shift 2
fi
if [[ "$1" == "--flat-playlist" ]]; then
    printf '{"entries":[]}\n'
    exit 0
fi
if [[ "$1" == "-J" ]]; then
    printf '{"related_playlists":{"uploads":""}}\n'
    exit 0
fi
if [[ "$1" == "--yes-playlist" ]]; then
    exit 137
fi
exit 0
EOF
    chmod +x "$BIN_DIR/yt-dlp"

    run env PATH="$BIN_DIR:$PATH" RETRY_COUNT=1 RETRY_BACKOFF_SECONDS=0 "$SCRIPT" 'https://www.youtube.com/watch?v=jn6ZnlgfnO4&list=PLDIoUOhQQPlXbO7j5xIlWgqLS_-OUNysq'

    [ "$status" -eq 137 ]
    grep -F 'Error: yt-dlp failed for playlist: https://www.youtube.com/playlist?list=PLDIoUOhQQPlXbO7j5xIlWgqLS_-OUNysq (exit code 137)' <<< "$output"
    grep -F 'Likely cause: at least one playlist item failed or a post-download health check returned an error.' <<< "$output"
    grep -F 'Summary: playlists completed 0, partial failures skipped 0, fatal failures 1' <<< "$output"
    grep -F "$SCRIPT_IDENTITY exit 137" <<< "$output"
    grep -Fxq 'https://www.youtube.com/playlist?list=PLDIoUOhQQPlXbO7j5xIlWgqLS_-OUNysq' "$YT_DIR/playlist_queue.txt"
    [ ! -s "$YT_DIR/seen_playlists.txt" ]
}

@test "yt auto-playlist: exit code 1 continues to the next playlist" {
    cat > "$BIN_DIR/yt-dlp" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "--version" ]]; then
    echo "2026.03.17"
    exit 0
fi
if [[ "$1" == "--js-runtimes" ]]; then
    shift 2
fi
if [[ "$1" == "--flat-playlist" ]]; then
    if [[ "$3" == 'https://www.youtube.com/playlist?list=PLSEED123' ]]; then
        printf '{"entries":[{"id":"seed-video"}]}'
    else
        printf '{"entries":[]}'
    fi
    exit 0
fi
if [[ "$1" == "-J" ]]; then
    if [[ "$2" == 'https://www.youtube.com/watch?v=seed-video' ]]; then
        printf '{"related_playlists":{"uploads":"","mix":"RDseed-video"}}\n'
    else
        printf '{"related_playlists":{"uploads":""}}\n'
    fi
    exit 0
fi
if [[ "$1" == "--yes-playlist" ]]; then
    if [[ "${*: -1}" == 'https://www.youtube.com/playlist?list=PLSEED123' ]]; then
        exit 1
    fi
    exit 0
fi
exit 0
EOF
    chmod +x "$BIN_DIR/yt-dlp"

    run env PATH="$BIN_DIR:$PATH" RETRY_COUNT=1 RETRY_BACKOFF_SECONDS=0 "$SCRIPT" 'https://www.youtube.com/playlist?list=PLSEED123'

    [ "$status" -eq 0 ]
    grep -F 'Warning: yt-dlp reported partial failures for playlist: https://www.youtube.com/playlist?list=PLSEED123 (exit code 1)' <<< "$output"
    grep -F 'Continuing to the next playlist because exit code 1 usually means one or more playlist entries failed.' <<< "$output"
    grep -F '▶ Playlist: https://www.youtube.com/watch?v=seed-video&list=RDseed-video&start_radio=1' <<< "$output"
    grep -F 'Summary: playlists completed 1, partial failures skipped 1, fatal failures 0' <<< "$output"
    grep -F "$SCRIPT_IDENTITY exit 0" <<< "$output"
    grep -Fxq 'https://www.youtube.com/playlist?list=PLSEED123' "$YT_DIR/seen_playlists.txt"
    grep -Fxq 'https://www.youtube.com/watch?v=seed-video&list=RDseed-video&start_radio=1' "$YT_DIR/seen_playlists.txt"
    [ ! -s "$YT_DIR/playlist_queue.txt" ]
}

@test "yt auto-playlist: radio watch URLs keep their watch context" {
    cat > "$BIN_DIR/yt-dlp" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "--version" ]]; then
    echo "2026.03.17"
    exit 0
fi
if [[ "$1" == "--js-runtimes" ]]; then
    shift 2
fi
if [[ "$1" == "--flat-playlist" ]]; then
    printf '{"entries":[]}\n'
    exit 0
fi
if [[ "$1" == "-J" ]]; then
    printf '{"related_playlists":{"uploads":""}}\n'
    exit 0
fi
if [[ "$1" == "--yes-playlist" ]]; then
    exit 137
fi
exit 0
EOF
    chmod +x "$BIN_DIR/yt-dlp"

    run env PATH="$BIN_DIR:$PATH" RETRY_COUNT=1 RETRY_BACKOFF_SECONDS=0 "$SCRIPT" 'https://www.youtube.com/watch?v=ETxAvTEL7mo&list=RDETxAvTEL7mo&start_radio=1'

    [ "$status" -eq 137 ]
    grep -Fxq 'https://www.youtube.com/watch?v=ETxAvTEL7mo&list=RDETxAvTEL7mo&start_radio=1' "$YT_DIR/playlist_queue.txt"
    grep -F '▶ Playlist: https://www.youtube.com/watch?v=ETxAvTEL7mo&list=RDETxAvTEL7mo&start_radio=1' <<< "$output"
    [ ! -s "$YT_DIR/seen_playlists.txt" ]
}

@test "yt auto-playlist: enqueues a related mix when uploads playlist is missing" {
    cat > "$BIN_DIR/yt-dlp" <<'EOF'
#!/usr/bin/env bash
LOG_FILE="${TEST_LOG_FILE:?}"
if [[ "$1" == "--version" ]]; then
    echo "2026.03.17"
    exit 0
fi
if [[ "$1" == "--js-runtimes" ]]; then
    shift 2
fi
printf '%s\n' "$*" >> "$LOG_FILE"
if [[ "$1" == "--flat-playlist" ]]; then
    if [[ "$3" == 'https://www.youtube.com/playlist?list=PLSEED123' ]]; then
        printf '{"entries":[{"id":"seed-video"}]}'
    else
        printf '{"entries":[]}'
    fi
    exit 0
fi
if [[ "$1" == "-J" ]]; then
    if [[ "$2" == 'https://www.youtube.com/watch?v=seed-video' ]]; then
        printf '{"related_playlists":{"uploads":"","mix":"RDseed-video"}}\n'
    else
        printf '{"related_playlists":{"uploads":""}}\n'
    fi
    exit 0
fi
if [[ "$1" == "--yes-playlist" ]]; then
    exit 0
fi
exit 0
EOF
    chmod +x "$BIN_DIR/yt-dlp"

    run env PATH="$BIN_DIR:$PATH" TEST_LOG_FILE="$TEST_DIR/yt-dlp-related-mix.log" RETRY_COUNT=1 RETRY_BACKOFF_SECONDS=0 "$SCRIPT" 'https://www.youtube.com/playlist?list=PLSEED123'

    [ "$status" -eq 0 ]
    grep -F '▶ Playlist: https://www.youtube.com/playlist?list=PLSEED123' <<< "$output"
    grep -F '▶ Playlist: https://www.youtube.com/watch?v=seed-video&list=RDseed-video&start_radio=1' <<< "$output"
    grep -F "$SCRIPT_IDENTITY exit 0" <<< "$output"
    grep -Fxq 'https://www.youtube.com/playlist?list=PLSEED123' "$YT_DIR/seen_playlists.txt"
    grep -Fxq 'https://www.youtube.com/watch?v=seed-video&list=RDseed-video&start_radio=1' "$YT_DIR/seen_playlists.txt"
    [ ! -s "$YT_DIR/playlist_queue.txt" ]
}

@test "yt auto-playlist: default downloads target the current directory and create an index" {
    cat > "$BIN_DIR/yt-dlp" <<'EOF'
#!/usr/bin/env bash
LOG_FILE="${TEST_LOG_FILE:?}"
TARGET_FILE="${TEST_TARGET_FILE:?}"
if [[ "$1" == "--version" ]]; then
    echo "2026.03.17"
    exit 0
fi
if [[ "$1" == "--js-runtimes" ]]; then
    shift 2
fi
printf '%s\n' "$*" >> "$LOG_FILE"
if [[ "$1" == "--flat-playlist" ]]; then
    printf '{"entries":[]}\n'
    exit 0
fi
if [[ "$1" == "-J" ]]; then
    printf '{"related_playlists":{"uploads":""}}\n'
    exit 0
fi
if [[ "$1" == "--yes-playlist" ]]; then
    while [[ $# -gt 0 ]]; do
        if [[ "$1" == "--exec" ]]; then
            shift
            exec_command="$1"
            exec_command="${exec_command#after_move:}"
            exec_command="${exec_command//\{\}/$TARGET_FILE}"
            : > "$TARGET_FILE"
            eval "$exec_command"
            exit $?
        fi
        shift
    done
    exit 0
fi
exit 0
EOF
    chmod +x "$BIN_DIR/yt-dlp"

    run env PATH="$BIN_DIR:$PATH" HOME="$TEST_DIR/home" TEST_LOG_FILE="$TEST_DIR/yt-dlp-args.log" TEST_TARGET_FILE="$OUTPUT_DIR/001-Example.mp3" RETRY_COUNT=1 RETRY_BACKOFF_SECONDS=0 bash -lc 'cd "$1" && "$2" "$3"' _ "$OUTPUT_DIR" "$SCRIPT" 'https://www.youtube.com/playlist?list=PLDIoUOhQQPlXbO7j5xIlWgqLS_-OUNysq'

    [ "$status" -eq 0 ]
    grep -F -- "-o $OUTPUT_DIR/%(playlist_index)s - %(title)s.%(ext)s" "$TEST_DIR/yt-dlp-args.log"
    grep -F -- "-x --audio-format mp3" "$TEST_DIR/yt-dlp-args.log"
    grep -F -- "--exec after_move:" "$TEST_DIR/yt-dlp-args.log"
    grep -F "Startup index [local]: $OUTPUT_DIR/yt-dlp-download-index.json (not created yet)" <<< "$output"
    grep -F "Startup index [master]: $TEST_DIR/home/.yt-dlp-download-index.json (not created yet)" <<< "$output"
        grep -F 'Info: no related or recommended playlist was discovered from the first 10 entries of https://www.youtube.com/playlist?list=PLDIoUOhQQPlXbO7j5xIlWgqLS_-OUNysq.' <<< "$output"
    [ -f "$OUTPUT_DIR/yt-dlp-download-index.json" ]
    [ -f "$TEST_DIR/home/.yt-dlp-download-index.json" ]
    [ "$(jq -r '.download_count' "$OUTPUT_DIR/yt-dlp-download-index.json")" -eq 1 ]
    [ "$(jq -r '.downloads[0].path' "$OUTPUT_DIR/yt-dlp-download-index.json")" = "$OUTPUT_DIR/001-Example.mp3" ]
        [ "$(jq -r '.index_scope' "$OUTPUT_DIR/yt-dlp-download-index.json")" = 'local' ]
        [ "$(jq -r '.authoritative' "$OUTPUT_DIR/yt-dlp-download-index.json")" = 'false' ]
    [ "$(jq -r '.download_count' "$TEST_DIR/home/.yt-dlp-download-index.json")" -eq 1 ]
    [ "$(jq -r '.downloads[0].path' "$TEST_DIR/home/.yt-dlp-download-index.json")" = "$OUTPUT_DIR/001-Example.mp3" ]
        [ "$(jq -r '.index_scope' "$TEST_DIR/home/.yt-dlp-download-index.json")" = 'master' ]
        [ "$(jq -r '.authoritative' "$TEST_DIR/home/.yt-dlp-download-index.json")" = 'true' ]
    grep -F 'Summary: playlists completed 1, partial failures skipped 0, fatal failures 0' <<< "$output"
    grep -F "Final index [local]: $OUTPUT_DIR/yt-dlp-download-index.json (downloads 1, playlists 1, updated " <<< "$output"
    grep -F "Final index [master]: $TEST_DIR/home/.yt-dlp-download-index.json (downloads 1, playlists 1, updated " <<< "$output"
}

@test "yt auto-playlist: --video switches yt-dlp to video download mode" {
    cat > "$BIN_DIR/yt-dlp" <<'EOF'
#!/usr/bin/env bash
LOG_FILE="${TEST_LOG_FILE:?}"
if [[ "$1" == "--version" ]]; then
    echo "2026.03.17"
    exit 0
fi
if [[ "$1" == "--js-runtimes" ]]; then
    shift 2
fi
printf '%s\n' "$*" >> "$LOG_FILE"
if [[ "$1" == "--flat-playlist" ]]; then
    printf '{"entries":[]}\n'
    exit 0
fi
if [[ "$1" == "-J" ]]; then
    printf '{"related_playlists":{"uploads":""}}\n'
    exit 0
fi
if [[ "$1" == "--yes-playlist" ]]; then
    exit 0
fi
exit 0
EOF
    chmod +x "$BIN_DIR/yt-dlp"

    run env PATH="$BIN_DIR:$PATH" TEST_LOG_FILE="$TEST_DIR/yt-dlp-video-mode.log" RETRY_COUNT=1 RETRY_BACKOFF_SECONDS=0 DOWNLOAD_DIR="$OUTPUT_DIR" "$SCRIPT" --video 'https://www.youtube.com/playlist?list=PLDIoUOhQQPlXbO7j5xIlWgqLS_-OUNysq'

    [ "$status" -eq 0 ]
    grep -F -- "--yes-playlist -f bv*+ba/b --merge-output-format mp4" "$TEST_DIR/yt-dlp-video-mode.log"
    ! grep -F -- "-x --audio-format mp3" "$TEST_DIR/yt-dlp-video-mode.log"
}

@test "yt auto-playlist: rebuild-local-index recreates the local non-authoritative index from the master index" {
        mkdir -p "$TEST_DIR/home" "$OUTPUT_DIR"

        cat > "$TEST_DIR/home/.yt-dlp-download-index.json" <<EOF
{
    "index_scope": "master",
    "authoritative": true,
    "script_version": "$SCRIPT_VERSION",
    "created_at": "2026-05-18T10:00:00Z",
    "updated_at": "2026-05-18T10:00:00Z",
    "download_count": 3,
    "downloads": [
        {
            "downloaded_at": "2026-05-18T10:00:00Z",
            "path": "$OUTPUT_DIR/001-First.mp3",
            "file_name": "001-First.mp3",
            "size_bytes": 1,
            "playlist_url": "https://www.youtube.com/playlist?list=PLTARGET"
        },
        {
            "downloaded_at": "2026-05-18T10:01:00Z",
            "path": "$OUTPUT_DIR/002-Second.mp3",
            "file_name": "002-Second.mp3",
            "size_bytes": 2,
            "playlist_url": "https://www.youtube.com/playlist?list=PLTARGET"
        },
        {
            "downloaded_at": "2026-05-18T10:02:00Z",
            "path": "$TEST_DIR/elsewhere/003-Other.mp3",
            "file_name": "003-Other.mp3",
            "size_bytes": 3,
            "playlist_url": "https://www.youtube.com/playlist?list=PLOTHER"
        }
    ]
}
EOF

        run env PATH="$BIN_DIR:$PATH" HOME="$TEST_DIR/home" DOWNLOAD_DIR="$OUTPUT_DIR" "$SCRIPT" --rebuild-local-index "$OUTPUT_DIR"

        [ "$status" -eq 0 ]
        [ -f "$OUTPUT_DIR/yt-dlp-download-index.json" ]
        [ "$(jq -r '.index_scope' "$OUTPUT_DIR/yt-dlp-download-index.json")" = 'local' ]
        [ "$(jq -r '.authoritative' "$OUTPUT_DIR/yt-dlp-download-index.json")" = 'false' ]
        [ "$(jq -r '.source_master_index' "$OUTPUT_DIR/yt-dlp-download-index.json")" = "$TEST_DIR/home/.yt-dlp-download-index.json" ]
        [ "$(jq -r '.download_count' "$OUTPUT_DIR/yt-dlp-download-index.json")" -eq 2 ]
        [ "$(jq -r '.downloads[0].path' "$OUTPUT_DIR/yt-dlp-download-index.json")" = "$OUTPUT_DIR/001-First.mp3" ]
        [ "$(jq -r '.downloads[1].path' "$OUTPUT_DIR/yt-dlp-download-index.json")" = "$OUTPUT_DIR/002-Second.mp3" ]
        grep -F "Rebuilt local index from master: $OUTPUT_DIR/yt-dlp-download-index.json" <<< "$output"
        grep -F "Final index [local]: $OUTPUT_DIR/yt-dlp-download-index.json (downloads 2, playlists 1, updated " <<< "$output"
}

@test "yt auto-playlist: playlist directory mode writes into a playlist subdirectory" {
    cat > "$BIN_DIR/yt-dlp" <<'EOF'
#!/usr/bin/env bash
LOG_FILE="${TEST_LOG_FILE:?}"
if [[ "$1" == "--version" ]]; then
    echo "2026.03.17"
    exit 0
fi
if [[ "$1" == "--js-runtimes" ]]; then
    shift 2
fi
printf '%s\n' "$*" >> "$LOG_FILE"
if [[ "$1" == "--flat-playlist" ]]; then
    printf '{"entries":[]}\n'
    exit 0
fi
if [[ "$1" == "-J" ]]; then
    printf '{"related_playlists":{"uploads":""}}\n'
    exit 0
fi
if [[ "$1" == "--yes-playlist" ]]; then
    exit 0
fi
exit 0
EOF
    chmod +x "$BIN_DIR/yt-dlp"

    run env PATH="$BIN_DIR:$PATH" TEST_LOG_FILE="$TEST_DIR/yt-dlp-playlist-mode.log" DIRECTORY_MODE=playlist RETRY_COUNT=1 RETRY_BACKOFF_SECONDS=0 DOWNLOAD_DIR="$OUTPUT_DIR" "$SCRIPT" 'https://www.youtube.com/playlist?list=PLDIoUOhQQPlXbO7j5xIlWgqLS_-OUNysq'

    [ "$status" -eq 0 ]
    grep -F -- "-o $OUTPUT_DIR/%(playlist_title)s/%(playlist_index)s - %(title)s.%(ext)s" "$TEST_DIR/yt-dlp-playlist-mode.log"
}

@test "yt auto-playlist: max files per directory selects the next batch folder" {
    mkdir -p "$OUTPUT_DIR/batch-001"
    : > "$OUTPUT_DIR/batch-001/existing.mp3"

    cat > "$BIN_DIR/yt-dlp" <<'EOF'
#!/usr/bin/env bash
LOG_FILE="${TEST_LOG_FILE:?}"
if [[ "$1" == "--version" ]]; then
    echo "2026.03.17"
    exit 0
fi
if [[ "$1" == "--js-runtimes" ]]; then
    shift 2
fi
printf '%s\n' "$*" >> "$LOG_FILE"
if [[ "$1" == "--flat-playlist" ]]; then
    printf '{"entries":[]}\n'
    exit 0
fi
if [[ "$1" == "-J" ]]; then
    printf '{"related_playlists":{"uploads":""}}\n'
    exit 0
fi
if [[ "$1" == "--yes-playlist" ]]; then
    exit 0
fi
exit 0
EOF
    chmod +x "$BIN_DIR/yt-dlp"

    run env PATH="$BIN_DIR:$PATH" TEST_LOG_FILE="$TEST_DIR/yt-dlp-batch-mode.log" MAX_FILES_PER_DIR=1 RETRY_COUNT=1 RETRY_BACKOFF_SECONDS=0 DOWNLOAD_DIR="$OUTPUT_DIR" "$SCRIPT" 'https://www.youtube.com/playlist?list=PLDIoUOhQQPlXbO7j5xIlWgqLS_-OUNysq'

    [ "$status" -eq 0 ]
    grep -F -- "-o $OUTPUT_DIR/batch-002/%(playlist_index)s - %(title)s.%(ext)s" "$TEST_DIR/yt-dlp-batch-mode.log"
}

@test "yt auto-playlist: health check stops downloads when disk space is below threshold" {
    cat > "$BIN_DIR/yt-dlp" <<'EOF'
#!/usr/bin/env bash
TARGET_FILE="${TEST_TARGET_FILE:?}"
if [[ "$1" == "--version" ]]; then
    echo "2026.03.17"
    exit 0
fi
if [[ "$1" == "--js-runtimes" ]]; then
    shift 2
fi
if [[ "$1" == "--flat-playlist" ]]; then
    printf '{"entries":[]}\n'
    exit 0
fi
if [[ "$1" == "-J" ]]; then
    printf '{"related_playlists":{"uploads":""}}\n'
    exit 0
fi
if [[ "$1" == "--yes-playlist" ]]; then
    shift
    while [[ $# -gt 0 ]]; do
        if [[ "$1" == "--exec" ]]; then
            shift
            exec_command="$1"
            exec_command="${exec_command#after_move:}"
            exec_command="${exec_command//\{\}/$TARGET_FILE}"
            : > "$TARGET_FILE"
            eval "$exec_command"
            exit $?
        fi
        shift
    done
fi
exit 0
EOF
    chmod +x "$BIN_DIR/yt-dlp"

    run env PATH="$BIN_DIR:$PATH" TEST_TARGET_FILE="$OUTPUT_DIR/001-Example.mp3" RETRY_COUNT=1 RETRY_BACKOFF_SECONDS=0 HEALTH_CHECK_INTERVAL_SECONDS=0 MIN_FREE_SPACE_MB=99999999 DOWNLOAD_DIR="$OUTPUT_DIR" "$SCRIPT" 'https://www.youtube.com/playlist?list=PLDIoUOhQQPlXbO7j5xIlWgqLS_-OUNysq'

    [ "$status" -ne 0 ]
    grep -E '@@@@ [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} HEALTH ERROR: free disk space' <<< "$output"
    grep -F 'The playlist was left at the front of the queue for retry.' <<< "$output"
}

@test "yt auto-playlist: health check prints runtime stats and removable-drive warning on macOS" {
    cat > "$BIN_DIR/uname" <<'EOF'
#!/usr/bin/env bash
echo "Darwin"
EOF

    cat > "$BIN_DIR/diskutil" <<'EOF'
#!/usr/bin/env bash
cat <<'OUT'
   Volume Name: External SSD
   Protocol: USB
   Ejectable: Yes
OUT
EOF

    cat > "$BIN_DIR/yt-dlp" <<'EOF'
#!/usr/bin/env bash
TARGET_FILE="${TEST_TARGET_FILE:?}"
if [[ "$1" == "--version" ]]; then
    echo "2026.03.17"
    exit 0
fi
if [[ "$1" == "--js-runtimes" ]]; then
    shift 2
fi
if [[ "$1" == "--flat-playlist" ]]; then
    printf '{"entries":[]}\n'
    exit 0
fi
if [[ "$1" == "-J" ]]; then
    printf '{"related_playlists":{"uploads":""}}\n'
    exit 0
fi
if [[ "$1" == "--yes-playlist" ]]; then
    shift
    while [[ $# -gt 0 ]]; do
        if [[ "$1" == "--exec" ]]; then
            shift
            exec_command="$1"
            exec_command="${exec_command#after_move:}"
            exec_command="${exec_command//\{\}/$TARGET_FILE}"
            : > "$TARGET_FILE"
            eval "$exec_command"
            exit $?
        fi
        shift
    done
fi
exit 0
EOF

    chmod +x "$BIN_DIR/uname" "$BIN_DIR/diskutil" "$BIN_DIR/yt-dlp"

    run env PATH="$BIN_DIR:$PATH" TEST_TARGET_FILE="$OUTPUT_DIR/001-Example.mp3" RETRY_COUNT=1 RETRY_BACKOFF_SECONDS=0 HEALTH_CHECK_INTERVAL_SECONDS=0 DOWNLOAD_DIR="$OUTPUT_DIR" SCRIPT_START_EPOCH=0 "$SCRIPT" 'https://www.youtube.com/playlist?list=PLDIoUOhQQPlXbO7j5xIlWgqLS_-OUNysq'

    [ "$status" -eq 0 ]
    grep -E '@@@@ [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} HEALTH: flushing writes for ' <<< "$output"
    grep -E '@@@@ [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} HEALTH: disk free ' <<< "$output"
    grep -E '@@@@ [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} HEALTH WARNING: ' <<< "$output"
    grep -E '@@@@ [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} HEALTH: downloaded 1 files, directory contains 2 files, runtime ' <<< "$output"
    grep -F 'External SSD' <<< "$output"
}

@test "yt auto-playlist: retries before succeeding" {
    cat > "$BIN_DIR/yt-dlp" <<'EOF'
#!/usr/bin/env bash
STATE_FILE="${TEST_STATE_FILE:?}"
if [[ "$1" == "--version" ]]; then
    echo "2026.03.17"
    exit 0
fi
if [[ "$1" == "--js-runtimes" ]]; then
    shift 2
fi
if [[ "$1" == "--flat-playlist" ]]; then
    printf '{"entries":[]}\n'
    exit 0
fi
if [[ "$1" == "-J" ]]; then
    printf '{"related_playlists":{"uploads":""}}\n'
    exit 0
fi
if [[ "$1" == "--yes-playlist" ]]; then
    count=0
    if [[ -f "$STATE_FILE" ]]; then
        count=$(cat "$STATE_FILE")
    fi
    count=$((count + 1))
    printf '%s\n' "$count" > "$STATE_FILE"
    if [[ "$count" -lt 2 ]]; then
        exit 1
    fi
    exit 0
fi
exit 0
EOF
    chmod +x "$BIN_DIR/yt-dlp"

    run env PATH="$BIN_DIR:$PATH" TEST_STATE_FILE="$TEST_DIR/download-attempts" RETRY_COUNT=2 RETRY_BACKOFF_SECONDS=0 "$SCRIPT" 'https://www.youtube.com/playlist?list=PLDIoUOhQQPlXbO7j5xIlWgqLS_-OUNysq'

    [ "$status" -eq 0 ]
    [ "$(cat "$TEST_DIR/download-attempts")" -eq 2 ]
    grep -Fxq 'https://www.youtube.com/playlist?list=PLDIoUOhQQPlXbO7j5xIlWgqLS_-OUNysq' "$YT_DIR/seen_playlists.txt"
    [ ! -s "$YT_DIR/playlist_queue.txt" ]
}

@test "yt auto-playlist: requirement checks are cached for the same day" {
    cat > "$BIN_DIR/yt-dlp" <<'EOF'
#!/usr/bin/env bash
LOG_FILE="${TEST_LOG_FILE:?}"
if [[ "$1" == "--version" ]]; then
    printf 'version\n' >> "$LOG_FILE"
    echo "2026.03.17"
    exit 0
fi
if [[ "$1" == "--js-runtimes" ]]; then
    shift 2
fi
if [[ "$1" == "--flat-playlist" ]]; then
    printf '{"entries":[]}\n'
    exit 0
fi
if [[ "$1" == "-J" ]]; then
    printf '{"related_playlists":{"uploads":""}}\n'
    exit 0
fi
if [[ "$1" == "--yes-playlist" ]]; then
    exit 0
fi
exit 0
EOF
    chmod +x "$BIN_DIR/yt-dlp"

    run env PATH="$BIN_DIR:$PATH" TEST_LOG_FILE="$TEST_DIR/yt-dlp.log" "$SCRIPT" 'https://www.youtube.com/playlist?list=PLCACHE123'
    [ "$status" -eq 0 ]

    run env PATH="$BIN_DIR:$PATH" TEST_LOG_FILE="$TEST_DIR/yt-dlp.log" "$SCRIPT" 'https://www.youtube.com/playlist?list=PLCACHE123'
    [ "$status" -eq 0 ]
    grep -Fxq "Using cached requirement check for $(date +%F)." <<< "$output"
    [ "$(grep -c '^version$' "$TEST_DIR/yt-dlp.log")" -eq 1 ]
}
