#!/bin/bash
# The lab run on the real sites (Tests/NerdaLab): builds Nerda Test, opens
# it behind the windows in use with its pages at a volume nobody hears,
# visits YouTube, X, Twitch, Instagram and the media test bed's own file
# and stream signed out, does each action to their videos, and writes what
# it found to build/lab/lab-<time>.json, with a summary beside it.
#
#   ./lab.sh                  every site
#   ./lab.sh --only YouTube   the sites whose name has that word
#   ./lab.sh --no-build       Nerda Test as built already
#
# One run at a time: a second stops at once. Needs Screen Recording for
# the app it runs from to record sound; without it, sound is "not measured".
set -euo pipefail
cd "$(dirname "$0")"
swift build --product NerdaLab
exec "$(swift build --show-bin-path)/NerdaLab" "$@"
