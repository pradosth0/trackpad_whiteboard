#!/bin/bash
# Builds a release binary and wraps it in TrackpadBoard.app (double-clickable).
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
APP="TrackpadBoard.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/TrackpadBoard "$APP/Contents/MacOS/TrackpadBoard"
# Math fonts of the LaTeX renderer; SwiftPM looks for resource bundles at the app's top level.
cp -R .build/release/*.bundle "$APP/"
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Trackpad Board</string>
    <key>CFBundleIdentifier</key><string>local.trackpad-board</string>
    <key>CFBundleExecutable</key><string>TrackpadBoard</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF
echo "Built $APP"
