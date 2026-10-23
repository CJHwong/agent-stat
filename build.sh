#!/bin/bash
# Build the menu bar app. swiftc only, no Xcode project.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
APP="$HERE/.build/AgentStat.app"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -o "$APP/Contents/MacOS/AgentStat" "$HERE/src/"*.swift \
    -framework AppKit -framework SwiftUI

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>AgentStat</string>
    <key>CFBundleIdentifier</key><string>io.github.cjhwong.agentstat</string>
    <key>CFBundleName</key><string>AgentStat</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

# Sign with a development identity when the machine has one, so the bundle keeps
# a stable identity across rebuilds. CODESIGN_IDENTITY overrides it.
IDENTITY="${CODESIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
    IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*"\(Apple Development:.*\)"/\1/p' | head -1)
fi
codesign --force --sign "${IDENTITY:--}" "$APP" 2>/dev/null || true
echo "built: $APP"
