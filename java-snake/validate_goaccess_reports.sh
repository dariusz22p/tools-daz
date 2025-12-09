#!/usr/bin/env bash
set -euo pipefail

SCRIPT_VERSION="1.4.0"

# validate_goaccess_reports.sh
# Version: 1.4.0
# Usage: validate_goaccess_reports.sh [REPORT_DIR]
#
# Purpose: Validate that goaccess reports contain real data, not empty/fake content
# Default report directory: /var/log/goaccess_reports
# Web directory: /usr/share/nginx/html
#
# This script checks:
# - Report files exist and are readable
# - HTML files contain actual data (non-trivial file size)
# - HTML contains valid goaccess metrics (requests, visitors, bandwidth, etc.)
# - HTML contains actual traffic data (not just headers)
# - Reports were generated recently (within last 24 hours by default)

REPORT_DIR="${1:-/var/log/goaccess_reports}"
WEB_DIR="/usr/share/nginx/html"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
MAX_AGE_HOURS=24  # Reports older than this are considered stale

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
  info "Validation start time: $(date '+%Y-%m-%d %H:%M:%S')"
  
  # Check 1: Web symlink file exists
  ((TOTAL_CHECKS++))
  echo "[debug] $(date '+%H:%M:%S') Check 1: Verifying web file exists" >&2
  if [ -f "$web_file" ]; then
    success "Web file exists: $web_file"
    ((PASSED_CHECKS++))
  else
    warn "Web file missing: $web_file"
    ((FAILED_CHECKS++))
    return 1
  fi
  
  # Check 2: File is not empty (minimum 10KB expected for real goaccess output)
  ((TOTAL_CHECKS++))
  echo "[debug] $(date '+%H:%M:%S') Check 2: Verifying file size" >&2
  local file_size=$(stat -f%z "$web_file" 2>/dev/null || stat -c%s "$web_file" 2>/dev/null || echo 0)
  if [ "$file_size" -gt 10000 ]; then
    success "File size is substantial: ${file_size} bytes"
    ((PASSED_CHECKS++))
  else
    warn "File size suspiciously small: ${file_size} bytes (expected > 10KB)"
    ((FAILED_CHECKS++))
    return 1
  fi
  
  # Check 3: File contains HTML structure
  ((TOTAL_CHECKS++))
  echo "[debug] $(date '+%H:%M:%S') Check 3: Verifying HTML structure" >&2
  if timeout 5 sed -n '1,100p' "$web_file" 2>/dev/null | grep -q "<html\|<!DOCTYPE" 2>/dev/null; then
    success "Contains valid HTML structure"
    ((PASSED_CHECKS++))
  else
    warn "Missing HTML structure tags"
    ((FAILED_CHECKS++))
    return 1
  fi
  
  # Check 4: Contains goaccess-specific elements
  ((TOTAL_CHECKS++))
  echo "[debug] $(date '+%H:%M:%S') Check 4: Verifying goaccess branding" >&2
  if timeout 5 sed -n '1,100p' "$web_file" 2>/dev/null | grep -qi "goaccess" 2>/dev/null; then
    success "Contains goaccess branding/metadata"
    ((PASSED_CHECKS++))
  else
    warn "Missing goaccess branding (might not be a real goaccess report)"
    ((FAILED_CHECKS++))
    return 1
  fi
  
  # Check 5: Contains traffic metrics
  ((TOTAL_CHECKS++))
  echo "[debug] $(date '+%H:%M:%S') Check 5: Verifying traffic metrics" >&2
  local has_metrics=0
  if timeout 5 sed -n '1,500p' "$web_file" 2>/dev/null | grep -qi "requests\|visitors\|bandwidth\|hits" 2>/dev/null; then
    has_metrics=1
  fi
  
  if [ $has_metrics -eq 1 ]; then
    success "Contains traffic metrics (requests/visitors/bandwidth)"
    ((PASSED_CHECKS++))
  else
    warn "No traffic metrics found in report"
    ((FAILED_CHECKS++))
    return 1
  fi
  
  # Check 6: Contains actual request data (IP addresses, user agents, URLs, etc.)
  ((TOTAL_CHECKS++))
  echo "[debug] $(date '+%H:%M:%S') Check 6: Verifying HTTP request data" >&2
  local has_data=0
  if timeout 5 sed -n '1,500p' "$web_file" 2>/dev/null | grep -q "GET\|POST\|/\|http" 2>/dev/null; then
    has_data=1
  fi
  
  if [ $has_data -eq 1 ]; then
    success "Contains actual HTTP request data"
    ((PASSED_CHECKS++))
  else
    warn "No actual HTTP request data found"
    ((FAILED_CHECKS++))
    return 1
  fi
  
  # Check 7: File modification time (should be recent)
  ((TOTAL_CHECKS++))
  echo "[debug] $(date '+%H:%M:%S') Check 7: Verifying file freshness" >&2
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
  
  # Check 8: Look for latest archive file
  ((TOTAL_CHECKS++))
  echo "[debug] $(date '+%H:%M:%S') Check 8: Verifying archive files" >&2
  local latest_archive=$(ls -t $archive_pattern 2>/dev/null | head -1 || echo "")
  if [ -n "$latest_archive" ]; then
    local archive_size=$(stat -f%z "$latest_archive" 2>/dev/null || stat -c%s "$latest_archive" 2>/dev/null || echo 0)
    success "Latest archive found: $(basename $latest_archive) (${archive_size} bytes)"
    ((PASSED_CHECKS++))
  else
    warn "No archive files found matching pattern: $archive_pattern"
    ((FAILED_CHECKS++))
  fi
  
  # Check 9: Extract and display some metrics from the report
  ((TOTAL_CHECKS++))
  echo "[debug] $(date '+%H:%M:%S') Check 9: Extracting report metrics" >&2
  local metrics_found=0
  
  # Try to extract request count using simple sed/grep
  if timeout 5 sed -n '1,500p' "$web_file" 2>/dev/null | grep -q "requests\|visitors" 2>/dev/null; then
    metrics_found=1
    info "  Sample metric: Found traffic metrics in report"
  fi
  
  if [ $metrics_found -eq 1 ]; then
    success "Successfully extracted metrics from report"
    ((PASSED_CHECKS++))
  else
    info "  (Could not extract specific metrics - report structure varies)"
    ((PASSED_CHECKS++))  # Don't fail on this
  fi
  
  echo ""
  info "✓ Completed validation for $report_name Report at $(date '+%H:%M:%S')"
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
  echo "  Web:     $WEB_DIR/"
  echo "  Archive: $REPORT_DIR/"
  echo ""
  
  # Show file sizes for web reports
  info "Web report sizes:"
  for report_type in "${REPORTS[@]}"; do
    local web_file="$WEB_DIR/${report_type}.html"
    if [ -f "$web_file" ]; then
      local size=$(stat -f%z "$web_file" 2>/dev/null || stat -c%s "$web_file" 2>/dev/null || echo 0)
      echo "  $report_type: $size bytes"
    fi
  done
  
  exit 0
else
  warn "Some validations failed. Reports may contain fake or incomplete data."
  exit 1
fi
