# Browser performance audit — 29 September 2026

The audit follows window launch, tab creation and switching, close and sleep,
page scripts, persistence, background activities and the extension lifecycle.
All 45 Swift source files were included in the source and hotspot review.
Runtime evidence comes from the existing isolated benchmark and regression
tests. Source review alone does not establish a runtime bottleneck.

## Changes and evidence

| Finding | Evidence | Change |
|---|---|---|
| A closed tab could keep its WebKit page, observations and page process while a preview or UI action retained the tab | `aRetainedClosedTabLetsItsPageGo` failed before the change: the closed tab still had a page | The shared close path stops loading and capture, cancels recolouring, removes the page's slot and releases the page and observations immediately |
| The first icon request waited up to 100 ms for disk on the main thread; reads completing later were discarded | A suspended disk queue reproduced a 100.46 ms wait and a missing late icon | Preload checks completion without waiting; completion on the main queue applies late icons |
| Every page update searched all open pages for every slot and searched all slots for every page | Two nested linear searches in `PageView`; the same repeated tab lookup in pinned tiles and the horizontal tab strip | Sets and dictionaries make these lookups linear overall. Visibility changes happen only when needed; deferred keyboard focus checks that the page is still visible |
| A native host exiting before a read registered its continuation left that read waiting forever | `/usr/bin/true` reproduced the stranded read in `aHostThatAlreadyExitedDoesNotLeaveAReadWaiting` | Host completion is remembered under the existing lock; later reads fail immediately, buffered replies still take priority, and stopping a pipe completes its waiters |
| Closing or sleeping a tab scheduled a global service-worker shutdown 30 seconds later, even with extensions loaded | Nerda's call site and [WebKit's implementation](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/WebProcessPool.cpp) of `terminateServiceWorkers`, reviewed on the audit date | Global worker cleanup is skipped while any extension context is loaded. This removes one plausible cause of password managers losing their background connections; it does not establish the cause of every NordPass failure |
| Extension code and workers were attached to every regular page even when reliability was more important than compatibility | Page configuration constructed the controller unconditionally; startup loaded enabled installed extensions | Extensions are paused by default. A master switch in Settings › Extensions takes effect after restarting. The controller is lazy, pages have no attached extension controller while paused, and loading and update checks are skipped. Installed files, permissions and settings are preserved |
| An extension finishing an asynchronous load could be loaded after being disabled or removed; error observers could outlive their contexts | Load suspends while preparing scripts and reading resources; unload did not remove its error watcher | Recheck installed/enabled state before loading a context, avoid duplicate contexts, and remove the error watcher during unload |

The tab-slot regression check verifies reuse across switches and full slot
removal on sleep and close. The page-configuration check verifies that the
master switch controls whether a regular page has an extension controller.
Existing tests cover media suspension, closed-tab deallocation, buffered native
replies, session restoration, privacy boundaries, extension messages and
permissions. Three new reproductions were run failing before their fixes.

## Source coverage

| Area | Files reviewed | Result |
|---|---|---|
| Launch and lifecycle | `main.swift`, `Edition.swift`, `AppMenu.swift`, `Quit.swift`, `Incognito.swift` | First page and pinned restore order reviewed; dev/test data separation and private-window boundaries retained |
| Tabs, pages and interaction | `Browser.swift`, `Tab.swift`, `TabPeek.swift`, `TabStrip.swift`, `Sidebar.swift`, `SidebarMenu.swift`, `Swipe.swift`, `Fullscreen.swift`, `FindBar.swift`, `Selection.swift` | Close ownership and quadratic lookups fixed; sleep, preview cancellation, gestures, focus, page scripts and full-screen handling reviewed |
| Navigation and history | `AddressBar.swift`, `CommandBar.swift`, `History.swift`, `HistoryPage.swift` | Suggestions measured with 20,000 visits; history already indexes once, loads and saves in the background, and uses a lazy history list |
| State and saved items | `Session.swift`, `Bookmarks.swift`, `Preferences.swift` | Session encoding/writing already serialised off the main thread and coalesced; restoration and unchanged-session tests retained. Bookmark writes are synchronous and proportional to the saved tree, on mutations rather than every frame |
| Site icons and appearance | `Favicons.swift`, `Backdrop.swift`, `WallpaperPicker.swift`, `Palette.swift` | Icon preload stall fixed; per-site observation, icon limits, background image decoding and cached wallpaper selection reviewed |
| Content blocking | `Blocker.swift` | Existing helper-process compilation, cached lists, refresh backoff and unchanged-rule suppression retained; navigation/blocker tests and benchmark exercised this path |
| Extension runtime | `Extensions.swift`, `ExtensionShims.swift`, `ExtensionNative.swift`, `ExtensionSocket.swift`, `ExtensionPopup.swift` | Default pause, worker lifetime, native read completion and observer/load guards fixed; message deduplication, popup timers, socket/orphan cleanup and worker/native keepalives reviewed |
| Extension installation and UI | `Crx.swift`, `WebStore.swift`, `ExtensionsUI.swift`, `Settings.swift` | Paused state and restart requirement shown; installation signature/permission checks retained. Paused installs are saved without attempting to run them |
| Downloads and passwords | `Downloads.swift`, `Passwords.swift`, `PasswordsWindow.swift` | Download progress already throttled before main-thread updates; keychain, authentication, clipboard expiry and account UI tasks reviewed without accessing the owner's vault |
| Developer and diagnostics | `Developer.swift`, `TaskManager.swift`, `Bench.swift` | Existing error batching and process-sampling lifetimes retained; task manager samples while its window is shown |
| Updates and shortcuts | `Updater.swift`, `UpdateCard.swift`, `AIChats.swift` | Six-hour update timer, background verification and on-demand chat icon reads reviewed; no per-frame network or disk work found in these paths |

## Measurements

`./bench.sh` was authorised for both runs. It builds an optimised Nerda Bench
with separate data, opens ten public sites five times each, measures a minute
after loading, then switches, sleeps and wakes tabs. Launch is measured ten
times with an empty session and ten times with ten restored tabs.

Baseline: `build/bench/2026-09-29-2247/` (unmodified `f986c9c`).
Final: `build/bench/2026-09-29-2327/`.
Each folder contains the raw page samples, process breakdowns, launch samples
and logs. The figures below use the benchmark's reported summary statistics.

| Measurement | Before | Final |
|---|---:|---:|
| Empty window ready, median of 10 launches | 291 ms | 301 ms |
| Window with 10 restored tabs ready, median of 10 launches | 331 ms | 330 ms |
| Restored selected page loaded, median of 10 launches | 1,159 ms | 1,173 ms |
| Address suggestions, 20,000 visits, median per key | 6.0 ms | 5.3 ms |
| History indexing, once | 43 ms | 35 ms |
| Canvas animation | 120 FPS | 120 FPS |
| CPU during that canvas animation, all processes | 33.8% | 39.6% |
| Idle CPU, all processes | 8.82% | 2.01% |
| Idle CPU, Nerda itself | 0.82% | 0.13% |
| Idle wakeups per second, all processes | 68.5 | 41.9 |
| Memory with 10 awake sites, all processes | 2,652 MB | 2,658 MB |
| Memory with 10 awake sites, Nerda itself | 93 MB | 87 MB |
| Tab switch, median of 30 switches | 13.3 ms | 10.1 ms |
| Tab switch, p90 | 26.5 ms | 28.9 ms |
| Tab switch, slowest sample | 27.2 ms | 73.9 ms |
| Memory with all but one tab asleep, all processes | 503 MB | 529 MB |
| Page processes with all but one tab asleep | 2 | 1 |
| Sleeping tab's first paint, median | 134 ms | 155 ms |
| Sleeping tab loaded, median | 696 ms | 736 ms |

The idle workload and median switch improved in these runs; total site memory
did not. Animation CPU, switch tails and sleeping-tab wake times did not
improve. This is evidence for the specific lifecycle fixes and reduced idle
work, not a claim that every operation is faster or every frame is smooth.
History code was unchanged, so its small timing change should not be credited
to a new search optimisation.

### Additional checks

An intermediate full run in `build/bench/2026-09-29-2306/` reported 332 ms
empty launch, 1.0% idle CPU and a 12.7 ms median switch. Its worse launch and
switch tails prompted additional checks rather than accepting the median alone.
The final build also avoids the extension URL-scheme API during paused startup;
the scheme is registered when creating an enabled controller or installing an
extension.

The `controlled`, `controlled-final` and `same-path` folders under that
intermediate run record alternating old/new launches and three 300-switch
plain-page runs per build. App staging and launch order substantially affected
launch totals. For example, the same-path trials reported 575 ms before and
758 ms after, while the final normal launches reported 291 and 301 ms.
These staged launch totals are retained as diagnostic evidence, not substituted
for normal-launch measurements.

To locate that delay, temporary benchmark-only copies marked startup before
NSApplication creation, after theme setup, around window creation/showing and
around extension startup. The `startup-checkpoints` folder contains those logs.
In four instrumented launches, the marked runtime span was approximately
264–283 ms before and 267–273 ms after. The large cold-launch difference
(1,130 ms before; 688 ms after) occurred before the first marked statement.
This isolates a pre-entry component of the staged-launch noise; the precise
OS or loader cause was not established. Instrumentation stayed outside the
project and the shipped build.

Plain-page switch medians also varied: 5.8–7.7 ms before and 6.2–10.7 ms after
across those checks. They do not establish an improvement in worst-case
switch latency. The deterministic closed-tab, slow-disk and exited-host
regressions provide stronger evidence for their corresponding fixes than these
short timing differences.

The fixture contains no installed extensions. Its measurements establish the
ordinary browser cost; they cannot quantify a live NordPass session or the
benefit of pausing the owner's particular extensions. Public-site load time,
advertising, service-worker state and process reuse vary between runs.

## Validation and limits

- Baseline: `swift test`, 132 tests passed.
- Updated: `swift test`, 137 tests passed.
- `git diff --check` passed.
- Existing window tests now order their windows behind the active window.
- No new dependencies or changes to WebKit's security, permission or privacy boundaries.
- Real NordPass sign-in, autofill and native-app pairing were not exercised. The reliable default for this request is to keep extensions paused; enabling them restores an optional compatibility layer with its existing WebKit limits.
- Follow-up, 30 September: every tab switch rebuilt every sidebar row, so a switch cost grew with the number of tabs (hosted-window probe, debug build, switching between two loaded pages: 3.1 ms with 10 tabs, 11.6 ms with 100, 45.5 ms with 400). The rows are now lazy (3.6, 4.5 and 5.6 ms), and the selected-tab preference is gathered only around the horizontal strip, where a profile showed it walked the whole window. `switchingTabsDoesNotSlowWithManyTabs` guards the ratio. The horizontal strip still makes all its tabs, clipped past its width limit.
- Follow-up: ten pages opened, switched and nine put to sleep in a hosted window released all nine `WKWebView`s; the benchmark's higher Nerda footprint after sleeping is not a retained page. The benchmark now wakes all nine sleeping sites with the time before the page's own clock (`overhead`) apart, and splits the animation's CPU by process. Wake `fcp` is measured on the page's clock, so it is WebKit's and the network's time, not Nerda's.
- This audit does not guarantee a frame-time ceiling for arbitrary websites, unbounded bookmark collections or third-party extensions. The benchmark covers ten concurrent public pages and the existing 20,000-visit search fixture; WebKit pages dominate the memory footprint.
