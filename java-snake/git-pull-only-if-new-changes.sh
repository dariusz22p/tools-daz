#!/bin/bash
# Run git pull only if there are new commits, then deploy and reload Nginx
# Logs actions to /git/logs/update-repo.log with 7-day rotation
#
# Usage / debug:
#  - Enable verbose tracing and live logging by setting DEBUG=1 in the environment.
#    Example: DEBUG=1 /path/to/git-pull-only-if-new-changes.sh
#  - If running with sudo and you want the DEBUG env preserved, use: sudo -E DEBUG=1 /path/to/script
#  - On macOS, `systemctl` is not available by default; the reload step may need adapting
#    to use `brew services` or launchd depending on how nginx was installed.

set -euo pipefail

SCRIPT_VERSION="2.0.0"


# Toggle debug: set DEBUG=1 to enable verbose tracing and live logging
DEBUG="${DEBUG:-0}"

# Configuration
REPO_DIR="/git/python-games"
SOURCE_DIR="$REPO_DIR/games-HTML5"
TARGET_DIR="${TARGET_DIR:-/usr/share/nginx/html}"
BRANCH="main"
LOG_DIR="/git/logs"
LOG_FILE="$LOG_DIR/update-repo.log"
SERVICE="nginx"

# Caching configuration
REMOTE_HASH_CACHE="$LOG_DIR/.remote_hash_cache"
REMOTE_HASH_CACHE_TTL=${REMOTE_HASH_CACHE_TTL:-300}  # 5 minutes
AGG_HASH_CACHE="$LOG_DIR/.agg_hash_cache"
REPORT_ON_NO_CHANGES=${REPORT_ON_NO_CHANGES:-false}  # Generate reports even if no git changes

# Log retention configuration
KEEP_ROTATED_LOGS=${KEEP_ROTATED_LOGS:-7}           # Keep rotated update-repo logs for N days
KEEP_AGGREGATED_LOGS=${KEEP_AGGREGATED_LOGS:-30}    # Keep aggregated nginx logs for N days
KEEP_CUMULATIVE_LOGS=${KEEP_CUMULATIVE_LOGS:-365}   # Keep cumulative logs for N days

# GoAccess configuration
GOACCESS_LOG_FORMAT=${GOACCESS_LOG_FORMAT:-COMBINED}
PARALLEL_PROCESSING=${PARALLEL_PROCESSING:-true}    # Process multiple logs in parallel (experimental)

# Ensure log directory exists early so we can tee into it if DEBUG is enabled
mkdir -p "$LOG_DIR"
: > "$LOG_FILE" || true

# Deploy-specific log (diagnostics). Ensure it exists and is writable by opc when possible.
DEPLOY_LOG="$LOG_DIR/goaccess_deploy.log"
if [ ! -f "$DEPLOY_LOG" ]; then
  # try to create and chown via sudo, fallback to creating silently as current user
  if command -v sudo >/dev/null 2>&1 && sudo bash -c "touch '$DEPLOY_LOG' && chown opc:opc '$DEPLOY_LOG'" >/dev/null 2>&1; then
    true
  else
    # try creating without emitting permission errors; if that fails, leave it and rely on sudo tee in deploy_append
    touch "$DEPLOY_LOG" 2>/dev/null || true
  fi
else
  # If file exists but not writable, try to chown it silently so append attempts succeed later
  if [ ! -w "$DEPLOY_LOG" ]; then
    if command -v sudo >/dev/null 2>&1; then
      sudo chown opc:opc "$DEPLOY_LOG" 2>/dev/null || true
    fi
  fi
fi

# Robust deploy append that writes to both the main log and the deploy log.
deploy_append() {
  # Usage: deploy_append [TAG] message...
  # If the first argument looks like [TAG] (e.g., [AGG], [DEPLOY]), use it; otherwise default to [DEPLOY]
  first="${1:-}"
  tag="[DEPLOY]"
  if [[ "$first" =~ ^\[[A-Z0-9_-]+\]$ ]]; then
    tag="$first"
    shift
  fi
  msg="$*"
  # Build the log line
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  line="$ts | ${tag} $msg"

  # Always append to main update log (best-effort)
  echo "$line" | tee -a "$LOG_FILE" >/dev/null 2>&1 || true

  # Try direct append to deploy log; if permission denied, use sudo tee if available
  if ! echo "$line" >> "$DEPLOY_LOG" 2>/dev/null; then
    if command -v sudo >/dev/null 2>&1; then
      echo "$line" | sudo tee -a "$DEPLOY_LOG" >/dev/null 2>&1 || true
    fi
  fi

  # If DEBUG is enabled, also print a colorized version to the console to make tags visible
  if [ "${DEBUG:-0}" -ne 0 ] 2>/dev/null; then
    # ANSI color map for tags
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    BLUE='\033[0;34m'
    MAGENTA='\033[0;35m'
    CYAN='\033[0;36m'
    RESET='\033[0m'
    case "$tag" in
      '[DEPLOY]') color="$GREEN" ;;
      '[AGG]') color="$BLUE" ;;
      '[CUM]') color="$MAGENTA" ;;
      '[DIAG]') color="$YELLOW" ;;
      '[GIT]') color="$CYAN" ;;
      *) color="$RESET" ;;
    esac
    # Colorize only the tag for readability
    console_line="$ts | ${color}${tag}${RESET} $msg"
    # Print to stdout so debug logging shows up on console
    echo -e "$console_line"
  fi
}

# If debugging, enable verbose tracing and send all output to both console and log
if [ "$DEBUG" -ne 0 ] 2>/dev/null; then
  export GIT_TRACE=1
  export GIT_CURL_VERBOSE=1
  set -x
  # Redirect all stdout/stderr through tee to append to the log file while still showing output
  exec > >(tee -a "$LOG_FILE") 2>&1
fi

# (goaccess removed here - we run it once at the end of the script)

# Rotate logs — keep N days (configurable via KEEP_ROTATED_LOGS)
find "$LOG_DIR" -name "update-repo.log.*.gz" -mtime +$KEEP_ROTATED_LOGS -delete
if [ -f "$LOG_FILE" ]; then
  gzip -f "$LOG_FILE" >/dev/null 2>&1
  mv "$LOG_FILE.gz" "$LOG_FILE.$(date '+%Y-%m-%d').gz" 2>/dev/null || true
fi

# Logging helper
log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') | $1" | tee -a "$LOG_FILE"
}

# Debug helper
debug() {
  [ "${DEBUG:-0}" -ne 0 ] 2>/dev/null && log "[DEBUG] $1" || true
}

# Print startup banner
echo "==========================================" >> "$LOG_FILE"
log "🚀 Starting git-pull-only-if-new-changes.sh version $SCRIPT_VERSION"
echo "==========================================" >> "$LOG_FILE"

# Check if nginx is running
check_nginx_health() {
  if sudo systemctl is-active --quiet "$SERVICE" 2>/dev/null; then
    return 0
  else
    return 1
  fi
}

# Get hash of aggregated logs to detect changes
get_agg_hash() {
  find /var/log/nginx -name "access.log*" -printf '%s %T@\n' 2>/dev/null | sort | md5sum 2>/dev/null | cut -d' ' -f1 || echo ""
}

# Check for git changes with caching
check_for_changes() {
  # Try cache first
  if [ -f "$REMOTE_HASH_CACHE" ]; then
    local cache_age=$(($(date +%s) - $(stat -c %Y "$REMOTE_HASH_CACHE" 2>/dev/null || stat -f %m "$REMOTE_HASH_CACHE" 2>/dev/null || echo 0)))
    if [ "$cache_age" -lt "$REMOTE_HASH_CACHE_TTL" ]; then
      REMOTE_HASH=$(cat "$REMOTE_HASH_CACHE")
      debug "Using cached remote hash (age: ${cache_age}s)"
      return 0
    fi
  fi
  
  # Cache expired or missing—fetch fresh
  git fetch origin "$BRANCH" >/dev/null 2>&1
  REMOTE_HASH=$(git rev-parse "origin/$BRANCH")
  echo "$REMOTE_HASH" > "$REMOTE_HASH_CACHE"
  debug "Fetched fresh remote hash and cached"
  return 0
}

# Deploy changes to web root
deploy_changes() {
  log "📦 Deploying new content..."
  
  # Ensure target directory exists
  if sudo mkdir -p "$TARGET_DIR" 2>/dev/null || true; then
    log "📁 Ensured target directory exists: $TARGET_DIR"
  fi

  local deploy_ok=0
  
  # Sync using rsync for safer updates
  if command -v rsync >/dev/null 2>&1; then
    if sudo rsync -a --delete --chmod=Du=rwx,Dg=rx,Do=rx,Fu=rw,Fg=r "$SOURCE_DIR"/ "$TARGET_DIR"/ >> "$LOG_FILE" 2>&1; then
      log "📦 Deployment completed successfully via rsync."
      deploy_ok=1
    else
      log "❌ rsync deployment failed."
      return 1
    fi
  else
    # Fallback to cp
    if sudo rm -rf "$TARGET_DIR"/* && sudo cp -vr "$SOURCE_DIR"/* "$TARGET_DIR"/ >> "$LOG_FILE" 2>&1; then
      log "📦 Deployment completed successfully via cp fallback."
      deploy_ok=1
    else
      log "❌ Deployment failed — cp fallback failed."
      return 1
    fi
  fi

  if [ "$deploy_ok" -eq 1 ]; then
    # Record deployed commit marker
    local local_short=$(git rev-parse --short "$LOCAL_HASH" 2>/dev/null || echo "$LOCAL_HASH")
    if sudo bash -c "printf '%s\n' '$local_short' > '$TARGET_DIR/.deployed_commit'" 2>/dev/null; then
      deploy_append [DEPLOY] "Wrote deployed commit marker: $TARGET_DIR/.deployed_commit => $local_short"
      sudo chown opc:opc "$TARGET_DIR/.deployed_commit" 2>/dev/null || true
      sudo chmod 644 "$TARGET_DIR/.deployed_commit" 2>/dev/null || true
    fi
    
    # Diagnostics
    local src_count=$(find "$SOURCE_DIR" -type f 2>/dev/null | wc -l || echo 0)
    local tgt_count=$(sudo find "$TARGET_DIR" -type f 2>/dev/null | wc -l || echo 0)
    deploy_append [DEPLOY] "Source files: $src_count; Target files: $tgt_count"
    
    return 0
  fi
  return 1
}

# Reload nginx with health check
reload_nginx() {
  if ! check_nginx_health; then
    log "⚠️ Warning: $SERVICE is not running before reload"
  fi
  
  if sudo systemctl reload "$SERVICE" 2>/dev/null; then
    sleep 1
    if check_nginx_health; then
      log "🚀 $SERVICE reloaded successfully."
      return 0
    else
      log "❌ $SERVICE stopped after reload — check configuration"
      return 1
    fi
  else
    log "❌ Failed to reload $SERVICE — check system logs."
    return 1
  fi
}

cd "$REPO_DIR" || { log "❌ Repo not found: $REPO_DIR"; exit 1; }

# Ensure tracking branch
git remote update >/dev/null 2>&1
git rev-parse --abbrev-ref "$BRANCH"@{upstream} >/dev/null 2>&1 || \
  git branch --set-upstream-to=origin/"$BRANCH" "$BRANCH" >/dev/null 2>&1

# Get local hash and check for remote changes (with caching)
LOCAL_HASH=$(git rev-parse "$BRANCH")
check_for_changes  # Sets REMOTE_HASH with caching

# Show last local commit short id and time information
if git rev-parse --verify "$LOCAL_HASH" >/dev/null 2>&1; then
  LAST_SHORT=$(git rev-parse --short "$LOCAL_HASH" 2>/dev/null || echo "$LOCAL_HASH")
  LAST_EPOCH=$(git show -s --format=%ct "$LOCAL_HASH" 2>/dev/null || echo 0)
  LAST_LOCAL_TIME=$(git show -s --format=%cd --date=local "$LOCAL_HASH" 2>/dev/null || echo "unknown")
  NOW_EPOCH=$(date +%s)
  if [ "$LAST_EPOCH" -gt 0 ] 2>/dev/null; then
    DIFF_SEC=$((NOW_EPOCH - LAST_EPOCH))
    days=$((DIFF_SEC/86400))
    hours=$(((DIFF_SEC%86400)/3600))
    mins=$(((DIFF_SEC%3600)/60))
    if [ "$days" -gt 0 ]; then
      DIFF_HUMAN="${days}d ${hours}h ${mins}m"
    elif [ "$hours" -gt 0 ]; then
      DIFF_HUMAN="${hours}h ${mins}m"
    elif [ "$mins" -gt 0 ]; then
      DIFF_HUMAN="${mins}m"
    else
      DIFF_HUMAN="${DIFF_SEC}s"
    fi
  else
    DIFF_HUMAN="unknown"
  fi
  log "🔎 Last local commit: ${LAST_SHORT} — committed at: ${LAST_LOCAL_TIME} (local time), ~${DIFF_HUMAN} ago"
fi

if [ "$LOCAL_HASH" != "$REMOTE_HASH" ]; then
  log "🔄 New changes detected — pulling updates..."
  if git pull origin "$BRANCH" >> "$LOG_FILE" 2>&1; then
    log "✅ Pull successful"
    if deploy_changes; then
      reload_nginx
    else
      log "❌ Deployment failed — check file permissions or paths."
    fi
  else
    log "❌ Git pull failed — check repository or network connection."
  fi
else
  log "✔️ No new changes — repository is up to date."
fi

# Aggregate nginx access logs into a dated file (so goaccess can consume a stable, long-lived
# artifact), keep 30 days of aggregates, then run goaccess once against today's aggregated log.
ACCESS_LOG_DIR="/var/log/nginx"
ACCESS_GLOB="$ACCESS_LOG_DIR/access.log*"
AGG_PREFIX="$LOG_DIR/nginx-access-aggregated"
AGG_TODAY="$AGG_PREFIX.$(date '+%Y-%m-%d').log"

# Clean up old aggregated logs (keep N days, configurable via KEEP_AGGREGATED_LOGS)
find "$LOG_DIR" -name "nginx-access-aggregated.*.log.gz" -mtime +$KEEP_AGGREGATED_LOGS -delete || true

# Build today's aggregated log by concatenating current and rotated logs (uncompressing gz if needed)
# Aggressive mode: attempt to read all candidate files via sudo (so script can run as opc)
: > "$AGG_TODAY" || true
# Build a candidate list from local glob and sudo listing to capture all files
candidates=()
# local glob first
for p in $ACCESS_GLOB; do
  [ -e "$p" ] && candidates+=("$p")
done

# then try sudo listing (best-effort). Use a safe loop that tolerates no output.
if command -v sudo >/dev/null 2>&1; then
  while IFS= read -r -d $'\0' p; do
    [ -n "$p" ] && candidates+=("$p")
  done < <(sudo bash -c 'for f in /var/log/nginx/access.log*; do [ -e "$f" ] && printf "%s\0" "$f"; done' 2>/dev/null) || true
fi

# Deduplicate while preserving order (portable: avoid associative arrays for macOS compatibility)
unique_candidates=()
for p in "${candidates[@]:-}"; do
  found=0
  for q in "${unique_candidates[@]:-}"; do
    if [ "$p" = "$q" ]; then
      found=1
      break
    fi
  done
  if [ "$found" -eq 0 ]; then
    unique_candidates+=("$p")
  fi
done

read_count=0
for f in "${unique_candidates[@]}"; do
  # Always try reading via sudo to avoid permission issues
  if [[ "$f" == *.gz ]]; then
    if command -v zcat >/dev/null 2>&1; then
      if sudo zcat -- "$f" >> "$AGG_TODAY" 2>/dev/null; then
        deploy_append [AGG] "Aggregated (gz via sudo zcat): $f"
        read_count=$((read_count+1))
      else
        # fallback to gzip -dc via sudo
        if sudo gzip -dc -- "$f" >> "$AGG_TODAY" 2>/dev/null; then
          deploy_append [AGG] "Aggregated (gz via sudo gzip -dc): $f"
          read_count=$((read_count+1))
        else
          deploy_append [DIAG] "Failed to read gz file via sudo: $f"
        fi
      fi
    else
      if sudo gzip -dc -- "$f" >> "$AGG_TODAY" 2>/dev/null; then
        deploy_append [AGG] "Aggregated (gz via sudo gzip -dc): $f"
        read_count=$((read_count+1))
      else
        deploy_append [DIAG] "Failed to read gz file via sudo gzip -dc: $f"
      fi
    fi
  else
    if sudo cat -- "$f" >> "$AGG_TODAY" 2>/dev/null; then
      deploy_append [AGG] "Aggregated (plain via sudo cat): $f"
      read_count=$((read_count+1))
    else
      deploy_append [DIAG] "Failed to read file via sudo cat: $f"
    fi
  fi
done

if [ "$read_count" -gt 0 ]; then
  deploy_append [AGG] "Aggregated $read_count files into $AGG_TODAY"
fi

# If aggregated log is non-empty, prefer it; otherwise diagnose why and force-aggregate with sudo before falling back
DAILY_TS=$(date '+%Y%m%d_%H%M%S')
DAILY_WEBFILE="$TARGET_DIR/stats_daily_$DAILY_TS.html"
DAILY_SYM="$TARGET_DIR/stats_daily_latest.html"
LIVE_WEBFILE="$TARGET_DIR/stats_live_$DAILY_TS.html"
LIVE_SYM="$TARGET_DIR/stats_live_latest.html"

# Check if report generation is needed (cache-based)
current_agg_hash=$(get_agg_hash)
cached_agg_hash=$(cat "$AGG_HASH_CACHE" 2>/dev/null || echo "")
needs_report_generation=false

if [ "$current_agg_hash" != "$cached_agg_hash" ] || [ "$REPORT_ON_NO_CHANGES" = "true" ]; then
  needs_report_generation=true
  echo "$current_agg_hash" > "$AGG_HASH_CACHE"
else
  deploy_append [AGG] "⏭️ Log files unchanged, skipping report generation"
fi

if [ "$needs_report_generation" = "true" ] && [ -s "$AGG_TODAY" ]; then
  deploy_append [AGG] "Using aggregated log: $AGG_TODAY (size: $(stat -c%s "$AGG_TODAY" 2>/dev/null || stat -f%z "$AGG_TODAY" 2>/dev/null || echo 'unknown'))"
  # Generate daily report from aggregated log
  if sudo goaccess "$AGG_TODAY" --log-format=$GOACCESS_LOG_FORMAT -o "$DAILY_WEBFILE" >> "$LOG_FILE" 2>&1; then
    deploy_append [AGG] "Daily report generated: $DAILY_WEBFILE"
    sudo chown opc:opc "$DAILY_WEBFILE" 2>/dev/null || true
    sudo chmod 644 "$DAILY_WEBFILE" 2>/dev/null || true
    sudo ln -snf "$DAILY_WEBFILE" "$DAILY_SYM" 2>/dev/null || ln -snf "$DAILY_WEBFILE" "$DAILY_SYM" 2>/dev/null
  else
    deploy_append [AGG] "⚠️ goaccess failed on aggregated log: $AGG_TODAY"
  fi
fi

# Compress today's aggregated log for long-term storage (overwrite existing .gz)
if [ -f "$AGG_TODAY" ]; then
  gzip -f "$AGG_TODAY" >/dev/null 2>&1 || true
fi

# Final comparison: show local git short id vs deployed commit marker (if present)
LOCAL_SHORT_FINAL=$(git rev-parse --short "$LOCAL_HASH" 2>/dev/null || echo "unknown")
DEPLOYED_MARK=""
if [ -f "$TARGET_DIR/.deployed_commit" ]; then
  DEPLOYED_MARK=$(sudo cat "$TARGET_DIR/.deployed_commit" 2>/dev/null || cat "$TARGET_DIR/.deployed_commit" 2>/dev/null || echo "")
fi
# If the deployed marker is missing, log a diagnostic and optionally auto-create it.
if [ -z "$DEPLOYED_MARK" ]; then
  deploy_append [DIAG] "deployed_marker missing at $TARGET_DIR/.deployed_commit"
  deploy_append [DIAG] "If you want the script to auto-create/update this marker when no deploy occurs, set AUTO_CREATE_DEPLOYED_MARKER=1 in the environment (destructive: will overwrite existing marker)."

  # Provide a helpful sudoers snippet example in the logs directory for admin use
  SUDOERS_EXAMPLE="$LOG_DIR/opc-goaccess-sudoers.example"
  if [ ! -f "$SUDOERS_EXAMPLE" ]; then
    cat > "$SUDOERS_EXAMPLE" <<'EOF'
# Example minimal sudoers entries for 'opc' to allow goaccess aggregation and deployment tasks
# Edit with visudo -f /etc/sudoers.d/opc-goaccess (as root) and verify binary paths on your system.
# Replace /usr/bin and /bin paths with the full paths from `which` on the server if different.
opc ALL=(root) NOPASSWD: /bin/cat, /usr/bin/zcat, /bin/gzip, /bin/ln, /bin/chown, /bin/chmod, /usr/bin/rsync, /bin/cp, /bin/mkdir, /bin/rm

# If your system uses different paths for chown/ln/gzip, adjust accordingly.
EOF
    deploy_append [DIAG] "Wrote sudoers example to: $SUDOERS_EXAMPLE"
  fi

  # Optionally auto-create the deployed marker (opt-in, disabled by default)
  if [ "${AUTO_CREATE_DEPLOYED_MARKER:-0}" -eq 1 ]; then
    # Try to write the marker using sudo, but fall back to a safer non-destructive check
    deploy_append [DIAG] "AUTO_CREATE_DEPLOYED_MARKER=1 enabled — attempting to create $TARGET_DIR/.deployed_commit"
    if command -v sudo >/dev/null 2>&1; then
      if sudo bash -c "umask 022; printf '%s\n' '$LOCAL_SHORT_FINAL' > '$TARGET_DIR/.deployed_commit'" 2>/dev/null; then
        # best-effort adjust ownership and perms
        sudo chown opc:opc "$TARGET_DIR/.deployed_commit" 2>/dev/null || true
        sudo chmod 644 "$TARGET_DIR/.deployed_commit" 2>/dev/null || true
        DEPLOYED_MARK="$LOCAL_SHORT_FINAL"
        deploy_append [DEPLOY] "Auto-created deployed marker: $TARGET_DIR/.deployed_commit => $LOCAL_SHORT_FINAL"
      else
        # If sudo failed, attempt to create as current user only if TARGET_DIR is writable
        if printf '%s\n' "$LOCAL_SHORT_FINAL" > "$TARGET_DIR/.deployed_commit" 2>/dev/null; then
          chown opc:opc "$TARGET_DIR/.deployed_commit" 2>/dev/null || true
          chmod 644 "$TARGET_DIR/.deployed_commit" 2>/dev/null || true
          DEPLOYED_MARK="$LOCAL_SHORT_FINAL"
          deploy_append [DEPLOY] "Auto-created deployed marker without sudo: $TARGET_DIR/.deployed_commit => $LOCAL_SHORT_FINAL"
        else
          deploy_append [DIAG] "Auto-create of deployed marker failed (sudo not available or insufficient privileges)"
        fi
      fi
    else
      # No sudo on system; try to write directly (best-effort)
      if printf '%s\n' "$LOCAL_SHORT_FINAL" > "$TARGET_DIR/.deployed_commit" 2>/dev/null; then
        chown opc:opc "$TARGET_DIR/.deployed_commit" 2>/dev/null || true
        chmod 644 "$TARGET_DIR/.deployed_commit" 2>/dev/null || true
        DEPLOYED_MARK="$LOCAL_SHORT_FINAL"
        deploy_append [DEPLOY] "Auto-created deployed marker without sudo: $TARGET_DIR/.deployed_commit => $LOCAL_SHORT_FINAL"
      else
        deploy_append [DIAG] "Auto-create of deployed marker failed (no sudo and not writable)"
      fi
    fi
  fi
fi

deploy_append [GIT] "Final comparison: local git short=$LOCAL_SHORT_FINAL deployed_marker=$DEPLOYED_MARK"
exit 0