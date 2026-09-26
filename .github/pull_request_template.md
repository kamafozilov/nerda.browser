<!--
Title: the Conventional Commit that lands on main when this is squashed,
`type(scope): description`: lowercase, imperative, no full stop, at most 72
characters, and describing what a person using Nerda gets, e.g.
`fix(tabs): end a rename with a click anywhere`.
The whole guide is docs/pull-requests.md.
-->

## What changed

<!--
One or two sentences for the person using Nerda, not about the code.
A feature: what they can now do, and where (menu › item, shortcut).
A fix: what went wrong before, and what happens now.
-->

## Screenshots

<!--
Every change this makes on screen, in pictures from the test VM (./vm.sh):
each screen of something new, and a before and an after of each thing that
looks or works differently. Leave them in build/screenshots/, named for what
they show and numbered in reading order (1-store-page.png,
2-extensions-menu.before.png, 2-extensions-menu.after.png): pushing the branch
uploads them, and the Screenshots check puts them here, each under its
caption, before and after side by side.

Nothing on screen changes (build, docs, refactor, perf): write
"Nothing on screen changes." instead.
-->

## How it works

<!--
Short bullets a reviewer needs to read the diff: the approach, the main
types or files, and why this way over the obvious one. Not a file-by-file
list. Mention anything left for later.
-->

## Testing

<!--
Only what was really done, with its result:
- `swift test`: 83 tests pass
- In the VM: the steps tried, and what happened
- `./bench.sh` before and after, when speed or memory could change
Anything not run is written as "Not run: …". Never claim a check that
didn't happen.
-->

## Changelog

<!--
The line this adds under [Unreleased] in CHANGELOG.md, with its heading,
e.g. "Fixed: Renaming a tab ends with a click anywhere …", or
"None: <why>" (refactor, build, docs, tests, or a fix to something not
released yet).
-->
