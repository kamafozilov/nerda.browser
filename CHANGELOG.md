# Changelog

Every change people using Nerda would notice, newest first. The format is
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html); how to write an
entry and how a release is made is in [docs/releasing.md](docs/releasing.md).

## [Unreleased]

### Added

- Tabs in a sidebar on the system's sidebar glass, newest first under New Tab. ⌘S collapses it, and it comes out over the page from the window's left edge. Drag its right edge to resize it (200–400 pt; double-click the edge to reset).
- Pinned tabs, shown as tiles above New Tab, three to a row. They never sleep, load at launch and stay open after ⌘W. Double-click a tile to go back to the address it was pinned at.
- Drag tabs and tiles to reorder them. Drop a tab on the tiles to pin it, or a tile on the list to unpin it.
- Command bar for new tabs (⌘T): type an address or a search. Suggestions come from your history and from Google.
- Address bar over the page, with back, forward, reload and stop. It shows the site in full and the rest of the address dimmer, and takes the colour of the page's top edge. Click it or press ⌘L to edit it in place.
- History: visited pages are kept for 90 days and suggested as you type. Typing the start of a site you visit often puts it first. The History menu lists recent pages and can clear them.
- Session restore: tabs come back after you quit, after a crash or after an update, with their history, scroll position and zoom.
- Sleeping tabs: a tab out of sight for 30 minutes, or any tab under memory pressure, frees its memory and wakes when shown. Tabs playing media or using the camera stay awake.
- Downloads go to ~/Downloads without overwriting files, with a progress ring and a list where you can cancel, show in Finder or clear.
- Find in page (⌘F, ⌘G, ⇧⌘G), page zoom (⌘+, ⌘−, ⌘0), ⌘1–⌘9 and ⌃Tab to switch tabs.
- Swipe back and forward with two fingers, as in Chrome: an arrow fills from the edge, and the trackpad ticks once it is far enough.
- Page video full screen inside the window, as in Chrome, and back to the same place in the page afterwards.
- Passwords: sign-ins that worked are offered for saving, and saved accounts are listed when a sign-in box is clicked. File › Import Passwords… reads the CSV exported by Passwords, Safari or Chrome. Passwords are kept in the login keychain.
- Asks before quitting (Return quits, Esc stays). Turn this off with "Always quit" or with Warn Before Quitting in the Nerda menu.
- Updates: Nerda checks for a new version on launch and every few hours, shows what's new, and installs it on request, then reopens with your tabs. Nerda › Check for Updates… checks now.
- Opens http: pages and asks before opening links meant for other apps (mailto: and the like). Pages can use the camera and microphone.
- Runs on macOS 15.4 or later, on Apple silicon and Intel Macs.
- App icon.

[Unreleased]: https://github.com/kamafozilov/nerda.browser/commits/main
