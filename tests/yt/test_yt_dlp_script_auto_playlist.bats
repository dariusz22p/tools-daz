#!/usr/bin/env bats

setup() {
    TEST_DIR="$(mktemp -d)"
    BIN_DIR="$TEST_DIR/bin"
    YT_DIR="$TEST_DIR/yt"
    OUTPUT_DIR="$TEST_DIR/output"
    SCRIPT_SOURCE="$BATS_TEST_DIRNAME/../../yt/yt-dlp-script-auto-playlist.sh"
    SCRIPT="$YT_DIR/yt-dlp-script-auto-playlist.sh"
    SCRIPT_VERSION="$(grep -m1 '^SCRIPT_VERSION=' "$SCRIPT_SOURCE" | cut -d'"' -f2)"
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
    [ "$output" = "yt-dlp-script-auto-playlist.sh $SCRIPT_VERSION" ]
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

    run env PATH="$BIN_DIR:$PATH" RETRY_COUNT=1 RETRY_BACKOFF_SECONDS=0 "$SCRIPT"

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
    grep -Fxq 'https://www.youtube.com/playlist?list=PLDIoUOhQQPlXbO7j5xIlWgqLS_-OUNysq' "$YT_DIR/playlist_queue.txt"
    [ ! -s "$YT_DIR/seen_playlists.txt" ]
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

    run env PATH="$BIN_DIR:$PATH" TEST_LOG_FILE="$TEST_DIR/yt-dlp-args.log" TEST_TARGET_FILE="$OUTPUT_DIR/001-Example.mp3" RETRY_COUNT=1 RETRY_BACKOFF_SECONDS=0 bash -lc 'cd "$1" && "$2" "$3"' _ "$OUTPUT_DIR" "$SCRIPT" 'https://www.youtube.com/playlist?list=PLDIoUOhQQPlXbO7j5xIlWgqLS_-OUNysq'

    [ "$status" -eq 0 ]
    grep -F -- "-o $OUTPUT_DIR/%(playlist_index)s - %(title)s.%(ext)s" "$TEST_DIR/yt-dlp-args.log"
    grep -F -- "--exec after_move:" "$TEST_DIR/yt-dlp-args.log"
    [ -f "$OUTPUT_DIR/yt-dlp-download-index.json" ]
    [ "$(jq -r '.download_count' "$OUTPUT_DIR/yt-dlp-download-index.json")" -eq 1 ]
    [ "$(jq -r '.downloads[0].path' "$OUTPUT_DIR/yt-dlp-download-index.json")" = "$OUTPUT_DIR/001-Example.mp3" ]
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
    grep -F 'below safety threshold' <<< "$output"
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
    grep -F 'Warning: ' <<< "$output"
    grep -F 'downloaded 1 files, directory contains 2 files, runtime ' <<< "$output"
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

    run env PATH="$BIN_DIR:$PATH" TEST_LOG_FILE="$TEST_DIR/yt-dlp.log" "$SCRIPT"
    [ "$status" -eq 0 ]

    run env PATH="$BIN_DIR:$PATH" TEST_LOG_FILE="$TEST_DIR/yt-dlp.log" "$SCRIPT"
    [ "$status" -eq 0 ]
    grep -Fxq "Using cached requirement check for $(date +%F)." <<< "$output"
    [ "$(grep -c '^version$' "$TEST_DIR/yt-dlp.log")" -eq 1 ]
}
