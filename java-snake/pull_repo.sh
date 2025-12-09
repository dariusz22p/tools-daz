#!/usr/bin/env bash
set -euo pipefail

# pull_tools_daz.sh
# Clone or update https://github.com/dariusz22p/tools-daz into /git/tools-daz
# Make all bash scripts executable, and create/update a symlink for
# generate_goaccess_report.sh into /git (i.e. /git/generate_goaccess_report.sh)

REPO_URL="https://github.com/dariusz22p/tools-daz.git"
# Allow overriding the base directory via first argument or env var TARGET_BASE
# Usage: pull_tools_daz.sh [TARGET_BASE]
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

# Ensure target base exists
if [[ ! -d "$TARGET_BASE" ]]; then
  echo "Creating $TARGET_BASE (may require sudo)..."
  if mkdir -p "$TARGET_BASE" 2>/dev/null; then
    echo "Created $TARGET_BASE"
  else
    echo "Could not create $TARGET_BASE without sudo; attempting with sudo..."
    if sudo mkdir -p "$TARGET_BASE" 2>/dev/null; then
      sudo chown "$USER:" "$TARGET_BASE" || true
    else
      warn "Failed to create $TARGET_BASE (read-only filesystem or insufficient privileges)."
      FALLBACK="$HOME/git"
      echo "Falling back to $FALLBACK"
      TARGET_BASE="$FALLBACK"
      TARGET_DIR="$TARGET_BASE/tools-daz"
      SYMLINK_DEST="$TARGET_BASE/generate_goaccess_report.sh"
      mkdir -p "$TARGET_BASE"
    fi
  fi
fi

# Clone or pull
if [[ -d "$TARGET_DIR/.git" ]]; then
  echo "Updating existing repo at $TARGET_DIR"
  # Portable: cd into target dir and run git commands in a subshell
  (
    cd "$TARGET_DIR" || { echo "Failed to cd to $TARGET_DIR"; exit 1; }
    git fetch --all --prune
    git reset --hard origin/main
    git pull --ff-only origin main || true
  )
else
  echo "Cloning repo into $TARGET_DIR"
  git clone "$REPO_URL" "$TARGET_DIR"
fi

# Make all .sh and .s files executable under the repo
find "$TARGET_DIR" -type f \( -name "*.sh" -o -name "*.s" \) -print0 | while IFS= read -r -d '' f; do
  if [[ ! -x "$f" ]]; then
    echo "Making executable: $f"
    chmod +x "$f"
  fi
done

# If generate_goaccess_report.sh exists in repo, link it into /git
REPO_GOACCESS="$TARGET_DIR/java-snake/generate_goaccess_report.sh"
if [[ -f "$REPO_GOACCESS" ]]; then
  echo "Linking $REPO_GOACCESS -> $SYMLINK_DEST"
  # Backup old symlink if present
  if [[ -L "$SYMLINK_DEST" || -f "$SYMLINK_DEST" ]]; then
    echo "Removing old $SYMLINK_DEST"
    rm -f "$SYMLINK_DEST"
  fi
  ln -s "$REPO_GOACCESS" "$SYMLINK_DEST"
  echo "Symlink created: $SYMLINK_DEST -> $REPO_GOACCESS"
else
  echo "$REPO_GOACCESS not found in repo; skipping symlink"
fi

echo "Done."