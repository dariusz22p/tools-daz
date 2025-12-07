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
mapfile -t access_lines < <(printf "%s\n" "$CONF_TEXT" | awk 'tolower($0) ~ /\baccess_log\b/ { print $0 }')

# Parse file paths from access_log directives
declare -a log_paths
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

# Generate the report
report_file="$OUTPUT_DIR/report_$TIMESTAMP.html"
info "Generating report: $report_file"
{
  echo "<html><head><title>GoAccess Report</title></head><body>"
  echo "<h1>GoAccess Report</h1>"
  echo "<p>Generated on: $(date)</p>"
  echo "<h2>Access Logs</h2><ul>"
  for log_path in "${log_paths[@]}"; do
    echo "<li>$log_path</li>"
  done
  echo "</ul>"
  echo "<h2>Report</h2><pre>"
  # shellcheck disable=SC2086
  "$GOACCESS_BIN" $GOACCESS_ARGS -o "$report_file" "${log_paths[@]}"
  echo "</pre></body></html>"
} > "$report_file"

info "Report written to $report_file"

# Update latest symlink
latest_link="$OUTPUT_DIR/latest_report.html"
if [ -L "$latest_link" ]; then
  rm "$latest_link"
fi
ln -s "$report_file" "$latest_link"
info "Updated latest report symlink: $latest_link"

# Also copy the generated report into the web target directory with a timestamped filename
if [ -n "$TARGET_DIR" ]; then
  timestamped_webfile="$TARGET_DIR/stats_$TIMESTAMP.html"
  latest_symlink="$TARGET_DIR/stats_latest.html"

  # Ensure the directory exists (use sudo if necessary)
  if sudo mkdir -p "$TARGET_DIR" 2>/dev/null || true; then
    info "Ensured target web directory exists: $TARGET_DIR"
  fi

  # Attempt to copy the file (prefer non-sudo but fall back to sudo)
  if cp -f "$report_file" "$timestamped_webfile" 2>/dev/null; then
    deploy_log "Copied report to $timestamped_webfile"
    copied_via_sudo=0
  else
    if sudo cp -f "$report_file" "$timestamped_webfile" 2>/dev/null; then
      deploy_log "Copied report to $timestamped_webfile (via sudo)"
      copied_via_sudo=1
    else
      deploy_log "Failed to copy report to $timestamped_webfile — check permissions."
      copied_via_sudo=0
    fi
  fi

  # Update latest symlink atomically
  if [ -e "$timestamped_webfile" ]; then
    if sudo ln -snf "$timestamped_webfile" "$latest_symlink" 2>/dev/null; then
      deploy_log "Updated symlink: $latest_symlink -> $timestamped_webfile"
    else
      # try non-sudo symlink
      ln -snf "$timestamped_webfile" "$latest_symlink" 2>/dev/null && deploy_log "Updated symlink: $latest_symlink -> $timestamped_webfile" || deploy_log "Failed to update symlink $latest_symlink"
    fi

    # Ensure the copied file has the requested ownership (opc:opc) if possible
    if sudo chown opc:opc "$timestamped_webfile" 2>/dev/null; then
      deploy_log "Set ownership opc:opc on $timestamped_webfile"
    else
      deploy_log "Could not set ownership on $timestamped_webfile (sudo may be required)"
    fi

    # Ensure the copied file is readable
    if sudo chmod 644 "$timestamped_webfile" 2>/dev/null; then
      deploy_log "Set permissions 644 on $timestamped_webfile"
    fi
  fi
fi

exit 0