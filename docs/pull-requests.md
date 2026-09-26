# Pull requests

Every change reaches `main` through a pull request, and every pull request looks the same: whoever opens it, a person or their agent. The owner reviews them, so each one says what changed for the person using Nerda, shows it in pictures, and says what was tested.

## One change per pull request

One feature or one fix, which is usually one line in the changelog. Something else found on the way gets a pull request of its own. A small pull request is read in minutes; one that mixes three things waits.

## Title

Pull requests are merged with **Squash and merge**, so the title becomes the commit on `main` (`fix(tabs): end a rename with a click anywhere (#6)`). It follows [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/):

- `type(scope): description`, at most 72 characters, no full stop.
- **type**: `feat` (something new people can use), `fix` (something broken now works), `perf`, `refactor`, `build`, `docs`, `test`, `chore`, `style`, `ci`, `revert`. A `!` after the scope when something people rely on goes away.
- **scope**: the part of Nerda, one word or two joined by a hyphen, as the log has them: `sidebar`, `tabs`, `bookmarks`, `updates`, `developer-tools`, `window`, `release`.
- **description**: lowercase, imperative, what a person using Nerda gets rather than how: `offer updates in a sidebar card with download progress`, not `add UpdateCard view`.

## Commits

Each commit follows the same convention as the title. A body is optional: short bullets, or a paragraph on why when the diff doesn't say it. Squashing lists them under the title on `main`.

No AI attribution anywhere in Git or on GitHub: no `Co-Authored-By` trailer for a tool, no "Generated with …" line, in commits, pull requests, comments or reviews.

## Body

[`.github/pull_request_template.md`](../.github/pull_request_template.md) has the sections, in this order, each with a note on what goes in it:

1. **What changed**: one or two sentences for the person using Nerda. A fix says what went wrong and what happens now.
2. **Screenshots**: below.
3. **How it works**: short bullets a reviewer needs to read the diff: the approach, the main types or files, why this way. Not a file-by-file list.
4. **Testing**: only what was really run, with its result. What wasn't is written "Not run: …".
5. **Changelog**: the line added to `CHANGELOG.md` with its heading, or "None" and why. How to write it: [releasing.md](releasing.md#every-change-the-changelog).

## Screenshots

A change that shows on screen is best shown in the pull request; the pictures are what the owner looks at first. They are welcome, not required: a pull request without them passes the check all the same. When there are pictures, they cover each screen of a new feature and each place a fix touches.

- **Something new** (a feature, a new screen, a dialog): one picture of it.
- **Something that was already there and now looks or works differently** (a fix, a change): a before and an after, side by side. The same window size, the same place and the same state in both, so the change is the only difference.
- **Nothing on screen changes** (build, docs, refactor, speed): the section says "Nothing on screen changes."

A feature with several screens (a store page, a dialog, a menu, a settings page) shows each of them, in the order someone would meet them.

They are taken on this Mac in the background, never with the owner's pointer, keyboard or front window (see [AGENTS.md](../AGENTS.md)), into `build/screenshots/`, one file per picture, named for what it shows and numbered in the order to read them. A before and an after of one thing share the name:

```
build/screenshots/1-store-page.png
build/screenshots/2-install-question.png
build/screenshots/3-extensions-menu.before.png
build/screenshots/3-extensions-menu.after.png
```

The name becomes the caption above it ("Store page", "Extensions menu").

1. For something that changes, before touching the code: `./build.sh test`, open Nerda Test behind the window in use, bring it to the state that shows it with cua-driver, and picture its window (`get_window_state` with `screenshot_out_file`, see [AGENTS.md](../AGENTS.md)) into `build/screenshots/3-extensions-menu.before.png`. Forgot? `git worktree add /tmp/nerda-base main`, the same steps from there, then `git worktree remove /tmp/nerda-base`.
2. After the change: `./build.sh test` again, the same steps, each picture into `build/screenshots/`.
3. Crop each to the part that matters, with enough around it to see where it is: `sips -c HEIGHT WIDTH --cropOffset Y X build/screenshots/…`. Crop a before and its after alike.

Once in `build/screenshots/`, they reach the pull request on their own:

- **Pushing the branch** uploads them: `.githooks/pre-push` runs `./screenshots.sh` with everything in `build/screenshots/` before the branch goes, whoever pushes it: T3 Code's buttons, `gh pr create` or `git push`. It is on once per clone: `git config core.hooksPath .githooks`. What is uploaded is the whole set: a picture taken out of the folder goes from the pull request too.
- **The Screenshots check** (`.github/workflows/screenshots.yml`) runs on every pull request as it opens, is edited or gets new commits. It puts every uploaded picture into the Screenshots section, each under its caption, a before and an after side by side, whatever was written there, and passes one without any all the same. A picture dragged into the body on GitHub counts too.

`./screenshots.sh` keeps them on `refs/screenshots/<your branch>`, a ref that isn't a branch: GitHub lists no branch and offers no pull request for it, and `main` never carries pictures. They are shown by the address of their commit, so a picture sent again has a new address, and the check swaps it in; sending them unchanged does nothing. Run it by hand for pictures taken after the last push, then push again or edit the body, and the check puts them in. From a fork, it uses your fork.

## Opening it

Before opening, check:

- `swift test` passes.
- The changelog line is in the same commit as the change, if people would notice it.
- Every picture is in `build/screenshots/`, one for each thing the pull request changes on screen (or it has nothing on screen): the push uploads them.

**From T3 Code**, with its commit and pull request buttons: T3 Code writes commit messages and the pull request from this repository's `AGENTS.md`, its last 20 commit subjects and the template on `main`. Its settings, under Source Control, stay at *Source control writing style: Repository conventions* with *Follow change request templates* on. It sees only the diff, so read what it wrote and correct it with `gh pr edit` where it guessed (Testing above all).

**By hand, or by an agent**: `gh pr create --title "type(scope): description" --body-file body.md`, with the body in the template's sections, its `<!-- -->` notes left out.
