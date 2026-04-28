#!/usr/bin/env bats
# Tests for MacBook/compress-foty-i-video-v3.sh pure functions

setup() {
    # Source only the functions we need by extracting them
    SCRIPT="$BATS_TEST_DIRNAME/../../macbook/compress-foty-i-video-v3.sh"

    # We need bash >=4 variables and the functions. Extract them safely.
    # Set variables the functions depend on
    export ema_alpha=0.2
    export start_time=$(date +%s)
    export ema_overall=0
    export ema_img=0
    export ema_vid=0
    export eta_force=true
    export eta_suppress_sec=0
    export SKIP_AUTO_UPDATE=1

    # Source the functions by extracting them
    eval "$(awk '/^format_duration\(\)/,/^}/' "$SCRIPT")"
    eval "$(awk '/^human_size\(\)/,/^}/' "$SCRIPT")"
    eval "$(awk '/^require_tool\(\)/,/^}/' "$SCRIPT")"
}

# --- format_duration ---

@test "format_duration: 0 seconds" {
    result=$(format_duration 0)
    [ "$result" = "00:00:00" ]
}

@test "format_duration: 59 seconds" {
    result=$(format_duration 59)
    [ "$result" = "00:00:59" ]
}

@test "format_duration: 60 seconds = 1 minute" {
    result=$(format_duration 60)
    [ "$result" = "00:01:00" ]
}

@test "format_duration: 3661 seconds = 1h 1m 1s" {
    result=$(format_duration 3661)
    [ "$result" = "01:01:01" ]
}

@test "format_duration: 86400 seconds = 24h" {
    result=$(format_duration 86400)
    [ "$result" = "24:00:00" ]
}

@test "format_duration: negative seconds treated as 0" {
    result=$(format_duration -5)
    [ "$result" = "00:00:00" ]
}

# --- human_size ---

@test "human_size: 0 bytes" {
    result=$(human_size 0)
    [ "$result" = "0.00B" ]
}

@test "human_size: 1024 bytes = 1K" {
    result=$(human_size 1024)
    [ "$result" = "1.00K" ]
}

@test "human_size: 1048576 bytes = 1M" {
    result=$(human_size 1048576)
    [ "$result" = "1.00M" ]
}

@test "human_size: 1073741824 bytes = 1G" {
    result=$(human_size 1073741824)
    [ "$result" = "1.00G" ]
}

@test "human_size: 500 bytes" {
    result=$(human_size 500)
    [ "$result" = "500.00B" ]
}

@test "human_size: 1536 bytes = 1.50K" {
    result=$(human_size 1536)
    [ "$result" = "1.50K" ]
}

# --- require_tool ---

@test "require_tool: finds existing tool (bash)" {
    run require_tool bash ""
    [ "$status" -eq 0 ]
}

@test "require_tool: fails for nonexistent tool" {
    run require_tool nonexistent_tool_xyz ""
    [ "$status" -eq 1 ]
}

@test "require_tool: prints hint on failure" {
    run require_tool nonexistent_tool_xyz "apt install something"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Install: apt install something"* ]]
}
