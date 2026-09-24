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

# The icon, drawn in assets/AppIcon.svg, rendered with what macOS ships:
# sips draws the SVG at each size (keeping it transparent, which Quick Look
# doesn't), iconutil packs the sizes.
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET" "$APP/Contents/Resources"
for size in 16 32 128 256 512; do
  sips -s format png -z $size $size assets/AppIcon.svg --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  sips -s format png -z $((size * 2)) $((size * 2)) assets/AppIcon.svg --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleExecutable</key><string>$NAME</string>
  <key>CFBundleIdentifier</key><string>dev.nerda.browser</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>$(date +%Y%m%d%H%M)</string>
  <key>LSMinimumSystemVersion</key><string>15.4</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <!-- Without these, macOS ends the app the moment a page (a video call) asks
       for the camera or microphone. -->
  <key>NSCameraUsageDescription</key><string>A website you open wants to use the camera.</string>
  <key>NSMicrophoneUsageDescription</key><string>A website you open wants to use the microphone.</string>
  <!-- A browser opens what it is given, http: too (t.co links often end on
       one); otherwise App Transport Security refuses it. The page's icon is
       fetched outside the page, so web content alone isn't enough. -->
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsArbitraryLoads</key><true/></dict>
</dict>
</plist>
PLIST

# Ad-hoc signature: enough to run on this Mac, not to hand to anyone else.
codesign --force --sign - "$APP"
echo "$APP"
