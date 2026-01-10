#!/bin/bash
################################################################################
# Minecraft World Backup Script
# Version: 1.0.0
# Description: Backs up Minecraft worlds from /opt/minecraft to repository
# Usage: ./backup.sh [world_name]
################################################################################

set -euo pipefail

SCRIPT_VERSION="1.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="/git/tools-daz"
MINECRAFT_DIR="/opt/minecraft"
BACKUP_DIR="${REPO_ROOT}/minecraft/backups"
LOG_FILE="${REPO_ROOT}/minecraft/backup.log"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

################################################################################
# Functions
################################################################################

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "${LOG_FILE}"
}

error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
    log "ERROR: $*"
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*"
    log "SUCCESS: $*"
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $*"
    log "WARNING: $*"
}

check_dependencies() {
    local deps=("tar" "gzip")
    for cmd in "${deps[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            error "Required command '$cmd' not found"
            exit 1
        fi
    done
}

check_directories() {
    if [[ ! -d "${MINECRAFT_DIR}" ]]; then
        error "Minecraft directory not found: ${MINECRAFT_DIR}"
        exit 1
    fi

    if [[ ! -d "${REPO_ROOT}" ]]; then
        error "Repository root not found: ${REPO_ROOT}"
        exit 1
    fi

    # Create backup directory if it doesn't exist
    mkdir -p "${BACKUP_DIR}"
}

list_worlds() {
    log "Available worlds in ${MINECRAFT_DIR}:"
    find "${MINECRAFT_DIR}" -maxdepth 1 -type d ! -path "${MINECRAFT_DIR}" -exec basename {} \; | sort
}

backup_world() {
    local world_name="$1"
    local world_path="${MINECRAFT_DIR}/${world_name}"
    
    if [[ ! -d "${world_path}" ]]; then
        error "World directory not found: ${world_path}"
        return 1
    fi

    local backup_file="${BACKUP_DIR}/${world_name}_${TIMESTAMP}.tar.gz"
    
    log "Starting backup of world: ${world_name}"
    log "Source: ${world_path}"
    log "Destination: ${backup_file}"
    
    # Calculate size before backup
    local size=$(du -sh "${world_path}" | cut -f1)
    log "World size: ${size}"
    
    # Create compressed backup
    if tar -czf "${backup_file}" -C "${MINECRAFT_DIR}" "${world_name}" 2>> "${LOG_FILE}"; then
        local backup_size=$(du -sh "${backup_file}" | cut -f1)
        success "Backup created: ${backup_file} (${backup_size})"
        
        # Create a latest symlink
        local latest_link="${BACKUP_DIR}/${world_name}_latest.tar.gz"
        ln -sf "$(basename "${backup_file}")" "${latest_link}"
        log "Latest backup link updated: ${latest_link}"
        
        return 0
    else
        error "Failed to create backup for ${world_name}"
        return 1
    fi
}

cleanup_old_backups() {
    local world_name="$1"
    local keep_count="${2:-5}"  # Keep last 5 backups by default
    
    log "Cleaning up old backups for ${world_name}, keeping ${keep_count} most recent"
    
    # Find and remove old backups, keeping the specified number
    local backups=($(find "${BACKUP_DIR}" -name "${world_name}_*.tar.gz" ! -name "*_latest.tar.gz" -type f -printf '%T@ %p\n' | sort -rn | awk '{print $2}'))
    
    if [[ ${#backups[@]} -gt ${keep_count} ]]; then
        local to_remove=("${backups[@]:${keep_count}}")
        for backup in "${to_remove[@]}"; do
            log "Removing old backup: $(basename "${backup}")"
            rm -f "${backup}"
        done
        success "Removed $((${#backups[@]} - ${keep_count})) old backup(s)"
    else
        log "No old backups to remove (found ${#backups[@]}, keeping ${keep_count})"
    fi
}

backup_all_worlds() {
    local success_count=0
    local fail_count=0
    
    log "Starting backup of all Minecraft worlds"
    
    while IFS= read -r world; do
        if backup_world "${world}"; then
            cleanup_old_backups "${world}"
            ((success_count++))
        else
            ((fail_count++))
        fi
    done < <(find "${MINECRAFT_DIR}" -maxdepth 1 -type d ! -path "${MINECRAFT_DIR}" -exec basename {} \;)
    
    log "Backup complete: ${success_count} succeeded, ${fail_count} failed"
    
    if [[ ${fail_count} -gt 0 ]]; then
        return 1
    fi
    return 0
}

show_usage() {
    cat << EOF
Minecraft World Backup Script v${SCRIPT_VERSION}

Usage: $0 [OPTIONS] [WORLD_NAME]

Options:
    -a, --all           Backup all worlds
    -l, --list          List all available worlds
    -k, --keep NUM      Number of backups to keep per world (default: 5)
    -h, --help          Show this help message
    -v, --version       Show version information

Examples:
    $0 world1                   # Backup a specific world
    $0 --all                    # Backup all worlds
    $0 --list                   # List available worlds
    $0 --keep 10 world1         # Backup world1 and keep 10 most recent backups

EOF
}

################################################################################
# Main
################################################################################

main() {
    local backup_all=false
    local list_only=false
    local keep_count=5
    local world_name=""
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -a|--all)
                backup_all=true
                shift
                ;;
            -l|--list)
                list_only=true
                shift
                ;;
            -k|--keep)
                keep_count="$2"
                shift 2
                ;;
            -h|--help)
                show_usage
                exit 0
                ;;
            -v|--version)
                echo "Minecraft Backup Script v${SCRIPT_VERSION}"
                exit 0
                ;;
            -*)
                error "Unknown option: $1"
                show_usage
                exit 1
                ;;
            *)
                world_name="$1"
                shift
                ;;
        esac
    done
    
    log "=== Minecraft Backup Script v${SCRIPT_VERSION} ==="
    
    check_dependencies
    check_directories
    
    if [[ "${list_only}" == true ]]; then
        list_worlds
        exit 0
    fi
    
    if [[ "${backup_all}" == true ]]; then
        backup_all_worlds
        exit $?
    fi
    
    if [[ -z "${world_name}" ]]; then
        error "No world specified"
        show_usage
        exit 1
    fi
    
    if backup_world "${world_name}"; then
        cleanup_old_backups "${world_name}" "${keep_count}"
        success "Backup process completed successfully"
        exit 0
    else
        error "Backup process failed"
        exit 1
    fi
}

# Execute main function
main "$@"
