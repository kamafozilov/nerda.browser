#!/bin/bash
# Wraps the SwiftPM binary into an app bundle — just a folder with a plist
# and the binary in the right place.
#
#   ./build.sh          release build: build/Nerda.app, the Nerda people use
#   ./build.sh debug    debug build: build/Nerda Dev.app, a separate app with
#                       its own bundle id, data and keychain item (Edition.swift)
#
# The version is NERDA_VERSION (release.sh sets it), else the latest v* tag.
# NERDA_SIGN_IDENTITY names the certificate to sign with (release.sh sets
# Developer ID); otherwise the first Apple Development one, otherwise ad-hoc.
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"
if [ "$CONFIG" = release ]; then
  NAME="Nerda"
  ID="dev.nerda.browser"
else
  NAME="Nerda Dev"
  ID="dev.nerda.browser.debug"
fi
APP="build/$NAME.app"
TAG="$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null || true)"
VERSION="${NERDA_VERSION:-${TAG#v}}"
VERSION="${VERSION:-0.0.0}"

# A release runs on Apple silicon and Intel Macs alike; a debug build is
# built for this Mac only, which is quicker.
ARCHS=()
[ "$CONFIG" = release ] && ARCHS=(--arch arm64 --arch x86_64)
swift build -c "$CONFIG" ${ARCHS[@]+"${ARCHS[@]}"}
BINARY="$(swift build -c "$CONFIG" ${ARCHS[@]+"${ARCHS[@]}"} --show-bin-path)/Nerda"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
# SwiftPM links reproducibly, which records the deployment target as the SDK
# the app was built with. macOS reads that SDK to decide which look to give
# the app, and for 15.4 it keeps the old one: smaller traffic lights, tighter
# window corners. Stamp the SDK it was really built with.
vtool -set-build-version macos 15.4 "$(xcrun --show-sdk-version)" -replace \
  -output "$APP/Contents/MacOS/$NAME" "$BINARY"

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
  <key>CFBundleIdentifier</key><string>$ID</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$(date +%Y%m%d%H%M)</string>
  <key>NSHumanReadableCopyright</key><string>© 2026 Kamron Fozilov</string>
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

# Signed with an Apple Development certificate when this Mac has one (Xcode ›
# Settings › Accounts, any Apple ID, free): the keychain then knows every
# build as the same app, by its team, and hands over saved passwords without
# asking. Otherwise ad-hoc, which is enough to run on this Mac, but each build
# is a new app to the keychain, and the first one to need the passwords asks
# once for the login password. The updater needs the team too: it only puts
# in a build signed by the same team as the one running.
IDENTITY="${NERDA_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | grep -o '"Apple Development: [^"]*"' | head -1 | tr -d '"' || true)}"
if [ "$CONFIG" = release ] && [ -n "$IDENTITY" ]; then
  # The hardened runtime notarization insists on, a timestamp so the
  # signature outlives the certificate, and the one thing pages need that the
  # runtime would refuse otherwise: Nerda.entitlements.
  codesign --force --options runtime --timestamp --entitlements Nerda.entitlements --sign "$IDENTITY" "$APP"
else
  codesign --force --timestamp=none --sign "${IDENTITY:--}" "$APP"
fi
echo "$APP"
