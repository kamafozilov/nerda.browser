#!/bin/bash
# Puts a pull request's screenshots on GitHub and prints the Markdown that
# shows them. They go to the `screenshots` branch, in a folder named after
# the branch in use, so the pull request can show them while main and every
# clone of it stay free of pictures. That branch is never merged.
#
#   ./screenshots.sh build/after.png                    a new feature
#   ./screenshots.sh build/before.png build/after.png   a fix or a change
#
# A file keeps its name, so name them before.png and after.png: that is what
# .github/pull_request_template.md expects. Sending one again replaces it.
# docs/pull-requests.md has the whole process.
set -euo pipefail
cd "$(dirname "$0")"

[ $# -gt 0 ] || { sed -n '7,8p' "$0" >&2; exit 1; }
BRANCH="$(git branch --show-current)"
[ -n "$BRANCH" ] || { echo "screenshots.sh: not on a branch" >&2; exit 1; }
# owner/repo of origin, from git@github.com:o/r.git or https://github.com/o/r
REPO="$(git remote get-url origin | sed -E 's#\.git$##; s#^.*github\.com[:/]##')"

# Built in a throwaway index, so the checkout's own index and files are
# never touched. Without the branch on origin yet, the first commit starts it.
export GIT_INDEX_FILE="$(mktemp -u)"
trap 'rm -f "$GIT_INDEX_FILE"' EXIT
if git fetch -q origin screenshots 2>/dev/null; then
  PARENT="-p FETCH_HEAD"
  git read-tree FETCH_HEAD
else
  PARENT=
  git read-tree --empty
fi
for f; do
  git update-index --add --cacheinfo "100644,$(git hash-object -w "$f"),$BRANCH/$(basename "$f")"
done
COMMIT="$(git commit-tree "$(git write-tree)" $PARENT -m "chore(screenshots): $BRANCH")"
git push -q origin "$COMMIT:refs/heads/screenshots"

URL="https://raw.githubusercontent.com/$REPO/screenshots/$BRANCH"
for f; do
  name="$(basename "$f")"
  echo "![${name%.*}]($URL/$name)"
done
