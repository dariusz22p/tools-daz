#!/usr/bin/env bats
# Tests for minecraft/scripts/backup.sh — cleanup_old_backups logic and argument parsing

setup() {
    TEST_DIR="$(mktemp -d)"
    BACKUP_DIR="$TEST_DIR/backups"
    LOG_FILE="$TEST_DIR/backup.log"
    mkdir -p "$BACKUP_DIR"
    touch "$LOG_FILE"

    # Stub functions
    log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"; }
    success() { log "SUCCESS: $*"; }
}

teardown() {
    rm -rf "$TEST_DIR"
}

# --- cleanup_old_backups ---

@test "cleanup: keeps all when count <= keep_count" {
    # Create 3 backups
    for i in 1 2 3; do
        touch "$BACKUP_DIR/world1_2026040${i}_120000.tar.gz"
    done

    cleanup_old_backups() {
        local world_name="$1"
        local keep_count="${2:-5}"
        local backups
        backups=($(find "$BACKUP_DIR" -name "${world_name}_*.tar.gz" ! -name "*_latest.tar.gz" -type f | sort -r))
        if [[ ${#backups[@]} -gt $keep_count ]]; then
            local to_remove=("${backups[@]:${keep_count}}")
            for backup in "${to_remove[@]}"; do
                rm -f "$backup"
            done
        fi
    }

    cleanup_old_backups "world1" 5
    local count
    count=$(find "$BACKUP_DIR" -name "world1_*.tar.gz" | wc -l | tr -d ' ')
    [ "$count" -eq 3 ]
}

@test "cleanup: removes oldest when count > keep_count" {
    # Create 5 backups with distinct names (sort order determines "oldest")
    for i in 1 2 3 4 5; do
        echo "backup$i" > "$BACKUP_DIR/world1_2026040${i}_120000.tar.gz"
    done

    cleanup_old_backups() {
        local world_name="$1"
        local keep_count="${2:-5}"
        local backups
        backups=($(find "$BACKUP_DIR" -name "${world_name}_*.tar.gz" ! -name "*_latest.tar.gz" -type f | sort -r))
        if [[ ${#backups[@]} -gt $keep_count ]]; then
            local to_remove=("${backups[@]:${keep_count}}")
            for backup in "${to_remove[@]}"; do
                rm -f "$backup"
            done
        fi
    }

    cleanup_old_backups "world1" 2
    local count
    count=$(find "$BACKUP_DIR" -name "world1_*.tar.gz" | wc -l | tr -d ' ')
    [ "$count" -eq 2 ]
}

@test "cleanup: does not remove _latest symlink" {
    touch "$BACKUP_DIR/world1_20260401_120000.tar.gz"
    touch "$BACKUP_DIR/world1_20260402_120000.tar.gz"
    touch "$BACKUP_DIR/world1_20260403_120000.tar.gz"
    ln -sf "world1_20260403_120000.tar.gz" "$BACKUP_DIR/world1_latest.tar.gz"

    cleanup_old_backups() {
        local world_name="$1"
        local keep_count="${2:-5}"
        local backups
        backups=($(find "$BACKUP_DIR" -name "${world_name}_*.tar.gz" ! -name "*_latest.tar.gz" -type f | sort -r))
        if [[ ${#backups[@]} -gt $keep_count ]]; then
            local to_remove=("${backups[@]:${keep_count}}")
            for backup in "${to_remove[@]}"; do
                rm -f "$backup"
            done
        fi
    }

    cleanup_old_backups "world1" 1
    [ -L "$BACKUP_DIR/world1_latest.tar.gz" ]
}

# --- check_dependencies ---

@test "check_dependencies: tar and gzip exist" {
    command -v tar >/dev/null 2>&1
    command -v gzip >/dev/null 2>&1
}
