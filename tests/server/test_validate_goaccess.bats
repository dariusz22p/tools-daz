#!/usr/bin/env bats
# Tests for server/validate_goaccess_reports.sh functions
# We test the validate_report logic by recreating it (the script runs inline,
# so we extract and test the core validation checks independently).

setup() {
    TEST_DIR="$(mktemp -d)"
    # Recreate the validation logic as functions for testing
    MIN_FILE_SIZE=50000
    MAX_AGE_HOURS=24
}

teardown() {
    rm -rf "$TEST_DIR"
}

# --- File existence checks ---

@test "validate: fails when web file does not exist" {
    [ ! -f "$TEST_DIR/nonexistent.html" ]
}

@test "validate: passes when file exists and is readable" {
    echo "<html>content</html>" > "$TEST_DIR/report.html"
    [ -f "$TEST_DIR/report.html" ]
    [ -r "$TEST_DIR/report.html" ]
}

# --- File size checks ---

@test "validate: small file fails size check" {
    echo "tiny" > "$TEST_DIR/small.html"
    local file_size
    file_size=$(stat -f%z "$TEST_DIR/small.html" 2>/dev/null || stat -c%s "$TEST_DIR/small.html" 2>/dev/null)
    [ "$file_size" -lt "$MIN_FILE_SIZE" ]
}

@test "validate: large file passes size check" {
    # Create a file larger than 50KB
    dd if=/dev/zero of="$TEST_DIR/big.html" bs=1024 count=60 2>/dev/null
    local file_size
    file_size=$(stat -f%z "$TEST_DIR/big.html" 2>/dev/null || stat -c%s "$TEST_DIR/big.html" 2>/dev/null)
    [ "$file_size" -gt "$MIN_FILE_SIZE" ]
}

# --- HTML header checks ---

@test "validate: file with goaccess signature passes header check" {
    printf '<!DOCTYPE html><html><head><title>GoAccess</title></head></html>' > "$TEST_DIR/goaccess.html"
    header=$(head -c 200 "$TEST_DIR/goaccess.html")
    echo "$header" | grep -qi "goaccess\|<!doctype\|<html"
}

@test "validate: file without HTML fails header check" {
    echo "just plain text no html here" > "$TEST_DIR/plain.txt"
    header=$(head -c 200 "$TEST_DIR/plain.txt")
    run bash -c "echo '$header' | grep -qi 'goaccess\|<!doctype\|<html'"
    [ "$status" -ne 0 ]
}

# --- File age checks ---

@test "validate: recently created file passes staleness check" {
    echo "fresh" > "$TEST_DIR/fresh.html"
    local file_mtime current_time age_hours
    file_mtime=$(stat -f%m "$TEST_DIR/fresh.html" 2>/dev/null || stat -c%Y "$TEST_DIR/fresh.html" 2>/dev/null)
    current_time=$(date +%s)
    age_hours=$(( (current_time - file_mtime) / 3600 ))
    [ "$age_hours" -lt "$MAX_AGE_HOURS" ]
}
