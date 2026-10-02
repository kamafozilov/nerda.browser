#!/bin/bash
# Reads a crash report Nerda wrote as an issue (Feedback.swift) with the names
# of the functions in Nerda it was in, from the Nerda.dSYM.zip of that
# version's release (release.sh). Other binaries' lines stay as they are.
#
#   ./symbolicate.sh 42    the issue's number
set -euo pipefail
cd "$(dirname "$0")"

BODY="$(gh issue view "$1" --json body -q .body)"
VERSION="$(grep -oE '^Nerda [0-9]+\.[0-9]+\.[0-9]+ \(build' <<< "$BODY" | head -1 | cut -d' ' -f2)"
ARCH="$(grep -oE '· (arm64|x86_64)' <<< "$BODY" | head -1 | cut -d' ' -f2)"  # arm64e runs arm64 code
UUID="$(grep -oE '^Nerda binary [0-9A-F-]+' <<< "$BODY" | cut -d' ' -f3)"
[ -n "$VERSION" ] && [ -n "$ARCH" ] || { echo "symbolicate: issue $1 has no crash report of Nerda's" >&2; exit 1; }

DIR="$(mktemp -d)"
gh release download "v$VERSION" --pattern Nerda.dSYM.zip --dir "$DIR"
ditto -x -k "$DIR/Nerda.dSYM.zip" "$DIR"
DSYM="$DIR/Nerda.dSYM"
dwarfdump --uuid --arch "$ARCH" "$DSYM" | grep -q "$UUID" \
  || echo "symbolicate: the crash was in another build of $VERSION than the release's; names may be wrong" >&2

# "3   Nerda   0x1a2b3c": a place in Nerda's code, which starts at 0x100000000.
while IFS= read -r line; do
  if [[ "$line" =~ ^([0-9]+\ +)Nerda\ +0x([0-9a-f]+)$ ]]; then
    echo "${BASH_REMATCH[1]}Nerda  $(atos -o "$DSYM" -arch "$ARCH" -l 0x100000000 "$(printf '0x%x' $((0x100000000 + 0x${BASH_REMATCH[2]})))")"
  else
    echo "$line"
  fi
done <<< "$BODY"
