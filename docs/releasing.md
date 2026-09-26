# Releasing

## Versions

[Semantic Versioning](https://semver.org), tagged `vMAJOR.MINOR.PATCH`.

- **Until the public launch, versions are 0.0.x**: 0.0.1, 0.0.2, 0.0.3 and so on, one patch step per release, whatever it contains. `./release.sh` with no argument takes the next one.
- **1.0.0 is the public launch.** The owner decides when Nerda is ready for it and announces it. Only then does `./release.sh 1.0.0` happen.
- From 1.0.0 on: MAJOR when something people rely on goes away or changes incompatibly, MINOR for new features, PATCH for fixes only.

## Two apps: Nerda Dev and Nerda

| | Nerda Dev | Nerda |
|---|---|---|
| Made by | `./watch.sh`, `./build.sh debug` | `./release.sh` (`./build.sh` for a local try) |
| Bundle id | `dev.nerda.browser.debug` | `dev.nerda.browser` |
| Data | `~/Library/Application Support/Nerda Dev` | `~/Library/Application Support/Nerda` |
| Keychain item | `Nerda Dev Passwords` | `Nerda Passwords` |
| Updates itself | Never | From GitHub Releases |

They run side by side, and working on Nerda Dev never touches the tabs, history or passwords of the Nerda you use. The split is in `Sources/Nerda/Edition.swift` and `build.sh`.

## Every change: the changelog

A change people would notice gets its line in `CHANGELOG.md` under `## [Unreleased]`, in the same commit as the change. The release notes are made from these lines; nothing is written at release time. They are read in two places: the GitHub Release, and What's New, which Nerda shows once after it updates itself.

### Which heading

Use one of these headings, in this order, and add only the ones that have entries:

- `### Added`: new features.
- `### Changed`: changes in existing behaviour.
- `### Deprecated`: features that will be removed later.
- `### Removed`: features removed now.
- `### Fixed`: bug fixes.
- `### Security`: fixes for vulnerabilities.

A commit's type points to the heading (`feat` to Added or Changed, `fix` to Fixed), but the reader decides: something that works differently now is Changed even when it came as a `feat`.

### What gets a line

- A change people would notice, one line each. A pull request usually adds one.
- Not refactors, build scripts, docs or tests.
- Not a fix to something that hasn't been released yet: for the reader it simply works. If it changes what the thing does, edit its line under `[Unreleased]` instead.

### In what order

Within a heading, the change people will notice most comes first: a new feature before a new setting, a fix to something everyone uses before one to a corner of Settings. A new line goes where it belongs in that order, not always at the end.

### How to write a line

- A dash, then the thing as the person sees it, first: its name on screen, "Bookmarks, …", "Renaming a tab …", "Nerda › Check for Updates… …". Then what they can do with it now, or what now works.
- Written to the person using Nerda, as "you", in the present tense: "Pick one to go to its tab", not "Users can now pick…" or "Added the ability to…".
- **Added**: what it is, where it is, and how to use it.
- **Changed**: what it does now, and what it did before when that helps.
- **Fixed**: the problem that is gone, as the person saw it, then what happens now: "The window fills the screen again when the Dock hides or shows, where it left a gap at the bottom."
- Names exactly as on screen: menus and settings as a path with › ("Settings › General", "File › Import Bookmarks…"), buttons and items by their label, shortcuts in brackets with their symbols (⌘ ⌥ ⇧ ⌃): "View Page Source (⌥⌘U)".
- No code: no type, file or function names, and no "we". Other browsers by name when they make it clearer: "as in Chrome", "as in Arc".
- Short: one to three sentences. The most important thing in the first one, as What's New may be read no further.
- British spelling, as the rest of Nerda: colour, behaviour, licence.
- Only inline Markdown: `**bold**` sparingly, `` `code` `` for something typed (an address, a path), links. What's New shows nothing else, so no nested lists, pictures or headings of your own.

| Instead of | Write |
|---|---|
| Added UpdateCard to the sidebar | A new version shows as a card at the bottom of the sidebar, with its number. |
| Fixed bug in rename field focus handling | Renaming a tab ends with a click anywhere, where before only a click on the page did. |
| Improved developer tools | Developer tools: Inspect Element when you right-click a page, and Developer Tools (⌥⌘I) in View › Developer. |

### Before a release

`git log v0.0.1..HEAD --oneline` (from the latest tag) lists what is new since a release: each `feat` and `fix` there either has its line, or is left out for one of the reasons above. Then read `[Unreleased]` from top to bottom as someone who has never seen the code.

## Making a release

Needs, once on the Mac that releases:

- The GitHub CLI, signed in: `brew install gh`, `gh auth login`.
- A **Developer ID Application** certificate with its private key in the login keychain, plus Apple's Developer ID G2 intermediate certificate. The key was made on this Mac, so moving to another Mac means exporting the identity as a `.p12`.
- `release.env` beside `release.sh`, kept out of Git: `NERDA_TEAM=<team id>`, the team of that certificate.
- Notarization credentials in the keychain under the name `nerda`: `xcrun notarytool store-credentials nerda --apple-id <email> --team-id <team id>`, with an app-specific password from account.apple.com.

Every release is signed by that one team. An installed Nerda only takes an update from the team that signed it, so changing the team means everyone installs that one version from the disk image by hand. `release.sh` refuses to publish anything signed by any other certificate.

1. Try what's on `main` in Nerda Dev, and check that `## [Unreleased]` says everything a user would notice.
2. Push `main`, then run `./release.sh`. It shows the version and the notes and asks before doing anything. Then it:
   - builds `build/Nerda.app` with that version for Apple silicon and Intel, signed with Developer ID, the hardened runtime and `Nerda.entitlements` (camera and microphone for pages);
   - puts the app in `build/Nerda.dmg` (to install from), signs the disk image, has Apple notarize it (only the disk image: Apple left every ZIP submission In Progress) and staples the ticket to the disk image and to the app;
   - packs the stapled app as `build/Nerda.zip` (for the updater);
   - checks both tickets and Gatekeeper's verdict on both, and stops before anything is committed if one fails;
   - turns `[Unreleased]` into `[0.0.x] - date` under a new, empty `[Unreleased]`, and updates the compare links at the bottom;
   - commits `chore(release): v0.0.x`, tags `v0.0.x`, pushes both;
   - creates the GitHub Release with both files, `release.json` for the updater, and the section as its notes, marked Latest (never as a pre-release: the updater reads only the latest release).
3. Installed copies see it within six hours or at their next launch. Nerda › Check for Updates… sees it at once.

If the release step fails after the push, the script prints the `gh release create` command that finishes it.

`NERDA_NOTARIZE=0 ./release.sh` publishes a release signed with Developer ID but not notarized, for while Apple's notary service leaves submissions In Progress. Updates install as usual (the updater checks the signature, not the ticket), but a first install from the disk image is refused until System Settings › Privacy & Security › Open Anyway.

## Installing the first time

Download `Nerda.dmg` from the [latest release](https://github.com/kamafozilov/nerda.browser/releases/latest), open it and drag Nerda onto Applications. From then on, Nerda updates itself.

Nerda is signed with Developer ID and notarized, so it opens like any app from the internet: macOS asks once whether to open something downloaded, and that's all. It runs on macOS 15.4 or later, on Apple silicon and on Intel (the Intel half was run under Rosetta, not yet on an Intel Mac).

The first release build asks once for the login keychain password when it reaches the saved passwords, if they were saved by an earlier build signed by another team (Nerda Dev, or a local `./build.sh`). "Always Allow" settles it for every later release.

## How an update is installed

`Sources/Nerda/Updater.swift` reads `release.json` from the latest release (`https://github.com/kamafozilov/nerda.browser/releases/latest/download/release.json`), which `release.sh` writes in the shape of GitHub's API: tag, notes, page, and `Nerda.zip` with its SHA-256. Not the API itself, which answers only 60 requests an hour to an address without a GitHub account, and a provider's shared address runs out of them. When its tag is newer than the running version, a card at the bottom of the sidebar shows it (in Settings › About Nerda too). A click on it then:

1. downloads `Nerda.zip` and checks it against the SHA-256 that GitHub lists (a release without one isn't taken);
2. checks that the new app has the same bundle id, a newer version, and a valid signature, everything inside it included, from a Developer ID Application certificate Apple gave the same team;
3. moves the old app to `Nerda.app.old`, moves the new one into place, and reopens Nerda, which restores its tabs and shows the release notes once, as What's New.

Only the app bundle is replaced; the data folder, settings and keychain stay as they are. If Nerda can't replace itself (for example when it runs from the disk image instead of Applications), it says why and opens the release page.

To try the updater without publishing, serve a JSON file shaped like GitHub's release (`tag_name`, `body`, `html_url`, `assets[].name`, `assets[].browser_download_url`, and `assets[].digest` as `sha256:` and the zip's `shasum -a 256`) next to a newer `Nerda.zip` signed with the Developer ID, and open a release build with `open --env NERDA_UPDATES=http://127.0.0.1:8000/release.json build/Nerda.app`. Plain http is taken only from this Mac.
