#!/bin/bash
# Builds Trackpad Board and installs it into the Applications folder.
set -euo pipefail
cd "$(dirname "$0")"

if [[ "$(uname)" != "Darwin" ]]; then
    echo "Trackpad Board only runs on macOS." >&2
    exit 1
fi
if ! xcode-select -p >/dev/null 2>&1 || ! command -v swift >/dev/null 2>&1; then
    echo "The Swift compiler is missing. Install Apple's Command Line Tools with:" >&2
    echo "    xcode-select --install" >&2
    echo "then run this script again." >&2
    exit 1
fi

./build_app.sh

# /Applications when writable, otherwise the per-user Applications folder.
DEST="/Applications"
if [[ ! -w "$DEST" ]]; then
    DEST="$HOME/Applications"
    mkdir -p "$DEST"
fi
rm -rf "$DEST/TrackpadBoard.app"
cp -R TrackpadBoard.app "$DEST/"

echo
echo "Installed $DEST/TrackpadBoard.app"
echo "Open it from Spotlight (\"Trackpad Board\") or with:"
echo "    open \"$DEST/TrackpadBoard.app\""
