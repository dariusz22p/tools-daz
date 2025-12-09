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

# goaccess


# Toggle debug: set DEBUG=1 to enable verbose tracing and live logging
DEBUG="${DEBUG:-0}"

REPO_DIR="/git/python-games"
SOURCE_DIR="$REPO_DIR/games-HTML5"
# Allow overriding TARGET_DIR via environment; default to /usr/share/nginx/html
TARGET_DIR="${TARGET_DIR:-/usr/share/nginx/html}"
BRANCH="main"
LOG_DIR="/git/logs"
LOG_FILE="$LOG_DIR/update-repo.log"
SERVICE="nginx"

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

# Rotate logs — keep 7 days
find "$LOG_DIR" -name "update-repo.log.*.gz" -mtime +7 -delete
if [ -f "$LOG_FILE" ]; then
  mv "$LOG_FILE" "$LOG_FILE.$(date '+%Y-%m-%d').gz"
  gzip -f "$LOG_FILE.$(date '+%Y-%m-%d').gz" >/dev/null 2>&1
fi

# Logging helper
log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') | $1" | tee -a "$LOG_FILE"
}

cd "$REPO_DIR" || { log "❌ Repo not found: $REPO_DIR"; exit 1; }

# Fetch and ensure tracking branch
git remote update >/dev/null 2>&1
git fetch origin "$BRANCH" >/dev/null 2>&1

git rev-parse --abbrev-ref "$BRANCH"@{upstream} >/dev/null 2>&1 || \
  git branch --set-upstream-to=origin/"$BRANCH" "$BRANCH" >/dev/null 2>&1

LOCAL_HASH=$(git rev-parse "$BRANCH")
REMOTE_HASH=$(git rev-parse "origin/$BRANCH")

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
    log "✅ Pull successful — deploying new content..."

    # Ensure target directory exists (create via sudo if needed)
    if sudo mkdir -p "$TARGET_DIR" 2>/dev/null || true; then
      log "📁 Ensured target directory exists: $TARGET_DIR"
    fi

    DEPLOY_OK=0
    # Sync using rsync for safer, atomic-like updates; delete removed files on the target
    if command -v rsync >/dev/null 2>&1; then
      if sudo rsync -a --delete --chmod=Du=rwx,Dg=rx,Do=rx,Fu=rw,Fg=r "$SOURCE_DIR"/ "$TARGET_DIR"/ >> "$LOG_FILE" 2>&1; then
        log "📦 Deployment completed successfully via rsync."
        DEPLOY_OK=1
      else
        log "❌ rsync deployment failed."
        DEPLOY_OK=0
      fi
    else
      # Fallback to cp if rsync is not available
      if sudo rm -rf "$TARGET_DIR"/* && sudo cp -vr "$SOURCE_DIR"/* "$TARGET_DIR"/ >> "$LOG_FILE" 2>&1; then
        log "📦 Deployment completed successfully via cp fallback."
        DEPLOY_OK=1
      else
        log "❌ Deployment failed — cp fallback failed."
        DEPLOY_OK=0
      fi
    fi

    if [ "$DEPLOY_OK" -eq 1 ]; then
      # Record deployed commit marker in target so we can compare later
      LOCAL_SHORT=$(git rev-parse --short "$LOCAL_HASH" 2>/dev/null || echo "$LOCAL_HASH")
      if sudo bash -c "printf '%s\n' '$LOCAL_SHORT' > '$TARGET_DIR/.deployed_commit'" 2>/dev/null; then
        deploy_append [DEPLOY] "Wrote deployed commit marker: $TARGET_DIR/.deployed_commit => $LOCAL_SHORT"
        sudo chown opc:opc "$TARGET_DIR/.deployed_commit" 2>/dev/null || true
        sudo chmod 644 "$TARGET_DIR/.deployed_commit" 2>/dev/null || true
      else
        deploy_append [DEPLOY] "Failed to write deployed commit marker to $TARGET_DIR/.deployed_commit"
      fi

      # Diagnostic: compare file counts and sample differences between source and target
      SRC_COUNT=$(find "$SOURCE_DIR" -type f 2>/dev/null | wc -l || echo 0)
      TGT_COUNT=$(sudo find "$TARGET_DIR" -type f 2>/dev/null | wc -l || echo 0)
      deploy_append [DEPLOY] "Source files: $SRC_COUNT; Target files: $TGT_COUNT"
      deploy_append [DEPLOY] "Sample differences (first 50 lines):"
      sudo diff -rq --no-dereference "$SOURCE_DIR" "$TARGET_DIR" 2>/dev/null | head -n 50 | while IFS= read -r line; do deploy_append [DEPLOY] "  $line"; done

      # Reload Nginx only if deployment succeeded
      if sudo systemctl reload "$SERVICE"; then
        log "🚀 $SERVICE reloaded successfully."
      else
        log "⚠️ Failed to reload $SERVICE — check system logs."
      fi
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

# Clean up old aggregated logs (keep 30 days)
find "$LOG_DIR" -name "nginx-access-aggregated.*.log.gz" -mtime +30 -delete || true

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

# helper function defined earlier; use that deploy_append

if [ -s "$AGG_TODAY" ]; then
  deploy_append [AGG] "Using aggregated log: $AGG_TODAY (size: $(stat -c%s "$AGG_TODAY" 2>/dev/null || stat -f%z "$AGG_TODAY" 2>/dev/null || echo 'unknown'))"
  # Generate daily report from aggregated log
  if sudo goaccess "$AGG_TODAY" --log-format=COMBINED -o "$DAILY_WEBFILE" >> "$LOG_FILE" 2>&1; then
    deploy_append [AGG] "Daily report generated: $DAILY_WEBFILE"
    sudo chown opc:opc "$DAILY_WEBFILE" 2>/dev/null || true
    sudo chmod 644 "$DAILY_WEBFILE" 2>/dev/null || true
    sudo ln -snf "$DAILY_WEBFILE" "$DAILY_SYM" 2>/dev/null || ln -snf "$DAILY_WEBFILE" "$DAILY_SYM" 2>/dev/null
  else
    deploy_append [AGG] "⚠️ goaccess failed on aggregated log: $AGG_TODAY"
  fi
else
  # Diagnostic: which files matched and their readability/sizes
  files_found=0
  unreadable_list=()
  zero_list=()
  for f in $ACCESS_GLOB; do
    if [ -e "$f" ]; then
      files_found=1
      if [ -r "$f" ]; then
        size=$(stat -c%s "$f" 2>/dev/null || stat -f%z "$f" 2>/dev/null || echo 0)
        if [ "$size" -eq 0 ]; then
          zero_list+=("$f")
        fi
      else
        unreadable_list+=("$f")
      fi
    fi
  done
  if [ "$files_found" -eq 0 ]; then
    deploy_append [DIAG] "No access log files matched glob: $ACCESS_GLOB"
  else
    if [ ${#unreadable_list[@]} -gt 0 ]; then
      deploy_append [DIAG] "Unreadable log files: ${unreadable_list[*]}"
    fi
    if [ ${#zero_list[@]} -gt 0 ]; then
      deploy_append [DIAG] "Matched but zero-size logs: ${zero_list[*]}"
    fi
  fi

  # Force-aggregate using sudo to read log files directly (handles perms)
  deploy_append [AGG] "Attempting force-aggregate via sudo from /var/log/nginx/access.log*"
  : > "$AGG_TODAY" || true
  for f in /var/log/nginx/access.log*; do
    [ -e "$f" ] || continue
    case "$f" in
      *.gz)
        if sudo command -v zcat >/dev/null 2>&1; then
          sudo zcat -- "$f" >> "$AGG_TODAY" 2>/dev/null || true
        else
          sudo gzip -dc -- "$f" >> "$AGG_TODAY" 2>/dev/null || true
        fi
        ;;
      *)
        sudo cat -- "$f" >> "$AGG_TODAY" 2>/dev/null || true
        ;;
    esac
  done

  if [ -s "$AGG_TODAY" ]; then
    deploy_append [AGG] "Force-aggregate succeeded, aggregated size: $(stat -c%s "$AGG_TODAY" 2>/dev/null || stat -f%z "$AGG_TODAY" 2>/dev/null || echo 'unknown')"
    if sudo goaccess "$AGG_TODAY" --log-format=COMBINED -o "$DAILY_WEBFILE" >> "$LOG_FILE" 2>&1; then
      deploy_append [AGG] "Daily report generated from force-aggregate: $DAILY_WEBFILE"
      sudo chown opc:opc "$DAILY_WEBFILE" 2>/dev/null || true
      sudo chmod 644 "$DAILY_WEBFILE" 2>/dev/null || true
      sudo ln -snf "$DAILY_WEBFILE" "$DAILY_SYM" 2>/dev/null || ln -snf "$DAILY_WEBFILE" "$DAILY_SYM" 2>/dev/null
    else
      deploy_append [AGG] "⚠️ goaccess failed on force-aggregated log: $AGG_TODAY"
    fi
  else
    deploy_append [DIAG] "Force-aggregate produced no data; falling back to live access.log"
    # Live fallback report
    if sudo goaccess /var/log/nginx/access.log --log-format=COMBINED -o "$LIVE_WEBFILE" >> "$LOG_FILE" 2>&1; then
      deploy_append [AGG] "Live fallback report generated: $LIVE_WEBFILE"
      sudo chown opc:opc "$LIVE_WEBFILE" 2>/dev/null || true
      sudo chmod 644 "$LIVE_WEBFILE" 2>/dev/null || true
      sudo ln -snf "$LIVE_WEBFILE" "$LIVE_SYM" 2>/dev/null || ln -snf "$LIVE_WEBFILE" "$LIVE_SYM" 2>/dev/null
    else
      deploy_append [AGG] "⚠️ goaccess failed on live access.log — no report generated"
    fi
  fi
fi

# Compress today's aggregated log for long-term storage (overwrite existing .gz)
if [ -f "$AGG_TODAY" ]; then
  gzip -f "$AGG_TODAY" >/dev/null 2>&1 || true
fi

# Append today's aggregate to cumulative log (run once per day)
CUMULATIVE_LOG="$LOG_DIR/full_aggregate.log"
LAST_APPEND_MARK="$LOG_DIR/.last_cumulative_append"
if [ -f "$LOG_DIR/nginx-access-aggregated.$(date '+%Y-%m-%d').log" ]; then
  today_date=$(date '+%Y-%m-%d')
  last_added=$(cat "$LAST_APPEND_MARK" 2>/dev/null || echo "")
  if [ "$last_added" != "$today_date" ]; then
    if sudo cat "$LOG_DIR/nginx-access-aggregated.$today_date.log" >> "$CUMULATIVE_LOG" 2>/dev/null; then
      echo "$today_date" > "$LAST_APPEND_MARK" 2>/dev/null || true
      deploy_append [CUM] "Appended today's aggregate to cumulative: $CUMULATIVE_LOG"
    else
      deploy_append [CUM] "Failed to append today's aggregate to cumulative log"
    fi
  else
    deploy_append [CUM] "Today's aggregate already appended to cumulative log; skipping"
  fi
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

# Generate cumulative report from cumulative log if present
if [ -f "$CUMULATIVE_LOG" ] && [ -s "$CUMULATIVE_LOG" ]; then
  CUM_TS=$(date +%Y%m%d_%H%M%S)
  CUM_WEBFILE="$TARGET_DIR/stats_cumulative_$CUM_TS.html"
  CUM_SYM="$TARGET_DIR/stats_cumulative_latest.html"
  if sudo goaccess "$CUMULATIVE_LOG" --log-format=COMBINED -o "$CUM_WEBFILE" >> "$LOG_FILE" 2>&1; then
    deploy_append [CUM] "Cumulative report generated: $CUM_WEBFILE"
    sudo chown opc:opc "$CUM_WEBFILE" 2>/dev/null || true
    sudo chmod 644 "$CUM_WEBFILE" 2>/dev/null || true
    sudo ln -snf "$CUM_WEBFILE" "$CUM_SYM" 2>/dev/null || ln -snf "$CUM_WEBFILE" "$CUM_SYM" 2>/dev/null
  else
    deploy_append [CUM] "⚠️ goaccess failed generating cumulative report"
  fi
fi

# At the end of the script, print a concise excerpt from the main update log to
# help when invoked from cron or via automation. This is best-effort and will not
# error the script if tail is unavailable.
echo
echo "==== End of run summary — last lines from $LOG_FILE ===="
if command -v tail >/dev/null 2>&1; then
  tail -n 200 "$LOG_FILE" 2>/dev/null || true
else
  # Portable fallback: print last ~200 lines using sed if available
  if command -v sed >/dev/null 2>&1; then
    sed -n "-200,
	$ p" "$LOG_FILE" 2>/dev/null || cat "$LOG_FILE" 2>/dev/null || true
  else
    cat "$LOG_FILE" 2>/dev/null || true
  fi
fi

echo "==== End of run ===="

echo
echo "==== Deploy diagnostics — last lines from $DEPLOY_LOG ===="
if [ -f "$DEPLOY_LOG" ]; then
  if command -v tail >/dev/null 2>&1; then
    tail -n 200 "$DEPLOY_LOG" 2>/dev/null || true
  else
    if command -v sed >/dev/null 2>&1; then
      sed -n "-200,
	$ p" "$DEPLOY_LOG" 2>/dev/null || cat "$DEPLOY_LOG" 2>/dev/null || true
    else
      cat "$DEPLOY_LOG" 2>/dev/null || true
    fi
  fi
else
  echo "(no deploy log found at $DEPLOY_LOG)"
fi
