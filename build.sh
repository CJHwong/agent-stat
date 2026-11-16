#!/bin/bash
# Build the menu bar app. swiftc only, no Xcode project.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
APP="$HERE/.build/Agent Board.app"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -o "$APP/Contents/MacOS/AgentStat" "$HERE/src/"*.swift \
    -framework AppKit -framework SwiftUI

# The app icon is the project logo drawn full bleed, because macOS frames an icon
# that carries its own rounded corners. macOS wants an icns with fixed sizes.
WORK="$(mktemp -d)"
ICONSET="$WORK/AppIcon.iconset"
mkdir "$ICONSET"
for size in 16 32 128 256 512; do
    sips -s format png -z "$size" "$size" "$HERE/docs/assets/agent-board-app-icon.png" \
        --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -s format png -z "$double" "$double" "$HERE/docs/assets/agent-board-app-icon.png" \
        --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm "$ICONSET"/*.png
rmdir "$ICONSET" "$WORK"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>AgentStat</string>
    <key>CFBundleIdentifier</key><string>io.github.cjhwong.agentstat</string>
    <key>CFBundleName</key><string>Agent Board</string>
    <key>CFBundleDisplayName</key><string>Agent Board</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
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
