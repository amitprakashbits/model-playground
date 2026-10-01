#!/bin/bash
# Builds ModelPlayground.app into ./build
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/build/Model Playground.app"

echo "Compiling..."
(cd "$ROOT/App" && swift build -c release)
BIN="$(cd "$ROOT/App" && swift build -c release --show-bin-path)/ModelPlayground"

echo "Bundling..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ModelPlayground"
cp "$ROOT/backend/server.py" "$APP/Contents/Resources/server.py"

ICONSET="$ROOT/build/AppIcon.iconset"
if [ ! -f "$ROOT/build/AppIcon.icns" ]; then
  swift "$ROOT/scripts/make_icon.swift" "$ICONSET"
  iconutil -c icns "$ICONSET" -o "$ROOT/build/AppIcon.icns"
  rm -rf "$ICONSET"
fi
cp "$ROOT/build/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Model Playground</string>
  <key>CFBundleDisplayName</key><string>Model Playground</string>
  <key>CFBundleIdentifier</key><string>local.modelplayground.app</string>
  <key>CFBundleExecutable</key><string>ModelPlayground</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSAppTransportSecurity</key>
  <dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
echo "Built: $APP"
