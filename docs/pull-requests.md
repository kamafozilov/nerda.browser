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

A change that shows on screen shows in the pull request; the pictures are what the owner looks at first.

- **A new feature**: one picture, `after.png`.
- **A fix, or a change to something that was already there**: two, `before.png` and `after.png`, side by side. The same window size, the same place and the same state in both, so the change is the only difference.
- **Nothing on screen changes** (build, docs, refactor, speed): the section says "Nothing on screen changes."

They are taken in the test VM, never on the owner's Mac (see [AGENTS.md](../AGENTS.md)):

1. For a fix or a change, before touching the code: `./vm.sh open`, bring Nerda to the state that shows the problem, `./vm.sh shot build/before.png`. Forgot? `git worktree add /tmp/nerda-base main`, the same steps from there, then `git worktree remove /tmp/nerda-base`.
2. After the change: `./vm.sh open`, the same steps, `./vm.sh shot build/after.png`.
3. Crop both to the part that changed, with enough around it to see where it is: `sips -c HEIGHT WIDTH --cropOffset Y X build/after.png`. Two views of one change (a dialog and a settings page) go side by side in one `after.png`.
4. `./vm.sh done`.

The change isn't finished until they are in `build/`; from there, they reach the pull request on their own:

- **Pushing the branch** uploads them: `.githooks/pre-push` runs `./screenshots.sh build/before.png build/after.png` (whichever are there) before the branch goes, whoever pushes it: T3 Code's buttons, `gh pr create` or `git push`. It is on once per clone: `git config core.hooksPath .githooks`.
- **The Screenshots check** (`.github/workflows/screenshots.yml`) runs on every pull request as it opens, is edited or gets new commits. It puts the uploaded pictures into the Screenshots section, whatever was written there, and fails a pull request that has none and doesn't say "Nothing on screen changes." A picture dragged into the body on GitHub counts too.

`./screenshots.sh` keeps them on the `screenshots` branch, in a folder named after your branch, so `main` never carries pictures; that branch is never merged. Sending a file again replaces it, though GitHub may show the old one for a few minutes; sending it unchanged does nothing. Run it by hand for pictures taken after the last push, then push again or edit the body, and the check puts them in. From a fork, it uses your fork.

## Opening it

Before opening, check:

- `swift test` passes.
- The changelog line is in the same commit as the change, if people would notice it.
- The screenshots are in `build/` (or the change has nothing on screen): the push uploads them.

**From T3 Code**, with its commit and pull request buttons: T3 Code writes commit messages and the pull request from this repository's `AGENTS.md`, its last 20 commit subjects and the template on `main`. Its settings, under Source Control, stay at *Source control writing style: Repository conventions* with *Follow change request templates* on. It sees only the diff, so read what it wrote and correct it with `gh pr edit` where it guessed (Testing above all).

**By hand, or by an agent**: `gh pr create --title "type(scope): description" --body-file body.md`, with the body in the template's sections, its `<!-- -->` notes left out.
