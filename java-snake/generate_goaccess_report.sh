#!/usr/bin/env bash
set -euo pipefail

# generate_goaccess_report.sh
# Usage: generate_goaccess_report.sh [NGINX_CONF]
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

NGINX_CONF=${1:-/etc/nginx/nginx.conf}
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
mapfile -t access_lines < <(printf "%s\n" "$CONF_TEXT" | awk 'tolower($0) ~ /\baccess_log\b/ { print $0 }')

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

# Function to generate a report with optional date filtering
generate_report() {
  local report_type=$1
  local report_name=$2
  local date_filter=$3
  
  local report_file="$OUTPUT_DIR/${report_type}_$TIMESTAMP.html"
  local web_file="$TARGET_DIR/${report_type}.html"
  
  info "Generating $report_name report: $report_file"
  
  # Filter logs by date if specified
  local temp_log=""
  if [ -n "$date_filter" ]; then
    temp_log=$(mktemp)
    for log_path in "${log_paths[@]}"; do
      if [ -f "$log_path" ]; then
        # Extract lines matching the date pattern
        grep -E "$date_filter" "$log_path" 2>/dev/null >> "$temp_log" || true
      fi
    done
    
    # If temp log is empty, skip this report
    if [ ! -s "$temp_log" ]; then
      warn "No log entries found for $report_name; skipping."
      rm -f "$temp_log"
      return 0
    fi
    
    # Generate report from filtered logs
    # shellcheck disable=SC2086
    "$GOACCESS_BIN" $GOACCESS_ARGS -o "$report_file" "$temp_log"
    rm -f "$temp_log"
  else
    # Generate report from all logs (all-time)
    # shellcheck disable=SC2086
    "$GOACCESS_BIN" $GOACCESS_ARGS -o "$report_file" "${log_paths[@]}"
  fi
  
  info "Report written to $report_file"
  
  # Copy to web directory
  if [ -n "$TARGET_DIR" ]; then
    # Ensure the directory exists
    if sudo mkdir -p "$TARGET_DIR" 2>/dev/null || true; then
      info "Ensured target web directory exists: $TARGET_DIR"
    fi
    
    # Attempt to copy the file
    if cp -f "$report_file" "$web_file" 2>/dev/null; then
      deploy_log "Copied $report_name report to $web_file"
    elif sudo cp -f "$report_file" "$web_file" 2>/dev/null; then
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

# Calculate date patterns for filtering
TODAY=$(date '+%d/%b/%Y')
WEEK_AGO=$(date -d '7 days ago' '+%d/%b/%Y' 2>/dev/null || date -v-7d '+%d/%b/%Y' 2>/dev/null || echo "")

# Generate date regex pattern for the last 7 days
if [ -n "$WEEK_AGO" ]; then
  # Build a pattern matching any date in the last 7 days
  WEEK_PATTERN=""
  for i in {0..6}; do
    DATE_PATTERN=$(date -d "$i days ago" '+%d/%b/%Y' 2>/dev/null || date -v-${i}d '+%d/%b/%Y' 2>/dev/null || echo "")
    if [ -n "$DATE_PATTERN" ]; then
      if [ -z "$WEEK_PATTERN" ]; then
        WEEK_PATTERN="$DATE_PATTERN"
      else
        WEEK_PATTERN="$WEEK_PATTERN|$DATE_PATTERN"
      fi
    fi
  done
else
  WEEK_PATTERN=""
fi

# Generate the three reports
info "=== Generating Daily Stats Report ==="
generate_report "daily-stats" "Daily" "$TODAY"

if [ -n "$WEEK_PATTERN" ]; then
  info "=== Generating Weekly Stats Report ==="
  generate_report "weekly-stats" "Weekly" "$WEEK_PATTERN"
else
  warn "Could not determine week pattern; skipping weekly report"
fi

info "=== Generating All-Time Stats Report ==="
generate_report "all-time-stats" "All-Time" ""

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

info "=== Report Generation Complete ==="
info "Daily stats: $TARGET_DIR/daily-stats.html"
info "Weekly stats: $TARGET_DIR/weekly-stats.html"
info "All-time stats: $TARGET_DIR/all-time-stats.html"

exit 0