#!/bin/bash
# Wraps the SwiftPM binary into build/Nerda.app — an app bundle is just a
# folder with a plist and the binary in the right place.
#
#   ./build.sh          release build
#   ./build.sh debug    debug build
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"
NAME="Nerda"
APP="build/$NAME.app"

swift build -c "$CONFIG"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
# SwiftPM links reproducibly, which records the deployment target as the SDK
# the app was built with. macOS reads that SDK to decide which look to give
# the app, and for 15.4 it keeps the old one: smaller traffic lights, tighter
# window corners. Stamp the SDK it was really built with.
vtool -set-build-version macos 15.4 "$(xcrun --show-sdk-version)" -replace \
  -output "$APP/Contents/MacOS/$NAME" ".build/$CONFIG/$NAME"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleExecutable</key><string>$NAME</string>
  <key>CFBundleIdentifier</key><string>dev.nerda.browser</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>$(date +%Y%m%d%H%M)</string>
  <key>LSMinimumSystemVersion</key><string>15.4</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <!-- Without these, macOS ends the app the moment a page (a video call) asks
       for the camera or microphone. -->
  <key>NSCameraUsageDescription</key><string>A website you open wants to use the camera.</string>
  <key>NSMicrophoneUsageDescription</key><string>A website you open wants to use the microphone.</string>
</dict>
</plist>
PLIST

# Ad-hoc signature: enough to run on this Mac, not to hand to anyone else.
codesign --force --sign - "$APP"
echo "$APP"
