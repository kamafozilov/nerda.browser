#!/bin/bash
# Publishes a version of Nerda: what CHANGELOG.md has under [Unreleased]
# becomes that version's section, a v-tag marks the commit, and a GitHub
# Release carries Nerda.dmg (to install from) and Nerda.zip (what an
# installed Nerda updates itself from) and release.json (what it reads to
# find them), with the section as its notes. Both
# are signed with Developer ID, notarized by Apple and stapled, so they open
# on any Mac without a warning.
#
#   ./release.sh          the next patch after the latest tag: 0.0.1, 0.0.2, …
#   ./release.sh 1.0.0    a version of your choosing
#   NERDA_NOTARIZE=0 ./release.sh   signed but not notarized: Gatekeeper asks
#                         for System Settings › Privacy & Security › Open
#                         Anyway on the first install; updates are unaffected
#
# docs/releasing.md has the whole process.
set -euo pipefail
cd "$(dirname "$0")"

REPO="kamafozilov/nerda.browser"
# Every release is signed by one team: an installed Nerda takes an update
# only from the team that signed it (Updater.swift), so it never changes
# without a manual install for everyone. The team is NERDA_TEAM in
# release.env, a file of this Mac's kept out of Git.
[ -f release.env ] && . ./release.env
TEAM="${NERDA_TEAM:-}"
# Notarization credentials, kept in the keychain by
#   xcrun notarytool store-credentials nerda --apple-id <email> --team-id <team>
PROFILE="${NERDA_NOTARY_PROFILE:-nerda}"
NOTARIZE="${NERDA_NOTARIZE:-1}"
fail() { echo "release: $*" >&2; exit 1; }
[ -n "$TEAM" ] || fail "NERDA_TEAM isn't set: put NERDA_TEAM=<team id> in release.env"

LAST="$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null || true)"
if [ $# -ge 1 ]; then
  VERSION="${1#v}"
else
  IFS=. read -r MAJOR MINOR PATCH <<< "${LAST#v}"
  VERSION="${MAJOR:-0}.${MINOR:-0}.$(( ${PATCH:-0} + 1 ))"
fi
TAG="v$VERSION"

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "$VERSION is not major.minor.patch"
if [ -n "$LAST" ]; then
  [ "$VERSION" != "${LAST#v}" ] && [ "$(printf '%s\n' "${LAST#v}" "$VERSION" | sort -V | tail -1)" = "$VERSION" ] \
    || fail "$VERSION doesn't come after $LAST"
fi
command -v gh >/dev/null || fail "needs the GitHub CLI: brew install gh"
gh auth status >/dev/null 2>&1 || fail "not signed in to GitHub: gh auth login"
[ "$(git branch --show-current)" = main ] || fail "releases are made from main"
[ -z "$(git status --porcelain)" ] || fail "commit or stash your changes first"
git fetch --quiet --tags origin
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || fail "main and origin/main differ: push or pull first"
! git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || fail "$TAG exists already"
IDENTITY="$(security find-identity -v -p codesigning | grep -o "\"Developer ID Application: [^\"]*($TEAM)\"" | head -1 | tr -d '"' || true)"
[ -n "$IDENTITY" ] || fail "no Developer ID Application certificate for team $TEAM in the keychain"
[ "$NOTARIZE" = 0 ] || xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1 \
  || fail "no notarization credentials: xcrun notarytool store-credentials $PROFILE --apple-id <email> --team-id $TEAM"

# What's new: the [Unreleased] section, up to the next section or the links.
NOTES="$(awk '/^## \[Unreleased\]/ { on = 1; next } /^## \[/ || /^\[[^]]+\]: / { on = 0 } on' CHANGELOG.md | sed '/./,$!d')"
[ -n "${NOTES//[[:space:]]/}" ] || fail "CHANGELOG.md has nothing under [Unreleased]"

echo "Nerda $VERSION (after ${LAST:-nothing}):"
echo
echo "$NOTES"
echo
read -r -p "Build and publish $TAG? [y/N] " ANSWER
[ "$ANSWER" = y ] || [ "$ANSWER" = Y ] || fail "stopped"

NERDA_VERSION="$VERSION" NERDA_SIGN_IDENTITY="$IDENTITY" ./build.sh release
APP="build/Nerda.app"
codesign --verify --strict --deep "$APP" || fail "$APP's signature doesn't hold"
SIGNED="$(codesign -dvv "$APP" 2>&1)"
grep -q "^TeamIdentifier=$TEAM$" <<< "$SIGNED" || fail "$APP isn't signed by team $TEAM"
grep -q "flags=.*runtime" <<< "$SIGNED" || fail "$APP isn't signed with the hardened runtime"

# Sends a file to Apple and waits for the verdict; the log says why when it
# isn't Accepted. Apple answers in minutes or leaves it In Progress for days,
# so after 30 minutes it stops, before anything is committed or published.
notarize() {
  [ "$NOTARIZE" = 0 ] && { echo "not notarized: $1"; return; }
  local result id status
  result="$(xcrun notarytool submit "$1" --keychain-profile "$PROFILE" --wait --timeout 30m --output-format json)" || true
  id="$(plutil -extract id raw - <<< "$result" 2>/dev/null || true)"
  status="$(plutil -extract status raw - <<< "$result" 2>/dev/null || true)"
  if [ "$status" != Accepted ]; then
    [ -n "$id" ] && { xcrun notarytool log "$id" --keychain-profile "$PROFILE" >&2 || true; }
    fail "Apple didn't notarize $1: ${status:-no answer}; NERDA_NOTARIZE=0 ./release.sh publishes without it"
  fi
  echo "notarized: $1 ($id)"
}

ZIP="build/Nerda.zip"
DMG="build/Nerda.dmg"
rm -f "$ZIP" "$DMG"
# The disk image: the app beside a shortcut to Applications, to drag it onto.
# Only it goes to Apple, one wait instead of two: its ticket covers the app
# inside by the app's cdhash, so the same ticket is stapled to the app, and
# the ZIP the updater fetches is made from the stapled app. The copy inside
# the image has no ticket of its own, so its first launch asks Apple online.
STAGE="$(mktemp -d)"
ditto "$APP" "$STAGE/Nerda.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Nerda $VERSION" -srcfolder "$STAGE" -ov -format UDZO -quiet "$DMG"
rm -rf "$STAGE"
codesign --timestamp --sign "$IDENTITY" "$DMG"
notarize "$DMG"
if [ "$NOTARIZE" != 0 ]; then
  xcrun stapler staple -q "$DMG"
  xcrun stapler staple -q "$APP"
  # What a Mac that downloaded them checks: both tickets, and Gatekeeper's verdict.
  xcrun stapler validate -q "$APP" && xcrun stapler validate -q "$DMG" || fail "a ticket isn't stapled"
  spctl --assess --type execute "$APP" || fail "Gatekeeper refuses $APP"
  spctl --assess --type open --context context:primary-signature "$DMG" || fail "Gatekeeper refuses $DMG"
fi
ditto -c -k --keepParent "$APP" "$ZIP"
printf '%s\n' "$NOTES" > build/notes.md

# The section gets its version and date under a new, empty [Unreleased], and
# the links at the bottom compare each version with the one before.
URL="https://github.com/$REPO"
SINCE="${LAST:-}"
awk -v v="$VERSION" -v d="$(date +%Y-%m-%d)" -v url="$URL" -v last="$SINCE" '
  /^## \[Unreleased\]/ { print; print ""; print "## [" v "] - " d; next }
  /^\[Unreleased\]: / {
    print "[Unreleased]: " url "/compare/v" v "...HEAD"
    if (last == "") print "[" v "]: " url "/releases/tag/v" v
    else print "[" v "]: " url "/compare/" last "...v" v
    next
  }
  { print }
' CHANGELOG.md > build/CHANGELOG.md
mv build/CHANGELOG.md CHANGELOG.md

git add CHANGELOG.md
git commit --quiet -m "chore(release): $TAG"
git tag -a "$TAG" -m "Nerda $VERSION"
git push --quiet origin main "$TAG"

# What installed copies read to find the release (Updater.swift): GitHub's
# API shape, served as one of the release's files.
SHA="$(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
FEED="build/release.json"
plutil -create xml1 "$FEED"
plutil -insert tag_name -string "$TAG" "$FEED"
plutil -insert body -string "$NOTES" "$FEED"
plutil -insert html_url -string "$URL/releases/tag/$TAG" "$FEED"
plutil -insert assets -json "[{\"name\":\"Nerda.zip\",\"browser_download_url\":\"$URL/releases/download/$TAG/Nerda.zip\",\"digest\":\"sha256:$SHA\"}]" "$FEED"
plutil -convert json "$FEED"

# Not a pre-release, even below 1.0.0: the updater reads the latest release,
# and GitHub leaves pre-releases out of it.
gh release create "$TAG" "$DMG" "$ZIP" "$FEED" --repo "$REPO" --title "Nerda $VERSION" \
  --notes-file build/notes.md --latest \
  || fail "$TAG is pushed but the release isn't made; again with: gh release create $TAG $DMG $ZIP $FEED --repo $REPO --title 'Nerda $VERSION' --notes-file build/notes.md --latest"
echo "released: $URL/releases/tag/$TAG"
