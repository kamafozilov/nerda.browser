# Technical decisions

Reference: [driceroland/Search](https://github.com/driceroland/Search) (MIT). We follow the same path.

## Adopted

| # | Layer | Decision | Why |
|---|---|---|---|
| 1 | Platform | macOS only | I use macOS myself; on Windows/Linux, Chrome extensions only fully work with Chromium, which goes against the "lightweight" goal |
| 2 | Engine | WebKit (`WKWebView`) | Ships with the system: the app is a few MB, without Chromium's 300 MB |
| 3 | Language | Swift | The only natural choice for Apple APIs |
| 4 | UI | SwiftUI, plus AppKit where needed | Search does it this way and it works |
| 5 | Project | SwiftPM (`Package.swift`) + `build.sh` assembles the `.app` bundle | Plain text files only; Xcode not required (Command Line Tools are enough) |
| 6 | Minimum OS | macOS 15.4 | `WKWebExtensionController` exists from this version on (checked in a build) |
| 7 | Chrome extensions | `WKWebExtension` + installing `.crx` from the Chrome Web Store | That is where the main users come from |
| 8 | Ad blocking | `WKContentRuleList` | Runs in WebKit's network layer, no JS cost |
| 9 | RAM | Put unused tabs to sleep (the web view is destroyed, a snapshot stays); sooner under memory pressure. Pinned tabs never sleep and load right away at launch | 100–300 MB per tab is the main cost |
| 10 | Storage | JSON files, in one folder | No server, no account |
| 11 | Passwords | Nerda's own store: the passwords are one item in the login keychain (`Nerda Passwords`), the site and user names they go with are `accounts.json` beside the history; those in Passwords/Safari come in once from a CSV via File › Import Passwords… | Safari's passwords sit behind an Apple entitlement; macOS (AMFI launch constraint) won't start the iCloud Passwords helper from Nerda. The keychain asks again after every build without a Team ID: as one item, and with the names outside it, that is one question, and only once a password is picked or saved, never for listing accounts |
| 12 | External dependencies | None, Apple frameworks only | |
| 13 | Codebase | Written from scratch; needed parts (e.g. `Crx.swift`, `ExtensionShims.swift`) are taken from Search, with the MIT license text | The structure should be our own |
| 14 | Tools | Xcode (Instruments, debugger), `swift format` (in the toolchain) | Command Line Tools are enough to build |
| 15 | Entry point | AppKit (`NSApplication`, `main.swift`); SwiftUI views through `NSHostingView` | Full control over windows; a SwiftUI `App` always requires some Scene |
| 16 | Concurrency | Swift 6, default isolation `MainActor` | AppKit and WebKit are on the main thread anyway; background work is marked explicitly |
| 17 | Versions | SemVer tags `vX.Y.Z`; 0.0.x, one patch step per release, until the public launch as 1.0.0; `CHANGELOG.md` in Keep a Changelog form | See [releasing.md](releasing.md) |
| 18 | Dev and release | Nerda Dev (debug) is a separate app: its own bundle id, data folder and keychain item (`Edition.swift`, `build.sh`) | Working on Nerda must not touch the data of the Nerda in use |
| 19 | Updates | Our own updater (`Updater.swift`, after Search's): GitHub Releases carry the DMG and a ZIP; a newer ZIP is checked by SHA-256, bundle id, version and signing team, then swapped in | No framework (#12): Sparkle would add a framework, an EdDSA key and a copy step to build.sh, for what about 300 lines do |
| 20 | Signing | Releases: Developer ID Application, one fixed team (`NERDA_TEAM` in the untracked `release.env`), hardened runtime, notarized and stapled, universal (arm64 + x86_64). Development: the Apple Development certificate, as before | Opens on any Mac without warnings; the team is fixed because the updater only accepts its own |

## Known limitations

- Extensions at Safari's level: `webRequest` doesn't work in MV3; some (e.g. Vimium C) don't open.
- DRM: FairPlay only (Netflix etc. as in Safari).
- Full screen: inside the window, as in Chrome (WebKit's own moves the page into a separate window and can't be turned off). A site's own `:fullscreen` CSS rules don't apply; the button of a plain `<video controls>` still opens WebKit's separate window. WebKit SPI (`_setWindowOcclusionDetectionEnabled:`) keeps video playing during the full-screen animation; should it go away, video only pauses for a moment during the animation again.
- Address bar colour: taken from WebKit's own sample of the page's top edge (SPI `_sampledPageTopColor`, as Safari's); should it go away, the bar falls back to the page's `theme-color`, which some sites (GitHub, YouTube) set to a colour their top doesn't use.
- Passwords: only in the page's own frame (not in sign-ins inside another site's iframe). No passkeys (they need Apple's browser entitlement and a Developer ID). Without an Apple Development certificate (Team ID), macOS asks for the login password once after each new build, the first time a password is picked or saved; `build.sh` uses the certificate by itself when there is one.
