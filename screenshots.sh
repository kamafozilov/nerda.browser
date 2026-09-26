#!/bin/bash
# Puts a pull request's screenshots on GitHub and prints the Markdown that
# shows them. They go to refs/screenshots/<branch in use>, a ref that isn't a
# branch: GitHub lists no branch and offers no pull request for it, and main
# and every clone of it stay free of pictures. They are shown by the commit's
# address, which never changes, so a picture sent again gets a new address.
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

REF="refs/screenshots/$BRANCH"

# Built in a throwaway index, so the checkout's own index and files are
# never touched. Without the ref on origin yet, the first commit starts it.
export GIT_INDEX_FILE="$(mktemp -u)"
trap 'rm -f "$GIT_INDEX_FILE"' EXIT
if git fetch -q origin "$REF" 2>/dev/null; then
  PARENT="-p FETCH_HEAD"
  git read-tree FETCH_HEAD
else
  PARENT=
  git read-tree --empty
fi
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
