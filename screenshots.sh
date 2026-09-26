#!/bin/bash
# Puts a pull request's screenshots on GitHub and prints the Markdown that
# shows them. They go to refs/screenshots/<branch in use>, a ref that isn't a
# branch: GitHub lists no branch and offers no pull request for it, and main
# and every clone of it stay free of pictures. They are shown by the commit's
# address, which never changes, so a picture sent again gets a new address.
#
#   ./screenshots.sh              every picture in build/screenshots/
#   ./screenshots.sh FILE...      these pictures
#
# What is sent is the pull request's whole set: a picture left out of it is
# taken off. Each is named for what it shows, numbered in the order to read
# them, a before and an after of one thing by the same name:
#
#   build/screenshots/1-store-page.png
#   build/screenshots/2-extensions-menu.before.png
#   build/screenshots/2-extensions-menu.after.png
#
# docs/pull-requests.md has the whole process.
set -euo pipefail
cd "$(dirname "$0")"

if [ $# -eq 0 ]; then
  shopt -s nullglob
  set -- build/screenshots/*.png
  [ $# -gt 0 ] || { echo "screenshots.sh: no pictures in build/screenshots/" >&2; exit 1; }
fi
BRANCH="$(git branch --show-current)"
[ -n "$BRANCH" ] || { echo "screenshots.sh: not on a branch" >&2; exit 1; }
# owner/repo of origin, from git@github.com:o/r.git or https://github.com/o/r
REPO="$(git remote get-url origin | sed -E 's#\.git$##; s#^.*github\.com[:/]##')"

REF="refs/screenshots/$BRANCH"

# Built in a throwaway index from these pictures alone, so the checkout's own
# index and files are never touched. The last upload, if there was one, is
# the parent, and only its tree is compared.
export GIT_INDEX_FILE="$(mktemp -u)"
trap 'rm -f "$GIT_INDEX_FILE"' EXIT
PARENT=
git fetch -q origin "$REF" 2>/dev/null && PARENT="-p FETCH_HEAD"
git read-tree --empty
for f; do
  git update-index --add --cacheinfo "100644,$(git hash-object -w "$f"),$(basename "$f")"
done
TREE="$(git write-tree)"
# Sent again unchanged (every push, from the pre-push hook): nothing to commit.
if [ -z "$PARENT" ] || [ "$TREE" != "$(git rev-parse FETCH_HEAD^{tree})" ]; then
  COMMIT="$(git commit-tree "$TREE" $PARENT -m "chore(screenshots): $BRANCH")"
  git push -q --no-verify origin "$COMMIT:$REF"
else
  COMMIT="$(git rev-parse FETCH_HEAD)"
fi

URL="https://raw.githubusercontent.com/$REPO/$COMMIT"
for f; do
  name="$(basename "$f")"
  echo "![${name%.*}]($URL/$name)"
done
