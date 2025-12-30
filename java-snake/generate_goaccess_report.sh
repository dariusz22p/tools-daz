#!/usr/bin/env bash
# set -euo pipefail

SCRIPT_VERSION="1.6.0"

# generate_goaccess_report.sh
# Version: 1.6.0
# Usage: generate_goaccess_report.sh [NGINX_CONF] [--daily-only]
#
# Special arguments:
#  --daily-only - Generate only the daily stats report
#
# Notes:
# - This script is suitable for placement at /git/generate_goaccess_report.sh and
#   to be run by a privileged system user such as 'opc'.
# - Default output directory is /var/log/goaccess_reports so reports live in a central,
#   system-accessible location. Override with GOACCESS_OUTPUT_DIR if desired.
# Environment overrides:
#  GOACCESS_BIN - path to goaccess (default: goaccess)
#  GOACCESS_ARGS - extra args for goaccess (default: --log-format=COMBINED)
#  GOACCESS_OUTPUT_DIR - directory to place reports (default: /var/log/goaccess_reports)
#  MAX_ROTATED_LOGS - max old logs to process (default: 365, 0=unlimited)
#  MIN_DISK_SPACE_MB - minimum free disk space required in MB (default: 500)
#  ENABLE_CACHE - skip regeneration if logs unchanged (default: true)
#  DEBUG - set to "true" for verbose debugging output

# Parse arguments
NGINX_CONF=/etc/nginx/nginx.conf
DAILY_ONLY_MODE=false

# Handle arguments in any order
for arg in "$@"; do
  case "$arg" in
    --daily-only)
      DAILY_ONLY_MODE=true
      ;;
    -*)
      # Skip other flags
      ;;
    *)
      # Treat non-flag as NGINX_CONF
      NGINX_CONF="$arg"
      ;;
  esac
done

debug "Arguments parsed: DAILY_ONLY_MODE=$DAILY_ONLY_MODE, NGINX_CONF=$NGINX_CONF"

# ensure a sensible PATH when run from cron or as a non-interactive user
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH
export PATH

GOACCESS_BIN=${GOACCESS_BIN:-goaccess}
GOACCESS_ARGS=${GOACCESS_ARGS:---log-format=COMBINED}
# default to a system-wide directory suitable for privileged runs; override via env
OUTPUT_DIR=${GOACCESS_OUTPUT_DIR:-"/var/log/goaccess_reports"}
# Also optionally copy the final report into the web root TARGET_DIR/stats.html for easy serving
# This can be overridden by setting TARGET_DIR in the environment; default to /usr/share/nginx/html
TARGET_DIR=${TARGET_DIR:-/usr/share/nginx/html}
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Performance and resilience settings
MAX_ROTATED_LOGS=${MAX_ROTATED_LOGS:-365}  # Limit old logs processed (0=unlimited)
MIN_DISK_SPACE_MB=${MIN_DISK_SPACE_MB:-500}  # Minimum free disk space in MB
ENABLE_CACHE=${ENABLE_CACHE:-true}  # Skip regeneration if logs unchanged
CACHE_STATE_FILE="$OUTPUT_DIR/.cache_state"
START_TIME=$(date +%s)

echo -e "\n\n target dir is: $TARGET_DIR"


mkdir -p "$OUTPUT_DIR"

# Deploy log for copy/symlink actions
DEPLOY_LOG_DIR="/git/logs"
DEPLOY_LOG="$DEPLOY_LOG_DIR/goaccess_deploy.log"
mkdir -p "$DEPLOY_LOG_DIR"
: > "$DEPLOY_LOG" || true
deploy_log() { echo "$(date '+%Y-%m-%d %H:%M:%S') | $*" | tee -a "$DEPLOY_LOG"; }

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "[info] $*"; }
warn() { echo "[warn] $*" >&2; }
debug() { [ "${DEBUG:-false}" = "true" ] && echo "[debug] $*" >&2; }

# Check disk space
check_disk_space() {
  local dir=$1
  local min_space_mb=$2
  
  # Get available space in KB, convert to MB
  local avail_kb=$(df -k "$dir" | awk 'NR==2 {print $4}')
  local avail_mb=$((avail_kb / 1024))
  
  if [ "$avail_mb" -lt "$min_space_mb" ]; then
    die "Insufficient disk space: ${avail_mb}MB available, ${min_space_mb}MB required"
  fi
  
  debug "Disk space check passed: ${avail_mb}MB available"
}

# Get hash of log files to detect changes
get_logs_hash() {
  local logs=("$@")
  local hash_input=""
  
  for log in "${logs[@]}"; do
    if [ -f "$log" ]; then
      # Use mtime and size for quick change detection
      hash_input+="$log:$(stat -c '%Y:%s' "$log" 2>/dev/null || stat -f '%m:%z' "$log" 2>/dev/null)"
    fi
  done
  
  echo -n "$hash_input" | md5sum 2>/dev/null | awk '{print $1}' || echo -n "$hash_input" | md5 2>/dev/null
}

# Check if report needs regeneration
needs_regeneration() {
  local report_type=$1
  shift
  local logs=("$@")
  
  if [ "$ENABLE_CACHE" != "true" ]; then
    debug "Cache disabled, regeneration required"
    return 0  # true
  fi
  
  if [ ! -f "$CACHE_STATE_FILE" ]; then
    debug "No cache state file, regeneration required"
    return 0  # true
  fi
  
  # Get current hash
  local current_hash=$(get_logs_hash "${logs[@]}")
  
  # Check cached hash
  local cached_hash=$(grep "^${report_type}:" "$CACHE_STATE_FILE" 2>/dev/null | cut -d: -f2)
  
  if [ "$current_hash" = "$cached_hash" ]; then
    debug "Cache hit for $report_type, no regeneration needed"
    return 1  # false
  fi
  
  debug "Cache miss for $report_type, regeneration required"
  return 0  # true
}

# Update cache state
update_cache() {
  local report_type=$1
  shift
  local logs=("$@")
  
  local current_hash=$(get_logs_hash "${logs[@]}")
  
  # Create or update cache file
  touch "$CACHE_STATE_FILE"
  
  # Remove old entry for this report type
  grep -v "^${report_type}:" "$CACHE_STATE_FILE" > "${CACHE_STATE_FILE}.tmp" 2>/dev/null || true
  
  # Add new entry
  echo "${report_type}:${current_hash}" >> "${CACHE_STATE_FILE}.tmp"
  
  mv "${CACHE_STATE_FILE}.tmp" "$CACHE_STATE_FILE"
  
  debug "Updated cache for $report_type"
}

# Validate GoAccess output
validate_report() {
  local report_file=$1
  
  if [ ! -f "$report_file" ]; then
    warn "Report file not created: $report_file"
    return 1
  fi
  
  if [ ! -s "$report_file" ]; then
    warn "Report file is empty: $report_file"
    return 1
  fi
  
  # Check for HTML tags indicating valid report
  if ! grep -q "<html" "$report_file" 2>/dev/null; then
    warn "Report file does not appear to be valid HTML: $report_file"
    return 1
  fi
  
  debug "Report validation passed: $report_file"
  return 0
}

info "Running generate_goaccess_report.sh version $SCRIPT_VERSION"

# Check disk space early
check_disk_space "$OUTPUT_DIR" "$MIN_DISK_SPACE_MB"

# Ensure goaccess is available
if ! command -v "$GOACCESS_BIN" >/dev/null 2>&1; then
  die "goaccess not found at '$GOACCESS_BIN'. Install with 'brew install goaccess' or set GOACCESS_BIN."
fi

# Try to get full nginx config with includes resolved using `nginx -T` when available
CONF_TEXT=""
if command -v nginx >/dev/null 2>&1; then
  if nginx -T >/dev/null 2>&1; then
    info "Using 'nginx -T' to read configuration (includes resolved)."
    # capture stdout+stderr because nginx -T prints to stderr on some systems
    CONF_TEXT=$(nginx -T 2>&1 || true)
  else
    warn "'nginx' present but 'nginx -T' failed or requires privileges; falling back to scanning files."
  fi
else
  warn "nginx binary not found; falling back to scanning configuration files under the conf directory."
fi

# If nginx -T didn't work, build CONF_TEXT by reading conf files under dirname(NGINX_CONF) and /etc/nginx
if [ -z "${CONF_TEXT}" ]; then
  conf_dir=$(dirname "$NGINX_CONF")
  info "Scanning for .conf files in $conf_dir and /etc/nginx (if present)."
  # gather candidate files; ignore errors
  mapfile -t conf_files < <(awk 'tolower($0) ~ /\binclude\b/ { for(i=2;i<=NF;i++) print $i }' "$NGINX_CONF" 2>/dev/null || true)
  # also add nginx.conf and all .conf in conf_dir and /etc/nginx
  conf_files+=("$NGINX_CONF")
  if [ -d "$conf_dir" ]; then
    while IFS= read -r -d $'\0' f; do conf_files+=("$f"); done < <(find "$conf_dir" -type f -name "*.conf" -print0 2>/dev/null || true)
  fi
  if [ -d /etc/nginx ]; then
    while IFS= read -r -d $'\0' f; do conf_files+=("$f"); done < <(find /etc/nginx -type f -name "*.conf" -print0 2>/dev/null || true)
  fi

  # Deduplicate
  if [ "${#conf_files[@]}" -gt 0 ]; then
    unique_conf_files=($(printf "%s\n" "${conf_files[@]}" | awk '!seen[$0]++'))
    for f in "${unique_conf_files[@]}"; do
      if [ -f "$f" ]; then
        CONF_TEXT+=$'\n# FILE: '"$f"$'\n'
        CONF_TEXT+=$(sed -n '1,20000p' "$f" 2>/dev/null || true)
        CONF_TEXT+=$'\n'
      fi
    done
  else
    warn "No configuration files found; continuing but no access_log paths will be discovered."
  fi
fi

# Extract access_log lines. This should handle lines like: access_log /var/log/nginx/access.log combined;
declare -a access_lines=()
mapfile -t access_lines < <(printf "%s\n" "$CONF_TEXT" | awk 'tolower($0) ~ /access_log/ { print $0 }')

# If no access_log directives were found, we can't proceed.
if [ ${#access_lines[@]} -eq 0 ]; then
  die "No 'access_log' directives found in NGINX configuration."
fi

# Parse file paths from access_log directives
declare -a log_paths=()
for line in "${access_lines[@]}"; do
  # remove comments
  line_no_comment=$(printf "%s" "$line" | sed 's/#.*$//')
  # tokenize; find 'access_log' token index and take the next token as path
  # support quoted paths and semicolon-terminated
  path=$(printf "%s" "$line_no_comment" | sed -E "s/^.*access_log[[:space:]]+//I" | awk '{print $1}')
  # strip trailing semicolon
  path=$(printf "%s" "$path" | sed 's/;$//')
  # strip surrounding quotes
  path=$(printf "%s" "$path" | sed -E 's/^\"|\"$|^\'\''|\'\''$//g')
  # skip if empty, off, or syslog/pipe
  if [ -z "$path" ]; then
    continue
  fi
  case "$path" in
    off|syslog:*|@*|:*|*\%*)
      # skip syslog and special entries
      warn "Skipping non-file access_log target: $path"
      continue
      ;;
  esac
  # skip piped logs (begin with |) and variables
  if [[ "$path" == \|* ]] || [[ "$path" == *\$* ]]; then
    warn "Skipping piped or variable path (unresolvable): $path"
    continue
  fi
  # expand ~
  if [[ "$path" == ~* ]]; then
    path=${path/#\~/$HOME}
  fi
  # add to list if file exists
  if [ -f "$path" ]; then
    log_paths+=("$path")
  else
    warn "Access log file does not exist: $path"
  fi
done

# If no log files were found, exit
if [ ${#log_paths[@]} -eq 0 ]; then
  die "No valid access log files found; exiting."
fi

# Function to find rotated log files for a given log path
# Parameters: base_log_path
find_rotated_logs() {
  local base_log=$1
  local log_dir=$(dirname "$base_log")
  local log_name=$(basename "$base_log")
  local rotated_logs=()
  
  # Find rotated logs: logname-YYYYMMDD, logname-YYYYMMDD.gz, logname.1, logname.1.gz, etc.
  if [ -d "$log_dir" ]; then
    # Find dated rotated logs (access.log-20251224, access.log-20251224.gz)
    while IFS= read -r -d $'\0' f; do
      rotated_logs+=("$f")
    done < <(find "$log_dir" -maxdepth 1 -type f \( -name "${log_name}-[0-9]*" -o -name "${log_name}-[0-9]*.gz" \) -print0 2>/dev/null | sort -z)
    
    # Find numbered rotated logs (access.log.1, access.log.1.gz, access.log.2.gz, etc.)
    while IFS= read -r -d $'\0' f; do
      rotated_logs+=("$f")
    done < <(find "$log_dir" -maxdepth 1 -type f \( -name "${log_name}.[0-9]*" \) -print0 2>/dev/null | sort -z)
  fi
  
  # Limit number of rotated logs if MAX_ROTATED_LOGS is set
  if [ "$MAX_ROTATED_LOGS" -gt 0 ] && [ "${#rotated_logs[@]}" -gt "$MAX_ROTATED_LOGS" ]; then
    debug "Limiting rotated logs from ${#rotated_logs[@]} to $MAX_ROTATED_LOGS"
    # Keep only the most recent N logs (they're already sorted)
    rotated_logs=("${rotated_logs[@]:0:$MAX_ROTATED_LOGS}")
  fi
  
  printf '%s\n' "${rotated_logs[@]}"
}

# Function to generate a report with optional date filtering
# Parameters: report_type, report_name, date_filter, [optional_log_file], [include_rotated]
generate_report() {
  local report_type=$1
  local report_name=$2
  local date_filter=$3
  local specific_log_file=${4:-}  # Optional: specific log file to use
  local include_rotated=${5:-false}  # Optional: include rotated logs
  
  echo -e "\n\n @@ Starting generate_report function for $report_name report @@\n\n"
  
  local report_file="$OUTPUT_DIR/${report_type}_$TIMESTAMP.html"
  local web_file="$TARGET_DIR/${report_type}.html"
  
  info "Generating $report_name report: $report_file"
  
  # Determine which logs to process
  local logs_to_process=()
  if [ -n "$specific_log_file" ]; then
    # Use only the specified log file
    if [ -f "$specific_log_file" ]; then
      logs_to_process=("$specific_log_file")
      debug "Using specific log file: $specific_log_file"
      
      # Add rotated logs if requested
      if [ "$include_rotated" = true ]; then
        mapfile -t rotated < <(find_rotated_logs "$specific_log_file")
        if [ ${#rotated[@]} -gt 0 ]; then
          logs_to_process+=("${rotated[@]}")
          info "Found ${#rotated[@]} rotated log files to include"
        fi
      fi
    else
      warn "Specified log file does not exist: $specific_log_file"
      return 1
    fi
  else
    # Use all discovered log paths
    logs_to_process=("${log_paths[@]}")
    debug "Using all discovered log paths"
    
    # Add rotated logs if requested
    if [ "$include_rotated" = true ]; then
      for log_path in "${log_paths[@]}"; do
        mapfile -t rotated < <(find_rotated_logs "$log_path")
        if [ ${#rotated[@]} -gt 0 ]; then
          logs_to_process+=("${rotated[@]}")
        fi
      done
      info "Total logs to process (including rotated): ${#logs_to_process[@]}"
    fi
  fi
  
  # Check cache - skip if logs haven't changed
  if needs_regeneration "$report_type" "${logs_to_process[@]}"; then
    info "Cache check: regeneration required for $report_name"
  else
    info "Cache check: $report_name is up-to-date, skipping regeneration"
    # Still copy existing report to web directory if it exists
    local latest_report=$(ls -t "$OUTPUT_DIR/${report_type}"_*.html 2>/dev/null | head -1)
    if [ -n "$latest_report" ] && [ -f "$latest_report" ]; then
      if [ -n "$TARGET_DIR" ]; then
        cp -f "$latest_report" "$web_file" 2>/dev/null && info "Copied cached report to $web_file"
      fi
    fi
    return 0
  fi
  
  # Filter logs by date if specified
  local temp_log=""
  if [ -n "$date_filter" ]; then
    temp_log=$(mktemp)
    local filtered_count=0
    
    for log_path in "${logs_to_process[@]}"; do
      if [ -f "$log_path" ]; then
        debug "Processing $log_path for pattern: $date_filter"
        # Handle gzipped files with error handling
        if [[ "$log_path" == *.gz ]]; then
          if ! local temp_count=$(zcat "$log_path" 2>/dev/null | grep -E "$date_filter" 2>/dev/null | tee -a "$temp_log" | wc -l); then
            warn "Failed to process gzipped log: $log_path (may be corrupted)"
            continue
          fi
        else
          if ! local temp_count=$(grep -E "$date_filter" "$log_path" 2>/dev/null | tee -a "$temp_log" | wc -l); then
            warn "Failed to process log: $log_path"
            continue
          fi
        fi
        if [ "$temp_count" -gt 0 ]; then
          debug "Filtered $temp_count lines from $log_path"
          filtered_count=$((filtered_count + temp_count))
        fi
      fi
    done
    
    # If temp log is empty, warn and skip this report
    if [ ! -s "$temp_log" ]; then
      warn "No log entries found for $report_name ($date_filter); skipping report generation."
      rm -f "$temp_log"
      return 0
    fi
    
    info "Filtered $filtered_count log entries for $report_name report"
    
    # Generate report from filtered logs with retry
    # shellcheck disable=SC2086
    local retry_count=0
    local max_retries=2
    while [ $retry_count -le $max_retries ]; do
      if "$GOACCESS_BIN" $GOACCESS_ARGS -o "$report_file" "$temp_log" 2>/dev/null; then
        break
      else
        retry_count=$((retry_count + 1))
        if [ $retry_count -le $max_retries ]; then
          warn "GoAccess failed, retrying ($retry_count/$max_retries)..."
          sleep 2
        else
          rm -f "$temp_log"
          die "GoAccess failed after $max_retries retries for $report_name report"
        fi
      fi
    done
    rm -f "$temp_log"
  else
    # Generate report from selected logs (all-time)
    debug "Generating all-time report from selected log paths"
    
    # Create a temporary file to combine all logs (including decompressing gzipped ones)
    local combined_log=$(mktemp)
    local total_lines=0
    for log_path in "${logs_to_process[@]}"; do
      if [ -f "$log_path" ]; then
        if [[ "$log_path" == *.gz ]]; then
          debug "Decompressing and processing: $log_path"
          if ! local line_count=$(zcat "$log_path" 2>/dev/null | tee -a "$combined_log" | wc -l); then
            warn "Failed to decompress log: $log_path (may be corrupted), skipping"
            continue
          fi
          total_lines=$((total_lines + line_count))
        else
          debug "Processing: $log_path"
          if ! local line_count=$(cat "$log_path" 2>/dev/null | tee -a "$combined_log" | wc -l); then
            warn "Failed to read log: $log_path, skipping"
            continue
          fi
          total_lines=$((total_lines + line_count))
        fi
      fi
    done
    
    info "Processing $total_lines total log entries for $report_name report"
    
    # Generate report with retry
    # shellcheck disable=SC2086
    local retry_count=0
    local max_retries=2
    while [ $retry_count -le $max_retries ]; do
      if "$GOACCESS_BIN" $GOACCESS_ARGS -o "$report_file" "$combined_log" 2>/dev/null; then
        break
      else
        retry_count=$((retry_count + 1))
        if [ $retry_count -le $max_retries ]; then
          warn "GoAccess failed, retrying ($retry_count/$max_retries)..."
          sleep 2
        else
          rm -f "$combined_log"
          die "GoAccess failed after $max_retries retries for $report_name report"
        fi
      fi
    done
    rm -f "$combined_log"
  fi
  
  # Validate report output
  if ! validate_report "$report_file"; then
    warn "Report validation failed for $report_name, but continuing..."
  fi
  
  # Update cache state
  update_cache "$report_type" "${logs_to_process[@]}"
  
  info "Report written to $report_file"
  
  # Copy to web directory
  echo -e "\n\n target dir is: $TARGET_DIR"
  if [ -n "$TARGET_DIR" ]; then
    # Ensure the directory exists
    if sudo mkdir -p "$TARGET_DIR" 2>/dev/null || true; then
      info "Ensured target web directory exists: $TARGET_DIR"
    fi
    
    # Attempt to copy the file with validation
    if cp -fv "$report_file" "$web_file" ; then
      # Verify copied file
      if ! validate_report "$web_file"; then
        warn "Copied report failed validation: $web_file"
        return 1
      fi
      deploy_log "Copied $report_name report to $web_file"
    elif sudo cp -fv "$report_file" "$web_file" ; then
      if ! validate_report "$web_file"; then
        warn "Copied report failed validation: $web_file"
        return 1
      fi
      deploy_log "Copied $report_name report to $web_file (via sudo)"
    else
      deploy_log "Failed to copy $report_name report to $web_file"
      return 1
    fi
    
    # Set permissions
    sudo chown opc:opc "$web_file" 2>/dev/null && deploy_log "Set ownership opc:opc on $web_file" || true
    sudo chmod 644 "$web_file" 2>/dev/null && deploy_log "Set permissions 644 on $web_file" || true
  fi
}

# Add log rotation logic to the script
rotate_logs() {
  local log_file=$1
  local max_files=${2:-7}  # Default to keeping 7 rotated logs

  if [ -f "$log_file" ]; then
    for ((i=max_files; i>0; i--)); do
      if [ -f "${log_file}.$i.gz" ]; then
        mv "${log_file}.$i.gz" "${log_file}.$((i+1)).gz"
      fi
    done

    if [ -f "${log_file}.1" ]; then
      gzip -f "${log_file}.1"
      mv "${log_file}.1.gz" "${log_file}.2.gz"
    fi

    mv "$log_file" "${log_file}.1"
  fi
}

# Calculate date patterns for filtering
# Nginx uses format: 01/Jan/2025
TODAY=$(date '+%d/%b/%Y' 2>/dev/null)
if [ -z "$TODAY" ]; then
  warn "Failed to calculate today's date; date filtering may not work."
  TODAY=""
fi

# Generate date regex pattern for the last 7 days (inclusive of today)
WEEK_PATTERN=""
if command -v date >/dev/null 2>&1; then
  # Try different date arithmetic approaches for Linux and macOS
  for i in {0..6}; do
    if DATE_PATTERN=$(date -d "$i days ago" '+%d/%b/%Y' 2>/dev/null); then
      # Linux: -d flag works
      :
    elif DATE_PATTERN=$(date -v-${i}d '+%d/%b/%Y' 2>/dev/null); then
      # macOS: -v flag works
      :
    else
      warn "Failed to calculate date $i days ago"
      continue
    fi
    
    if [ -n "$DATE_PATTERN" ]; then
      if [ -z "$WEEK_PATTERN" ]; then
        WEEK_PATTERN="$DATE_PATTERN"
      else
        WEEK_PATTERN="$WEEK_PATTERN|$DATE_PATTERN"
      fi
      debug "Added to weekly pattern: $DATE_PATTERN"
    fi
  done
fi

if [ -z "$WEEK_PATTERN" ]; then
  warn "Could not calculate week pattern; weekly report will be skipped."
fi

# Generate the three reports
info "=== Generating Daily Stats Report ==="
generate_report "daily-stats" "Daily" "$TODAY" "/var/log/nginx/access.log" false

if [ "$DAILY_ONLY_MODE" = false ]; then
  if [ -n "$WEEK_PATTERN" ]; then
    info "=== Generating Weekly Stats Report ==="
    generate_report "weekly-stats" "Weekly" "$WEEK_PATTERN" "/var/log/nginx/access.log" true
  else
    warn "Could not determine week pattern; skipping weekly report"
  fi

  info "=== Generating All-Time Stats Report ==="
  generate_report "all-time-stats" "All-Time" "" "/var/log/nginx/access.log" true
else
  info "Daily-only mode enabled; skipping weekly and all-time reports"
fi

# Update legacy symlink for backward compatibility
all_time_report="$OUTPUT_DIR/all-time-stats_$TIMESTAMP.html"
latest_link="$OUTPUT_DIR/latest_report.html"
if [ -f "$all_time_report" ]; then
  if [ -L "$latest_link" ]; then
    rm "$latest_link"
  fi
  ln -s "$all_time_report" "$latest_link"
  info "Updated legacy symlink: $latest_link"
fi



# Call rotate_logs for daily and weekly logs
rotate_logs "/var/log/nginx/access_daily.log" 7
rotate_logs "/var/log/nginx/access_weekly.log" 4

# Calculate and log execution time
END_TIME=$(date +%s)
EXECUTION_TIME=$((END_TIME - START_TIME))
info "Script execution completed in ${EXECUTION_TIME} seconds"


info "we run script version: $SCRIPT_VERSION"

exit 0