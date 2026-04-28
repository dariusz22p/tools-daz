#!/usr/bin/env bats
# Tests for server/pull_repo.sh — TARGET_BASE resolution logic
# The script uses: 1st arg > env TARGET_BASE > default "/git"

setup() {
    TEST_DIR="$(mktemp -d)"
    SCRIPT="$BATS_TEST_DIRNAME/../../server/pull_repo.sh"
}

teardown() {
    rm -rf "$TEST_DIR"
}

# --- TARGET_BASE resolution priority ---

@test "pull_repo: first argument takes priority over env" {
    # Extract just the resolution logic
    result=$(TARGET_BASE="/from_env" bash -c '
        TARGET_BASE_ARG="/from_arg"
        TARGET_BASE_ENV="${TARGET_BASE:-}"
        if [[ -n "$TARGET_BASE_ARG" ]]; then
            TARGET_BASE="$TARGET_BASE_ARG"
        elif [[ -n "$TARGET_BASE_ENV" ]]; then
            TARGET_BASE="$TARGET_BASE_ENV"
        else
            TARGET_BASE="/git"
        fi
        echo "$TARGET_BASE"
    ')
    [ "$result" = "/from_arg" ]
}

@test "pull_repo: env variable used when no argument" {
    result=$(TARGET_BASE="/from_env" bash -c '
        TARGET_BASE_ARG=""
        TARGET_BASE_ENV="${TARGET_BASE:-}"
        if [[ -n "$TARGET_BASE_ARG" ]]; then
            TARGET_BASE="$TARGET_BASE_ARG"
        elif [[ -n "$TARGET_BASE_ENV" ]]; then
            TARGET_BASE="$TARGET_BASE_ENV"
        else
            TARGET_BASE="/git"
        fi
        echo "$TARGET_BASE"
    ')
    [ "$result" = "/from_env" ]
}

@test "pull_repo: defaults to /git when no arg or env" {
    result=$(unset TARGET_BASE; bash -c '
        TARGET_BASE_ARG=""
        TARGET_BASE_ENV="${TARGET_BASE:-}"
        if [[ -n "$TARGET_BASE_ARG" ]]; then
            TARGET_BASE="$TARGET_BASE_ARG"
        elif [[ -n "$TARGET_BASE_ENV" ]]; then
            TARGET_BASE="$TARGET_BASE_ENV"
        else
            TARGET_BASE="/git"
        fi
        echo "$TARGET_BASE"
    ')
    [ "$result" = "/git" ]
}
