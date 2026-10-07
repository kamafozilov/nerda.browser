#!/bin/bash
# Wraps the SwiftPM binary into an app bundle — just a folder with a plist
# and the binary in the right place.
#
#   ./build.sh          release build: build/Nerda.app, the Nerda people use
#   ./build.sh debug    debug build: build/Nerda Dev.app, a separate app with
#                       its own bundle id, data and keychain item (Edition.swift)
#   ./build.sh test     build/Nerda Test.app, for agents trying things on
#                       screen: Nerda Dev's build with data of its own
#   ./build.sh bench    build/Nerda Bench.app, for bench.sh: a development build
#                       with data of its own, optimized as a release is
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
elif [ "$CONFIG" = test ]; then
  NAME="Nerda Test"
  ID="dev.nerda.browser.test"
  CONFIG=debug
elif [ "$CONFIG" = bench ]; then
  NAME="Nerda Bench"
  ID="dev.nerda.browser.bench"
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
FLAGS=(-c "$CONFIG")
[ "$CONFIG" = release ] && FLAGS+=(--arch arm64 --arch x86_64)
# Timed as people get it, with the development build's Bench.swift in.
[ "$CONFIG" = bench ] && FLAGS=(-c release -Xswiftc -DDEBUG)
swift build "${FLAGS[@]}"
BINARY="$(swift build "${FLAGS[@]}" --show-bin-path)/Nerda"

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
# doesn't), iconutil packs the sizes. Development builds wear
# AppIconDev.svg, so Nerda Dev isn't taken for Nerda in the Dock.
ICON=assets/AppIconDev.svg
[ "$CONFIG" = release ] && ICON=assets/AppIcon.svg
ICON_WORK="$(mktemp -d)"
ICONSET="$ICON_WORK/AppIcon.iconset"
mkdir -p "$ICONSET" "$APP/Contents/Resources"
# Menus use 16/32-point icons: the Dock's outer spacing makes those too
# small. Tighten their viewBox, keeping the whole tile and its shadow.
sed 's/viewBox="0 0 1024 1024"/viewBox="80 80 864 864"/' "$ICON" > "$ICON_WORK/AppIconSmall.svg"
for size in 16 32 128 256 512; do
  SOURCE_ICON="$ICON"
  [ "$size" -le 32 ] && SOURCE_ICON="$ICON_WORK/AppIconSmall.svg"
  sips -s format png -z $size $size "$SOURCE_ICON" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  sips -s format png -z $((size * 2)) $((size * 2)) "$SOURCE_ICON" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICON_WORK"

# A display name, not a new app: the bundle path, data and updater keep
# their existing names. macOS uses the localised name while the bundle's
# filename still matches CFBundleDisplayName in Info.plist.
DISPLAY_NAME="$NAME"
[ "$CONFIG" = release ] && DISPLAY_NAME="Nerda Browser"
mkdir -p "$APP/Contents/Resources/en.lproj"
cat > "$APP/Contents/Resources/en.lproj/InfoPlist.strings" <<STRINGS
"CFBundleName" = "$DISPLAY_NAME";
"CFBundleDisplayName" = "$DISPLAY_NAME";
STRINGS

# The pictures behind a new tab's field (Backdrop.swift, assets/backgrounds/CREDITS.md).
mkdir -p "$APP/Contents/Resources/Backgrounds"
cp assets/backgrounds/*.heic "$APP/Contents/Resources/Backgrounds/"

# Every version's notes, for What's New and Settings › Release Notes
# (ReleaseNotes in UpdateCard.swift). release.sh builds before it gives
# [Unreleased] its version and date, so the release gets them here.
if [ -n "${NERDA_VERSION:-}" ]; then
  sed "s/^## \[Unreleased\]\$/## [$VERSION] - $(date +%Y-%m-%d)/" CHANGELOG.md > "$APP/Contents/Resources/CHANGELOG.md"
else
  cp CHANGELOG.md "$APP/Contents/Resources/"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>$NAME</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>LSHasLocalizedDisplayName</key><true/>
  <key>CFBundleExecutable</key><string>$NAME</string>
  <key>CFBundleIdentifier</key><string>$ID</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$(date +%Y%m%d%H%M)</string>
  <key>NSHumanReadableCopyright</key><string>© 2026 Kamron Fozilov</string>
  <key>LSMinimumSystemVersion</key><string>15.4</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <!-- Web links alone make an app a URL handler. A browser also opens
       HTML documents, which macOS uses when offering browser candidates. -->
  <key>CFBundleDocumentTypes</key><array>
    <dict>
      <key>CFBundleTypeName</key><string>HTML document</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Default</string>
      <key>LSItemContentTypes</key><array><string>public.html</string><string>public.xhtml</string></array>
    </dict>
    <dict>
      <key>CFBundleTypeName</key><string>PDF document</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key><array><string>com.adobe.pdf</string></array>
    </dict>
  </array>
  <key>CFBundleURLTypes</key><array><dict>
    <key>CFBundleURLName</key><string>Web addresses</string>
    <key>CFBundleTypeRole</key><string>Viewer</string>
    <key>CFBundleURLSchemes</key><array><string>http</string><string>https</string></array>
  </dict></array>
  <!-- Without these, macOS ends the app the moment a page (a video call) asks
       for the camera or microphone. -->
  <key>NSCameraUsageDescription</key><string>A website you open wants to use the camera.</string>
  <key>NSMicrophoneUsageDescription</key><string>A website you open wants to use the microphone.</string>
  <key>NSLocationUsageDescription</key><string>A website you open wants to use your location.</string>
  <key>NSLocationWhenInUseUsageDescription</key><string>A website you open wants to use your location.</string>
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
ENTITLEMENTS=Nerda.entitlements
# Native passkeys need Apple's managed browser capability, independently of
# notarization. Only an approved profile can turn them on.
if [ -n "${NERDA_PASSKEYS_PROFILE:-}" ]; then
  [ -n "$IDENTITY" ] || { echo "Passkeys require a signing identity" >&2; exit 1; }
  PASSKEYS_WORK="$(mktemp -d)"
  trap 'rm -rf "$PASSKEYS_WORK"' EXIT
  security cms -D -i "$NERDA_PASSKEYS_PROFILE" > "$PASSKEYS_WORK/profile.plist"
  /usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.developer.web-browser.public-key-credential' "$PASSKEYS_WORK/profile.plist" | grep -qx true \
    || { echo "The profile does not authorize browser passkeys" >&2; exit 1; }
  PROFILE_ID="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.application-identifier' "$PASSKEYS_WORK/profile.plist")"
  PROFILE_TEAM="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.developer.team-identifier' "$PASSKEYS_WORK/profile.plist")"
  case "$PROFILE_ID" in
    "$PROFILE_TEAM.$ID"|"$PROFILE_TEAM.*") ;;
    *) echo "The passkey profile does not match $ID" >&2; exit 1 ;;
  esac
  # Nerda's own entitlements and what the profile grants, not the profile's
  # whole list: that is what it allows, wildcards included, not what to sign.
  cp Nerda.entitlements "$PASSKEYS_WORK/entitlements.plist"
  /usr/libexec/PlistBuddy -c "Add :com.apple.application-identifier string $PROFILE_TEAM.$ID" \
    -c "Add :com.apple.developer.team-identifier string $PROFILE_TEAM" \
    -c "Add :com.apple.developer.web-browser.public-key-credential bool true" "$PASSKEYS_WORK/entitlements.plist"
  cp "$NERDA_PASSKEYS_PROFILE" "$APP/Contents/embedded.provisionprofile"
  ENTITLEMENTS="$PASSKEYS_WORK/entitlements.plist"
fi
if [ "$CONFIG" = release ] && [ -n "$IDENTITY" ]; then
  # The hardened runtime notarization insists on, a timestamp so the
  # signature outlives the certificate, and the one thing pages need that the
  # runtime would refuse otherwise: Nerda.entitlements.
  codesign --force --options runtime --timestamp --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$APP"
else
  if [ -n "${NERDA_PASSKEYS_PROFILE:-}" ]; then
    codesign --force --timestamp=none --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$APP"
  else
    codesign --force --timestamp=none --sign "${IDENTITY:--}" "$APP"
  fi
fi
echo "$APP"
