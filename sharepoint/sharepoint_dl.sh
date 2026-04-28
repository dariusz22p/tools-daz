#!/usr/bin/env bash
# Wrapper script for sharepoint_dl.py (macOS / Linux)
# Automatically sets up a virtual environment and installs dependencies.
#
# Usage:
#   ./sharepoint_dl.sh [--browser BROWSER] <sharepoint_stream_url> [output_filename]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_DIR="$SCRIPT_DIR/.venv"
PYTHON_SCRIPT="$SCRIPT_DIR/sharepoint_dl.py"

# Find a suitable python3
find_python() {
    for cmd in python3 python; do
        if command -v "$cmd" &>/dev/null; then
            if "$cmd" -c "import sys; sys.exit(0 if sys.version_info >= (3,7) else 1)" 2>/dev/null; then
                echo "$cmd"
                return
            fi
        fi
    done
    echo ""
}

PYTHON="$(find_python)"
if [[ -z "$PYTHON" ]]; then
    echo "ERROR: Python 3.7+ not found. Please install Python 3." >&2
    exit 1
fi

# Create venv if it doesn't exist
if [[ ! -d "$VENV_DIR" ]]; then
    echo "Creating virtual environment in $VENV_DIR ..."
    "$PYTHON" -m venv "$VENV_DIR"
fi

# Activate venv
source "$VENV_DIR/bin/activate"

# Install dependencies if missing
if ! python -c "import requests" &>/dev/null || ! python -c "import cryptography" &>/dev/null; then
    echo "Installing Python dependencies..."
    pip install --quiet requests cryptography
fi

# Run the downloader (it will check remaining requirements itself)
python "$PYTHON_SCRIPT" "$@"
