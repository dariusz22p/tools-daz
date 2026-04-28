#!/usr/bin/env bats
# Tests for server/generate_goaccess_report.sh functions
# We source individual functions from the script for isolated testing.

setup() {
    TEST_DIR="$(mktemp -d)"
    CACHE_STATE_FILE="$TEST_DIR/cache_state"
    ENABLE_CACHE="true"

    SCRIPT="$BATS_TEST_DIRNAME/../server/generate_goaccess_report.sh"

    # Extract pure functions from the script
    eval "$(awk '/^validate_report\(\)/,/^}/' "$SCRIPT")"
    # Stub logging functions
    warn()  { echo "WARN: $*" >&2; }
    debug() { :; }

    # get_logs_hash uses md5sum/md5 and stat — extract it
    eval "$(awk '/^get_logs_hash\(\)/,/^}/' "$SCRIPT")"
    eval "$(awk '/^needs_regeneration\(\)/,/^}/' "$SCRIPT")"
    eval "$(awk '/^update_cache\(\)/,/^}/' "$SCRIPT")"
}

teardown() {
    rm -rf "$TEST_DIR"
}

# --- validate_report ---

@test "validate_report: fails for nonexistent file" {
    run validate_report "$TEST_DIR/nope.html"
    [ "$status" -ne 0 ]
}

@test "validate_report: fails for empty file" {
    touch "$TEST_DIR/empty.html"
    run validate_report "$TEST_DIR/empty.html"
    [ "$status" -ne 0 ]
}

@test "validate_report: fails for non-HTML content" {
    echo "just plain text, no html tags at all" > "$TEST_DIR/bad.html"
    run validate_report "$TEST_DIR/bad.html"
    [ "$status" -ne 0 ]
}

@test "validate_report: passes for valid HTML report" {
    echo '<html><head><title>GoAccess Report</title></head><body>data</body></html>' > "$TEST_DIR/good.html"
    run validate_report "$TEST_DIR/good.html"
    [ "$status" -eq 0 ]
}

# --- get_logs_hash ---

@test "get_logs_hash: returns non-empty hash for existing file" {
    echo "log line 1" > "$TEST_DIR/access.log"
    result=$(get_logs_hash "$TEST_DIR/access.log")
    [ -n "$result" ]
}

@test "get_logs_hash: same file gives same hash" {
    echo "log data" > "$TEST_DIR/access.log"
    hash1=$(get_logs_hash "$TEST_DIR/access.log")
    hash2=$(get_logs_hash "$TEST_DIR/access.log")
    [ "$hash1" = "$hash2" ]
}

@test "get_logs_hash: different files give different hashes" {
    echo "log A" > "$TEST_DIR/a.log"
    echo "log B" > "$TEST_DIR/b.log"
    hash1=$(get_logs_hash "$TEST_DIR/a.log")
    hash2=$(get_logs_hash "$TEST_DIR/b.log")
    [ "$hash1" != "$hash2" ]
}

# --- needs_regeneration / update_cache ---

@test "needs_regeneration: returns true when no cache file exists" {
    rm -f "$CACHE_STATE_FILE"
    run needs_regeneration "daily" "$TEST_DIR/access.log"
    [ "$status" -eq 0 ]  # 0 = true (needs regen)
}

@test "needs_regeneration: returns false after cache is updated" {
    echo "log data" > "$TEST_DIR/access.log"
    update_cache "daily" "$TEST_DIR/access.log"
    run needs_regeneration "daily" "$TEST_DIR/access.log"
    [ "$status" -eq 1 ]  # 1 = false (cache hit)
}

@test "needs_regeneration: returns true when cache is disabled" {
    ENABLE_CACHE="false"
    echo "data" > "$TEST_DIR/access.log"
    update_cache "daily" "$TEST_DIR/access.log"
    run needs_regeneration "daily" "$TEST_DIR/access.log"
    [ "$status" -eq 0 ]  # 0 = true (cache disabled)
}

@test "update_cache: creates cache state file" {
    echo "data" > "$TEST_DIR/access.log"
    update_cache "daily" "$TEST_DIR/access.log"
    [ -f "$CACHE_STATE_FILE" ]
}

@test "update_cache: stores report type entry" {
    echo "data" > "$TEST_DIR/access.log"
    update_cache "weekly" "$TEST_DIR/access.log"
    grep -q "^weekly:" "$CACHE_STATE_FILE"
}

@test "update_cache: replaces existing entry on second call" {
    echo "data1" > "$TEST_DIR/access.log"
    update_cache "daily" "$TEST_DIR/access.log"
    echo "data2" > "$TEST_DIR/access.log"
    # force mtime change
    sleep 1
    touch "$TEST_DIR/access.log"
    update_cache "daily" "$TEST_DIR/access.log"
    local count
    count=$(grep -c "^daily:" "$CACHE_STATE_FILE")
    [ "$count" -eq 1 ]
}
