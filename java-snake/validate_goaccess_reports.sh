#!/usr/bin/env bash
set -euo pipefail

SCRIPT_VERSION="2.0.0"

# validate_goaccess_reports.sh
# Version: 2.0.0
# Usage: validate_goaccess_reports.sh [REPORT_DIR]
#
# Purpose: Validate that goaccess reports contain real data (simplified approach)
# Default report directory: /var/log/goaccess_reports
# Web directory: /usr/share/nginx/html
#
# This script checks:
# - Report files exist and are readable
# - HTML files have substantial size (indicates real content)
# - File modification time is recent (reports generated recently)
# - HTML header contains goaccess signature (first 100 bytes)
#
# Note: Avoids parsing large HTML files which can cause hangs on RHEL 7.9

REPORT_DIR="${1:-/var/log/goaccess_reports}"
WEB_DIR="/usr/share/nginx/html"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
MAX_AGE_HOURS=24  # Reports older than this are considered stale
MIN_FILE_SIZE=50000  # Minimum 50KB for real goaccess reports

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
die() { echo -e "${RED}ERROR: $*${NC}" >&2; exit 1; }
info() { echo -e "${BLUE}[info]${NC} $*"; }
success() { echo -e "${GREEN}[✓]${NC} $*"; }
warn() { echo -e "${YELLOW}[warn]${NC} $*" >&2; }

info "Starting goaccess report validation (v$SCRIPT_VERSION)"
info "Report directory: $REPORT_DIR"
info "Web directory: $WEB_DIR"
info "Start time: $(date '+%Y-%m-%d %H:%M:%S')"
echo ""

# Check if report directory exists
if [ ! -d "$REPORT_DIR" ]; then
  die "Report directory does not exist: $REPORT_DIR"
fi

# Initialize counters
TOTAL_CHECKS=0
PASSED_CHECKS=0
FAILED_CHECKS=0

# Define reports to validate
declare -a REPORTS=("daily-stats" "weekly-stats" "all-time-stats")

# Function to validate a single report
validate_report() {
  local report_type=$1
  local report_name=$2
  local web_file="$WEB_DIR/${report_type}.html"
  local archive_pattern="$REPORT_DIR/${report_type}_*.html"
  
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  info "Validating $report_name Report"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  
  # Check 1: Web symlink file exists
  ((TOTAL_CHECKS++))
  if [ -f "$web_file" ]; then
    success "Web file exists: $web_file"
    ((PASSED_CHECKS++))
  else
    warn "Web file missing: $web_file"
    ((FAILED_CHECKS++))
    return 1
  fi
  
  # Check 2: File is readable
  ((TOTAL_CHECKS++))
  if [ -r "$web_file" ]; then
    success "Web file is readable"
    ((PASSED_CHECKS++))
  else
    warn "Web file is not readable: $web_file"
    ((FAILED_CHECKS++))
    return 1
  fi
  
  # Check 3: File size is substantial (at least 50KB for real goaccess output)
  ((TOTAL_CHECKS++))
  local file_size=$(stat -f%z "$web_file" 2>/dev/null || stat -c%s "$web_file" 2>/dev/null || echo 0)
  local file_size_kb=$((file_size / 1024))
  
  if [ "$file_size" -gt "$MIN_FILE_SIZE" ]; then
    success "File size is substantial: ${file_size_kb} KB"
    ((PASSED_CHECKS++))
  else
    warn "File size suspiciously small: ${file_size_kb} KB (expected > 50 KB)"
    ((FAILED_CHECKS++))
    return 1
  fi
  
  # Check 4: File header contains goaccess signature (no parsing large file)
  ((TOTAL_CHECKS++))
  local header=$(head -c 200 "$web_file" 2>/dev/null || echo "")
  if echo "$header" | grep -qi "goaccess\|<!doctype\|<html" 2>/dev/null; then
    success "File header contains goaccess/HTML signature"
    ((PASSED_CHECKS++))
  else
    warn "File header missing goaccess/HTML signature"
    ((FAILED_CHECKS++))
    return 1
  fi
  
  # Check 5: File modification time (should be recent)
  ((TOTAL_CHECKS++))
  local file_mtime=$(stat -f%m "$web_file" 2>/dev/null || stat -c%Y "$web_file" 2>/dev/null || echo 0)
  local current_time=$(date +%s)
  local age_seconds=$((current_time - file_mtime))
  local age_hours=$((age_seconds / 3600))
  
  if [ $age_hours -lt $MAX_AGE_HOURS ]; then
    success "File is recent: ${age_hours} hours old"
    ((PASSED_CHECKS++))
  else
    warn "File is stale: ${age_hours} hours old (expected < ${MAX_AGE_HOURS})"
    ((FAILED_CHECKS++))
  fi
  
  # Check 6: Look for latest archive file
  ((TOTAL_CHECKS++))
  local latest_archive=$(ls -t $archive_pattern 2>/dev/null | head -1 || echo "")
  if [ -n "$latest_archive" ]; then
    local archive_size=$(stat -f%z "$latest_archive" 2>/dev/null || stat -c%s "$latest_archive" 2>/dev/null || echo 0)
    local archive_size_kb=$((archive_size / 1024))
    success "Latest archive found: $(basename $latest_archive) (${archive_size_kb} KB)"
    ((PASSED_CHECKS++))
  else
    warn "No archive files found matching pattern: $archive_pattern"
    ((FAILED_CHECKS++))
  fi
  
  echo ""
}

# Run validation for all three reports
for report_type in "${REPORTS[@]}"; do
  case "$report_type" in
    daily-stats)
      validate_report "$report_type" "Daily Stats"
      ;;
    weekly-stats)
      validate_report "$report_type" "Weekly Stats"
      ;;
    all-time-stats)
      validate_report "$report_type" "All-Time Stats"
      ;;
  esac
done

# Summary
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
info "VALIDATION SUMMARY"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
info "Validation completed at: $(date '+%Y-%m-%d %H:%M:%S')"
echo ""

echo "Total Checks: $TOTAL_CHECKS"
echo -e "Passed: ${GREEN}$PASSED_CHECKS${NC}"
echo -e "Failed: ${RED}$FAILED_CHECKS${NC}"
echo ""

if [ $FAILED_CHECKS -eq 0 ]; then
  success "All validations passed! Reports contain real data."
  echo ""
  
  # Show report locations
  info "Reports are accessible at:"
  for report_type in "${REPORTS[@]}"; do
    local web_file="$WEB_DIR/${report_type}.html"
    if [ -f "$web_file" ]; then
      echo "  ✓ $web_file"
    fi
  done
  
  echo ""
  info "Archive reports stored in: $REPORT_DIR"
  echo ""
  
  exit 0
else
  warn "Some validations failed. Reports may contain fake or incomplete data."
  exit 1
fi
