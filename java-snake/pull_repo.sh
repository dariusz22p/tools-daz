#!/usr/bin/env bash
set -euo pipefail

# pull_repo.sh
# Clone or update https://github.com/dariusz22p/tools-daz into a target base
# (default /git, or override by passing a path as first argument or env var TARGET_BASE).
# Make all .sh/.s files executable and create/update a symlink to
# generate_goaccess_report.sh at $TARGET_BASE/generate_goaccess_report.sh

REPO_URL="https://github.com/dariusz22p/tools-daz.git"

info() { echo "[info] $*"; }
warn() { echo "[warn] $*" >&2; }

# Allow overriding the base directory via first argument or env var TARGET_BASE
TARGET_BASE_ARG="${1:-}"
TARGET_BASE_ENV="${TARGET_BASE:-}"
if [[ -n "$TARGET_BASE_ARG" ]]; then
  TARGET_BASE="$TARGET_BASE_ARG"
elif [[ -n "$TARGET_BASE_ENV" ]]; then
  TARGET_BASE="$TARGET_BASE_ENV"
else
  TARGET_BASE="/git"
fi

TARGET_DIR="$TARGET_BASE/tools-daz"
SYMLINK_DEST="$TARGET_BASE/generate_goaccess_report.sh"

# Ensure target base exists, try without sudo first then sudo, else fallback to $HOME/git
if [[ ! -d "$TARGET_BASE" ]]; then
  info "Ensuring base directory exists: $TARGET_BASE"
  if mkdir -p "$TARGET_BASE" 2>/dev/null; then
    info "Created $TARGET_BASE"
  else
    info "Attempting to create $TARGET_BASE with sudo"
    if sudo mkdir -p "$TARGET_BASE" 2>/dev/null; then
      sudo chown "$USER:" "$TARGET_BASE" 2>/dev/null || true
    else
      warn "Failed to create $TARGET_BASE (read-only FS or insufficient privileges). Falling back to \$HOME/git"
      TARGET_BASE="$HOME/git"
      TARGET_DIR="$TARGET_BASE/tools-daz"
      SYMLINK_DEST="$TARGET_BASE/generate_goaccess_report.sh"
      mkdir -p "$TARGET_BASE"
      info "Using fallback base: $TARGET_BASE"
    fi
  fi
fi

# Clone or update repository (use subshell+cd for portability)
if [[ -d "$TARGET_DIR/.git" ]]; then
  info "Updating existing repo at $TARGET_DIR"
  (
    cd "$TARGET_DIR" || { warn "Failed to cd to $TARGET_DIR"; exit 1; }
    git fetch --all --prune
    git reset --hard origin/main
    git pull --ff-only origin main || true
  )
else
  info "Cloning repo into $TARGET_DIR"
  git clone "$REPO_URL" "$TARGET_DIR"
fi

# Make all .sh and .s files executable under the repo
info "Making .sh and .s files executable"
find "$TARGET_DIR" -type f \( -name "*.sh" -o -name "*.s" \) -print0 | while IFS= read -r -d '' f; do
  if [[ ! -x "$f" ]]; then
    info "chmod +x $f"
    chmod +x "$f"
  fi
done

# If generate_goaccess_report.sh exists in repo, link it into TARGET_BASE
REPO_GOACCESS="$TARGET_DIR/java-snake/generate_goaccess_report.sh"
if [[ -f "$REPO_GOACCESS" ]]; then
  info "Linking $REPO_GOACCESS -> $SYMLINK_DEST"
  if [[ -L "$SYMLINK_DEST" || -f "$SYMLINK_DEST" ]]; then
    info "Removing old $SYMLINK_DEST"
    rm -f "$SYMLINK_DEST"
  fi
  ln -s "$REPO_GOACCESS" "$SYMLINK_DEST"
  info "Symlink created: $SYMLINK_DEST -> $REPO_GOACCESS"
else
  warn "$REPO_GOACCESS not found in repo; skipping symlink"
fi

info "Done."