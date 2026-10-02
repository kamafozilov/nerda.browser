# Changelog

Every change people using Nerda would notice, newest first. The format is
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html); how to write an
entry and how a release is made is in [docs/releasing.md](docs/releasing.md).

## [Unreleased]

### Added

- File › Print… (⌘P) prints the page, and Export as PDF… saves it in pages, as it would print. A site's own Print button works too, and a page that closes itself once printed, as a ticket or a receipt does, is printed first.
- A tab making sound shows a small speaker on its site's icon, in the sidebar and across the top. Point at the icon and click to mute the tab, and again to bring its sound back; a pinned site has the speaker in its corner, so a click in the middle still opens it. Mute Tab is in the tab's right-click menu and in View too, and a muted tab's video doesn't float in Picture in Picture.
- Share the page on screen with AirDrop, Messages, Mail, Notes and the rest, from File › Share or a tab's right-click menu.
- More search engines in Settings › General: Kagi, Ecosia, Startpage and Perplexity, or one of your own. Custom… asks for its address, with %s where the search goes.

## [0.0.20] - 2026-10-01

### Added

- Settings has three new pages. Tabs: how soon a tab you've left gives its memory back, from 15 minutes to 4 hours or never, and whether tabs show a preview when the pointer rests on them. Passwords: open your saved passwords, import them, turn off offering to save or fill them, and take sites off the Never list. Site Settings: whether sites may ask for your camera, microphone, location and notifications at all, and every site you've allowed or blocked, to change or reset.
- Settings › General: turn off search suggestions so nothing you type leaves your Mac until Return, choose where downloads go or have Nerda ask each time, import and export bookmarks, and turn off checking for updates automatically.
- Settings › Appearance: pick the new tab picture, and hide the AI chats button in the sidebar.
- Settings › Security & Privacy: choose how long history is kept, from a day to a year, and how soon incognito windows lock when Nerda is in the background.
- Keyboard Shortcuts lists Bookmark This Tab, Hide Others and the Developer keys.

### Changed

- Load pinned tabs at launch moved from Settings › General to Settings › Tabs.

## [0.0.19] - 2026-10-01

### Added

- A page zoomed in or out (⌘+, ⌘−) shows its zoom, such as 125%, at the top of the sidebar. Click it to go back to actual size.

### Changed

- The update card at the bottom of the sidebar fills from left to right as the update downloads, without a percentage. Nerda no longer restarts on its own once it's in: the card turns into Restart to update, so nothing you're doing is cut short. Quitting Nerda finishes the update too.

## [0.0.18] - 2026-10-01

### Fixed

- A video or sound in a tab opened behind (⌘-click) waits until you go to that tab, instead of starting unseen.

## [0.0.17] - 2026-09-30

### Added

- Sites can send you notifications. When a site asks, Nerda asks you under Site Settings, beside the address: Allow shows its notifications as the Mac's own, and clicking one takes you to its tab; Block stops it asking. Change your mind in Site Settings › Notifications. Incognito windows never ask.

### Changed

- Site Settings is laid out as Nerda's other menus: each permission has its icon and a small Ask, Allow or Block menu, Reload to Apply shows only after an ad-blocking change, and a note says when macOS itself keeps the camera, microphone, location or notifications from Nerda.
- A site asking for your camera, microphone or location asks in the same way as notifications, and your answer is kept for the site, where WebKit asked each time.

### Fixed

- Sign-in pages that check for passkeys before showing, such as Stencil's, load instead of stopping at "Something went wrong".

## [0.0.16] - 2026-09-30

### Changed

- Nerda has a new icon: two cream blocks that form an N, on a black tile.

## [0.0.15] - 2026-09-30

### Added

- Reopen Closed Tab (⇧⌘T) brings back the last 25 closed tabs with their history, zoom and names, including after restarting Nerda. Pick an older one in History › Recently Closed; incognito tabs are never kept.
- Site settings, beside the address, lets you allow ads for one site, choose Ask, Allow or Block for its camera, microphone and location, and clear its data. Reload to apply an ad-blocking change.
- Downloads can be paused and resumed. An interrupted download offers Resume when the server supports it, or Retry for a download that can safely start again.
- File › Export Bookmarks… saves your bookmarks and folders as an HTML file other browsers can import.

### Changed

- Pages you edit stay awake, including forms inside frames, so an automatic sleep cannot throw away your work. Closing or leaving an edited page asks first, and quitting or restarting for an update warns about unsaved work and unfinished downloads.

### Fixed

- Saved passwords fill sign-in forms inside frames, using the frame's own site and filling only that frame.
- Closing Find on Page no longer leaves the last match highlighted.

## [0.0.14] - 2026-09-30

### Changed

- Extensions are paused by default for speed and reliability. Turn on Enable extensions in Settings › Extensions and restart Nerda to use them; installed extensions and their settings are kept.
- Pinned sites sit four to a row at the top of the sidebar, where they sat three, so more fit before the tabs.

### Fixed

- Switching tabs stays quick with hundreds of tabs in the sidebar, where it slowed with each one, and closing a tab releases its page straight away, even while its menu or preview still holds the tab.
- Slow disk reads of site icons no longer hold up the window opening; icons appear when their reads finish.
- An extension waiting on an app that has already quit hears that it has gone, where it could wait forever. Loaded extensions' background connections survive another tab closing or sleeping.

## [0.0.13] - 2026-09-28

### Fixed

- Extensions that talk to an app on your Mac or keep a live connection, as password managers do, leave nothing running behind them when they restart, update or are turned off, where each restart kept its helper's memory and connection until Nerda quit. A burst of messages between an extension's pages is handled once, where some were handled twice, and an extension's popup left open or just closed stays quiet, where it kept waking Nerda several times a second.
- A block list that can't be fetched, as one added by an address that has gone, is tried again after a few hours, where Nerda fetched and compiled every list again every half hour, taking a few seconds of CPU and hundreds of megabytes each time. Lists found unchanged no longer reload the rules in every open tab.
- A local page that throws errors in a loop no longer redraws the address bar at every frame, and a site without an icon is no longer asked for one at every page you open.
- Typing in History's search stays smooth with months of history, where each key went through every page at once.

## [0.0.12] - 2026-09-28

### Fixed

- Opening an item in a password manager's popup, as NordPass's, leaves it quick and still, where NordPass fetched the item again and again without end: its popup and pages slowed to a crawl and its process took more CPU and memory by the second.
- Copy in a password manager's popup or page, as NordPass's, puts the password on the clipboard, and the extension can clear it later as its settings say, where copying did nothing. The first copy asks once whether it may read the clipboard, and the popup stays open while you answer.

## [0.0.11] - 2026-09-28

### Added

- Passwords, in the sidebar's menu, in Window, or with ⌥⌘L: every saved password by site, behind Touch ID or your Mac's password, to search, see, copy, change, remove, or add by hand. A copied password stays on this Mac, out of clipboard managers, and leaves the clipboard after a minute and a half.
- Window › Task Manager: every tab, extension and part of Nerda with the memory and CPU it takes, and whether a tab is on screen, asleep or playing sound. Double-click a tab to go to it; End Process closes the tabs you chose.

### Changed

- The saved accounts under a sign-in box list the one you used last first, whether you picked it there or typed its password in, where the newest saved came first.

### Fixed

- Extensions that sign you in or ask for a site's access from their button, as Figma's does, work: the question is asked where the extension got an error, and a sign-in the extension watches for in its own tab finishes, where the tab stayed on "Can't Open This Page".
- Extensions that keep a line open to their background, as password managers do, go on answering after a moment unused, and their button opens at the first click, where after two minutes their pages and the icons they add to sign-in fields stopped doing anything.
- Extensions whose pages wait on their background hear it, as in Chrome: Bitwarden signs in and syncs, 1Password's popup gets past "Connecting to the app", and user scripts in ScriptCat and Tampermonkey can fetch from other sites, where each of these stayed stuck.
- Sites that try a passkey first, which Nerda can't use, ask for your password straight away, where they left you stuck on the passkey. A password manager extension that keeps your passkeys still answers them.
- A site that takes more than a minute to answer opens once it answers, where Nerda gave up after a minute and left the page blank.
- A secure (https) site can send you to an extension's page that the extension lets it open, as a sign-in done on the extension maker's site does, where the page failed to load.
- An extension whose update, reload or install fails keeps the copy that worked, running and with its settings, where it was left removed. Turning an extension off or removing it also closes its hidden page and lets the Mac sleep again if it was keeping it awake.
- Passbolt's popup shows your passwords and Claude's extension starts, as in Chrome, where the popup stayed empty and Claude's did nothing. A side panel that names its tab in its address opens, where it failed to load.
- A second click on an extension's button closes its popup, where it could open it again at once. A popup whose page sets its own width takes that width while open, narrower too, as Bitwarden's narrow setting asks.
- An extension's popup that Nerda opens again after restarting the extension stands under its button, where it stood at the bottom right of the window with its arrow pointing at nothing.
- An app on your Mac that set itself up for Vivaldi or Opera, as a password manager's desktop app does, answers its extension in Nerda too, where only apps set up for Chrome, Edge, Brave, Arc or Chromium did.
- Tab managers such as OneTab, Session Buddy and Tab Session Manager see every tab's address, title and icon, as in Chrome, and hear when a tab's address or title changes, where tabs on sites they couldn't also run on showed no icon and their changes came blank. Private tabs and other extensions' pages stay hidden from them.

### Security

- Extensions can do no more than Chrome lets them: they can't send a tab to a javascript: or file: address, open a private window as a normal one, or see into another extension's pages. Opening a download needs its own permission, only just after you used the extension and only for a file it downloaded itself; search, notifications, idle, power and speech need theirs; and only an extension that asks can talk to apps on your Mac.
- The list of saved accounts under a sign-in box takes a click only once it has been in place half a second, so a page can't put it under your pointer as you click and have a password filled in.
- Add to Nerda on a Chrome Web Store page installs only the extension that page is about, and only on the store over https.

## [0.0.10] - 2026-09-26

### Added

- Settings › General › Load pinned tabs at launch. Turned off, Nerda opens on a new tab, and a pinned tab loads only when you open it.

### Changed

- Nerda takes less memory with pinned tabs and heavy sites. At launch the tab on screen loads first and pinned tabs follow one at a time. A tab out of sight for 10 minutes that takes more than 500 MB, as x.com, Gmail or a 3D site can, sleeps, pinned or not, and loads again when you open it. When the Mac runs out of memory, pinned tabs sleep too.
- A pinned site that is asleep shows its icon in grey, and in colour again once you open it and it loads.

## [0.0.9] - 2026-09-26

### Changed

- A long history no longer slows Nerda down: switching to another app doesn't stall while it is saved, the window comes up without waiting for it to be read, and History (⌘Y), its search and the address bar's suggestions keep up as you type, where with thousands of pages they paused.
- Responsive Design Mode: the device, its size and Rotate sit in the middle of the bar, over the page. Pull the page's right or bottom edge, or the corner between, to make it any size. The size fields select all of themselves when clicked, step by 1 with ↑ and ↓ (10 with Shift), and put back the old number with Escape. A hairline shows where a dark page ends.
- Developer Mode no longer frames the page in amber and black tape. A local page is still marked by its amber port in the address bar, and in the sidebar's list of tabs by its amber edge.
- Pages load with less delay and memory when a Chrome extension works on them, as Dark Reader or a password manager does: each page, and each frame in it, now takes in a small part of what Nerda adds to the extension instead of all of it.

### Fixed

- Closing a tab or putting one to sleep frees its memory. Before, a closed tab kept its page running out of sight: after an evening of browsing, gigabytes of memory and a busy processor, until Nerda quit.
- The sidebar stays quick with thousands of imported bookmarks. Before, each switch of tab, or a page loading, could hold it up for a quarter of a second.
- Delete browsing data, with Browsing history ticked, also deletes the icons Nerda kept of the sites it takes out of your history. Before, they stayed on this Mac, a list of the sites you had visited.
- Blocking ads and trackers works after a first launch without internet, where before nothing was blocked for four days. Nerda tries the lists again about every half hour until it has them.

## [0.0.8] - 2026-09-26

### Added

- Developer Mode: a page from a server on your own Mac (localhost, 127.0.0.1) comes framed in amber and black tape, its tab edged in amber, and its address shown whole with the port picked out. Buttons for the console, with the page's JavaScript errors counted on it, Inspect Element, Hard Reload and Responsive Design Mode sit at the right of the address bar.
- A folder with open tabs in it shows a minus that closes them all, and Close Tabs in Folder in its menu. The bookmarks stay.
- A button at the end of the line under the bookmarks makes a new folder, where before it took a right-click.

### Changed

- An open bookmark shows its close button all the time, not only under the pointer, so you can see at a glance which ones are open.
- What's New, after Nerda updates itself, is clear glass like the rest of Nerda instead of a near-black card, and wider and taller, so more of the notes read at a glance. Short notes no longer float in empty space.

### Fixed

- A tab dragged along the tabs across the top stays among them: it stops at the last tab and at the pinned sites, instead of sliding over the traffic lights, the downloads button or off the window.
- Local projects open as typed: 127.0.0.1:5173, [::1]:3000, a network address like 192.168.1.1, and any address with a port go to http://, where before most ended on a TLS error.
- An address with 0.0.0.0 in it, as many local servers print, opens the server on this Mac instead of failing.

## [0.0.7] - 2026-09-26

### Added

- Chrome extensions: open one's page in the Chrome Web Store and press Add to Nerda, or paste its link in Settings › Extensions. The puzzle button at the right of the address bar opens their popups and pins the ones you use beside it. They update themselves and stay out of incognito windows, as in Chrome.

### Changed

- What's New, after Nerda updates itself, stays a compact card however tall the window is: the first notes show at a glance and the rest scroll, where before it stretched over most of a tall window.

### Fixed

- Downloads, AI chats and the menu read clearly over a light page. Before, they turned grey over a white site and their text faded into it, most of all with the tabs across the top.

## [0.0.6] - 2026-09-26

### Added

- Settings › Release Notes lists what every version of Nerda brought, newest first, with the day it came out; Release notes under About Nerda in General opens it too.
- AI chats, one click away: the sparkles button beside Downloads at the bottom of the sidebar shows ChatGPT, Claude, Gemini, Grok, Perplexity and DeepSeek. Pick one to go to its tab, or open it in a new one. Add your own with +, or right-click one to remove it.

### Changed

- A new version no longer pops up in the middle of the window: a card at the bottom of the sidebar shows it with its number. Click it and the update downloads right there, with a bar filling from 0 to 100%, then Nerda opens again as the new version and shows what's new in it.
- What's New shows everything since the version you had, each version under its number and date, when you skipped a few updates. Where it only showed the latest one.

### Fixed

- Greyed-out items in the sidebar's menu, such as Developer on a new tab, are readable again: dimmed as in a system menu rather than faded almost out of sight.
- Renaming a tab or bookmark ends with a click anywhere: another tab, the sidebar's empty space or a button, where before only a click on the page did. The new name is kept, and a click on the address bar leaves the keyboard there instead of taking it back to the page.

## [0.0.5] - 2026-09-25

### Added

- Developer tools: Inspect Element when you right-click a page, and a Developer submenu in the sidebar's menu and in View, with Developer Tools (⌥⌘I), JavaScript Console (⌥⌘J) and Inspect Element (⌥⌘C), as in Chrome.
- Responsive Design Mode (⌥⌘R, in Developer): the page at a size you type, starting at the size it has, or at a phone's, tablet's or computer's, told it is that device's browser so sites send their mobile pages. Turn it on its side; a screen too large for the window is scaled down to fit.
- View Page Source (⌥⌘U): the HTML a site sent, in a tab of its own, numbered by line and coloured, with its links going to their own sources. `view-source:` addresses open too.
- Disable JavaScript, in Developer, for the tab you're in, and Clear Site Data, which removes that site's cookies, storage and cache and nothing else.
- JSON pages, an API's answers, open as a coloured tree to fold and unfold, with Raw to see them as sent and Copy.

### Fixed

- Selecting text lights only the text you picked, as in Chrome: a word, a line or a drag over several paragraphs. Before, a band of selection colour ran out to the window's edges and filled the space between paragraphs.
- The window fills the screen again when the Dock hides or shows, or the display changes, where it left a gap at the bottom.

## [0.0.4] - 2026-09-25

### Fixed

- Nerda › Check for Updates… finds new versions again where it said "Couldn't check for updates" because too many people share your internet address.

## [0.0.3] - 2026-09-25

### Added

- Bookmarks, under the pinned sites in the sidebar: drag a tab there, or press ⌘D, to keep it. As in Arc, a bookmark opens in its own place and stays when you close it, ready to open again at the page you kept. A thin line parts them from the tabs, as in Arc and Zen: drag a tab above it to keep it. Put them in folders, and folders in folders (right-click › New Folder), drag them into another order, or down below the line to make one a tab again. They are in the Bookmarks menu too, and File › Import Bookmarks… brings them in from the file Chrome, Safari, Firefox or Arc exports.
- Auto Picture-in-Picture can float the video when you switch to another app too: tick Also when switching to another app under it in Settings › General. Back in Nerda, the video goes back into its page.
- Type the path of a file on your Mac in the address bar (`/Users/you/Movies/clip.mp4` or `~/Movies/clip.mp4`) to open it, as in Chrome.

### Changed

- Nerda's icon is simpler: the N on its own, without the orbit around it.
- Warn before quitting has moved from the Nerda menu to Settings › General, where every setting now has its icon beside it.

### Fixed

- Auto Picture-in-Picture works: a video playing with sound (YouTube and the rest) now floats over everything when you leave its tab, and goes back into the page when you return. WebKit had picture in picture turned off for every video, the player's own button included.
- A Settings page short enough to fit no longer slides about under a trackpad swipe; the filter lists and dropdowns in Settings stay still the same way.
- The Downloads button at the foot of the sidebar is now the same size as the menu button beside it.
- The arrow keys set the volume and seek again on YouTube after you switch to theater mode. Before, they scrolled the page, because the player lost the keyboard when it moved into its theater frame.
- A tab's hover card now shows up whole, with its picture and memory in place, where they used to fade in after it; moving on to the next tab changes the card at once.

## [0.0.2] - 2026-09-25

### Added

- Rest the pointer on a tab, in the sidebar or across the top, for a card with its title, its site and how much memory its page takes. Tabs other than the one on screen show a picture of their page; a sleeping tab shows the page as it went to sleep, and says it is sleeping.
- A Keyboard Shortcuts page in Settings lists every key Nerda answers to, by tabs, page and window, each with a line on what it does.
- A Security & Privacy page in Settings. Delete browsing history asks how far back to go (the last 15 minutes up to all time) and what to delete: the pages you visited, cached images and files, download history, cookies or site storage. Only what is safe to lose comes ticked, so you stay signed in unless you tick cookies yourself. History › Clear History… and the history page open the same choices. View browsing history opens the history page.
- Block ads and trackers has moved to Security & Privacy. Manage filters › Configure picks the lists Nerda blocks with from uBlock Origin's catalogue (uBlock filters, AdGuard, malware and phishing lists, cookie notices, regional lists and more), found by name, or adds a list of your own by its address. EasyList and EasyPrivacy stay on until you choose otherwise; lists are kept on your Mac, so turning one on fetches only that one.

### Changed

- ⌘W on a pinned tab now closes its page and gives its memory back, keeping its tile: click the tile to open it again, where you left it. Pinned sites still load on their own when Nerda opens.
- A page scrolled to its top or bottom now stays put, as in Chrome, where it used to stretch on past its edge over a black ground.

## [0.0.1] - 2026-09-25

### Added

- Make Nerda your default browser from the card at the top of Settings. Links from other apps open in the regular window, and the card shows when Nerda is already the default.
- About Nerda in Settings shows the current version and update status, with a Check for updates button and links to WebKit and the source code.
- Tabs in a sidebar on the system's sidebar glass, newest first under New Tab. ⌘S collapses it, and the page slides along with it as it goes and comes. Collapsed, it comes out over the page from the window's left edge. Drag its right edge to resize it (200–400 pt; double-click the edge to reset).
- Pinned tabs, shown as tiles above New Tab, three to a row. They never sleep, load at launch and stay open after ⌘W. Double-click a tile to go back to the address it was pinned at.
- A tab or tile is selected the moment it is pressed, as in other browsers, and tabs come back with their icons already there; a pinned site's icon stays on its tile while it loads. Drag tabs and tiles to reorder them. Drop a tab on the tiles to pin it, or a tile on the list to unpin it.
- Double-click a tab in the sidebar to give it a name of your own; clear the name to go back to the page's title.
- New tabs (⌘T, or New Tab in the sidebar) open with a search field in the middle of the page: type an address or a search. Suggestions come from your history and from your search engine. Closing a tab takes you back to the tab you were on before it, wherever it is in the list, as Vivaldi does; ⌘W on a pinned tab, to the last tab you were on below the tiles. Closing the last tab closes the window, as in other browsers; ⌘T or the Dock icon brings it back.
- A new tab shows a photo of Mount Fuji softly behind its search field, blurring into the window toward the bottom. The button at the bottom of the page opens a strip of Nerda's pictures to pick one to keep, take a new one each day, or add pictures of your own (also in View), kept sharp on screens up to 6K. Point at one of yours and click its × to remove it.
- The page and its address bar sit on the window's glass as one card with a fine edge. New tabs and Settings show the glass through the card, lightly tinted; Settings a little more.
- Search Tabs (⌘⇧A) comes up over the dimmed window, clear of any page, dark or light. It lists your open tabs, the last one you saw first, so Return goes back to it. Type to filter them by title or site, or to open an address or a search in a new tab.
- Address bar over the page, with back, forward, reload and stop. It shows the site in full and the rest of the address dimmer, and takes the colour of the page's top edge. Click it or press ⌘L to edit it in place; before anything is typed, it lists the sites you went to last, latest first. The copy button after reload copies the page's link.
- Incognito windows (⇧⌘N, in File and in the sidebar's menu): dark and plain, with the incognito mark in the sidebar's corner and on each new tab. Pages visited there stay out of your history and aren't suggested from it, the tabs aren't saved, and cookies and site data are kept in memory, shared by every incognito window, and gone once the last one closes. Settings and history open in the regular window. Closing its last tab closes it, and leaves incognito. Its tabs and menu wear a muted violet. Right-click a link and pick Open Link in Incognito Window to open it there. Incognito windows lock when the Mac locks or sleeps, or after Nerda has been in the background for a minute, and open again with Touch ID or your Mac's password.
- Hard Reload Page (⌘⇧R, in View) loads the page again from the site, not from the cache.
- History: visited pages are kept for 90 days and suggested as you type. Typing the start of a site you visit often puts it first. The History menu lists recent pages and can clear them. Show All History (⌘Y, also in the sidebar's menu) opens every page visited in a tab of its own, by day, to search, open or remove one by one.
- Session restore: tabs come back after you quit, after a crash or after an update, with their history, scroll position and zoom, and the Settings tab on the page it was left on. Nerda opens on the tab you left, or on a new tab if that is where you were.
- Sleeping tabs: a tab out of sight for 30 minutes, or any tab under memory pressure, frees its memory and wakes when shown. Tabs playing media or using the camera stay awake. A tab out of sight that keeps the processor busy for minutes (an ad gone wrong) is put to sleep, sparing the battery.
- Sites start connecting while you type their address, or when the pointer rests on a sleeping tab or on a link to another site, so they open sooner.
- Ads and trackers are blocked using EasyList and EasyPrivacy, updated every few days. The ad blocker allows page navigation and known sign-in checks. Turn off Block ads and trackers in Settings and reload if a site has trouble.
- Pages move at the screen's own rate: their animations run at up to 120 frames a second on a ProMotion screen, like a MacBook Pro's, instead of about 60, as in Chrome. In Low Power Mode they keep to 60, sparing the battery.
- Downloads go to ~/Downloads without overwriting files. A download that starts flies from the pointer into the button in the sidebar's bottom-right corner, which shows a progress ring and opens a list where you can cancel, show in Finder or clear.
- Settings open in a tab of their own, from ⌘,, Nerda › Settings… or the menu in the sidebar's bottom-left corner. General holds the search engine, Picture-in-Picture, screenshots, languages and spell check.
- Settings › Appearance: the theme (System, Light or Dark), the zoom pages open at, which Actual Size (⌘0) goes back to, where the tabs go, and whether the window's glass is tinted or transparent.
- Tabs across the top of the window (Settings › Appearance › Tab style › Horizontal), in place of the sidebar: pinned sites as icons beside the traffic lights, then the tabs, sharing the width, the one on screen running into its address bar. New tabs open at the end, by the + button. Drag a tab to move it, onto the pinned sites to pin it, or a pinned site among the tabs to unpin it; double-click a tab to rename it. Downloads and the menu sit at the far end.
- Right-click a tab, in the sidebar or across the top, to open a new tab, reload it, pin or unpin it, switch the tabs between the side and the top, collapse the sidebar, or close it, the other tabs, or the tabs below it (to its right across the top). Right-click beside the tabs for a new tab and where the tabs go.
- Drag the top of the window, off its tabs and buttons, to move it; double-click it to fill the screen and back, or whatever System Settings › Desktop & Dock says a title bar does.
- Search engine: Google, Bing, DuckDuckGo, Brave or Yandex, picked in Settings › General, for what you type in the address bar or a new tab and for the suggestions as you type.
- Auto Picture-in-Picture (Settings › General, off at first): a video playing with sound floats over your windows when you switch to another tab, and goes back into its page when you come back.
- Copy Screenshot and Save Screenshot… in a page's right-click menu capture what the page shows. Turn them off in Settings › General.
- Spell check as you type in pages, on at first. Turn it off in Settings › General.
- Preferred languages (Settings › General › Configure): the languages sites are asked for, in order; drag to reorder, add or remove. Sites get the first one after Nerda restarts.
- The menu in the sidebar's bottom-left corner lists recent history beside it, and opens Settings or a new tab.
- Find in page (⌘F, ⌘G, ⇧⌘G), page zoom (⌘+, ⌘−, ⌘0), ⌘1–⌘9 and ⌃Tab to switch tabs.
- Keys a page doesn't use pass quietly, without the system's beep. ⌘T, ⌘W, ⌘L, ⌘1–⌘9 and ⌃Tab always reach Nerda, whatever the page does with them. A new tab or Settings takes the keyboard from the page behind it, so keys never reach a tab out of sight.
- Swipe back and forward with two fingers, as in Chrome: an arrow fills from the edge, the trackpad taps firmly once letting go will go there and lightly when drawn back short of it, and a quick flick goes too. Three-finger swipes, a mouse's back and forward buttons, and Logitech mice set up in Logi Options+ go back and forward as well.
- Page video full screen inside the window, as in Chrome, and back to the same place in the page afterwards.
- Passwords: sign-ins that worked are offered for saving, and saved accounts are listed when a sign-in box is clicked. File › Import Passwords… reads the CSV exported by Passwords, Safari or Chrome. Passwords are kept in the login keychain.
- Asks before quitting (Return quits, Esc stays). Turn this off with "Always quit" or with Warn Before Quitting in the Nerda menu.
- Updates: Nerda checks for a new version on launch and every few hours, shows what's new, and installs it on request, then reopens with your tabs. Nerda › Check for Updates… checks now.
- Opens http: pages and asks before opening links meant for other apps (mailto: and the like). Pages can use the camera and microphone. A server on your Mac itself (localhost) opens over https with a certificate of its own, as in Chrome.
- A page opens a new tab or window only from a click or a key, as in Safari: it can't open tabs on its own, as it loads or on a timer, and take you away to them.
- ⌘-click or middle-click a link to open it in a tab of its own, behind the one you're on.
- Runs on macOS 15.4 or later, on Apple silicon and Intel Macs.
- App icon.

### Fixed

- Site icons on tabs, in the sidebar and across the top, show on their own, without a white square behind them; dark ones (GitHub's) take the text's colour.
- A site opened in a new tab, or a tab waking from sleep, no longer flashes white while the site answers; the tab stays dark in dark mode until the page arrives.

[Unreleased]: https://github.com/kamafozilov/nerda.browser/compare/v0.0.20...HEAD
[0.0.20]: https://github.com/kamafozilov/nerda.browser/compare/v0.0.19...v0.0.20
[0.0.19]: https://github.com/kamafozilov/nerda.browser/compare/v0.0.18...v0.0.19
[0.0.18]: https://github.com/kamafozilov/nerda.browser/compare/v0.0.17...v0.0.18
[0.0.17]: https://github.com/kamafozilov/nerda.browser/compare/v0.0.16...v0.0.17
[0.0.16]: https://github.com/kamafozilov/nerda.browser/compare/v0.0.15...v0.0.16
[0.0.15]: https://github.com/kamafozilov/nerda.browser/compare/v0.0.14...v0.0.15
[0.0.14]: https://github.com/kamafozilov/nerda.browser/compare/v0.0.13...v0.0.14
[0.0.13]: https://github.com/kamafozilov/nerda.browser/compare/v0.0.12...v0.0.13
[0.0.12]: https://github.com/kamafozilov/nerda.browser/compare/v0.0.11...v0.0.12
[0.0.11]: https://github.com/kamafozilov/nerda.browser/compare/v0.0.10...v0.0.11
[0.0.10]: https://github.com/kamafozilov/nerda.browser/compare/v0.0.9...v0.0.10
[0.0.9]: https://github.com/kamafozilov/nerda.browser/compare/v0.0.8...v0.0.9
[0.0.8]: https://github.com/kamafozilov/nerda.browser/compare/v0.0.7...v0.0.8
[0.0.7]: https://github.com/kamafozilov/nerda.browser/compare/v0.0.6...v0.0.7
[0.0.6]: https://github.com/kamafozilov/nerda.browser/compare/v0.0.5...v0.0.6
[0.0.5]: https://github.com/kamafozilov/nerda.browser/compare/v0.0.4...v0.0.5
[0.0.4]: https://github.com/kamafozilov/nerda.browser/compare/v0.0.3...v0.0.4
[0.0.3]: https://github.com/kamafozilov/nerda.browser/compare/v0.0.2...v0.0.3
[0.0.2]: https://github.com/kamafozilov/nerda.browser/compare/v0.0.1...v0.0.2
[0.0.1]: https://github.com/kamafozilov/nerda.browser/releases/tag/v0.0.1
