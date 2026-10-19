# Ad blocker audit

Audited on 2026-09-25 in `kamafozilov/new-tab-settings-blocking-speed`, starting at `9de8e82` plus the existing worktree changes. Scope covers list download, translation, compilation, installation, navigation and recovery in `Blocker.swift`, its `Tab.swift` callers, and the blocking tests.

The existing native architecture is appropriate. The main problems were translation errors and insufficient navigation protection. Keep WebKit's compiled network rules and the separate compiler process. No JavaScript interception, additional blocking engine or dependency is needed for these fixes. WebKit evaluates compiled rules in its resource-loading path without asking application code about every request. [WebKit architecture](https://webkit.org/blog/3476/content-blockers-first-look/)

## Findings and changes

| Finding in the audited implementation | Effect | Change |
|---|---|---|
| Host rules could include main documents; mixed `script,subdocument` rules lost the frame restriction. | An explicit first-party or site-scoped filter could deny navigation. | End the compiled list with exceptions for top-frame documents and popups. Embedded ad frames remain eligible for blocking. |
| XHR mapped to both `fetch` and `raw`. Negated types treated aliases as independent types. | An XHR filter could also block WebSockets or beacons; `~ping` could still block pings through `other`. | Use `fetch` for XHR, remove `raw` from the type universe, account for overlapping aliases, and skip positive blocking types that would broaden the filter. |
| `badfilter` lines were skipped without disabling their targets. | A rule explicitly withdrawn by a list could remain active. | Remove matching targets before compilation, including reordered options. |
| Mixed positive/negative domains caused exceptions to disappear. | An intended compatibility exception could be lost. | Continue skipping unsupported mixed-domain blocks; preserve exceptions with the positive scope, accepting some extra allowed requests. |
| `$document` exceptions extracted a hostname and discarded their path. | A path-specific exception disabled blocking throughout a site. | Match the complete pattern against the top URL. |
| `^` never matched the end of a URL. | Path filters and exceptions missed valid matches. | Support terminal separators without unsupported regex alternation. Keep ordinary host-boundary rules compact because WebKit serializes HTTP(S) host URLs with a slash. |
| Updating only the refresh preference retained the old compiled identifier. | An obsolete converter's rules loaded before the replacement, including offline. | Version the compiled artifact and freshness key together. |
| HTTP 200 alone accepted response content; refreshes lacked an overall deadline. | An error page could replace useful rules; a stuck helper could leave readiness pending. | Validate UTF-8 list headers, metadata and accepted size; bound network requests and helper lifetime; prevent overlapping refreshes. Keep the last valid rules from the current converter if refresh fails. |
| There was no user recovery control. | A future list regression required a code change. | Add a persistent Settings toggle that removes or restores Nerda's rule list on tracked controllers. Reload the affected page after changing it. |

The navigation failure was reproduced in a real `WKWebView` against a local HTTP server. Removing the final exemption produced `WebKitErrorDomain` error 104, "The URL was blocked by a content blocker"; restoring it allowed navigation. This is direct evidence for the navigation fix, independent of LinkedIn.

## Platform and syntax evidence

The official Safari 18.3/macOS 15.3 source release predates Nerda's macOS 15.4 minimum and already supports `load-context` with `top-frame` and `child-frame`. Its `raw` type expands to fetch, WebSocket, other and ping; `other` includes ping and CSP reports. Its party check compares registrable domains, so a different subdomain or port alone does not make a request third-party. This implementation is more precise than Apple's older prose describing scheme/domain/port equality. [Released WebKit resource mapping](https://github.com/WebKit/WebKit/blob/d2a4fe37e7063e6d4fd61ab2f84badc14c87981f/Source/WebCore/loader/ResourceLoadInfo.cpp)

`document` covers document loads generally. The separate `top-document` and `child-document` names landed on WebKit main on 2025-03-21. That commit explicitly describes the older equivalent using `document` plus `load-context`. The fix uses the established combination rather than assuming the newer names exist on the minimum OS. [WebKit document-type change](https://github.com/WebKit/WebKit/commit/d5d74427397d8dec2e03456dae6ea4de50060d53)

`ignore-previous-rules` applies within its compiled list. The navigation exemption must therefore remain after every Nerda blocking rule in the same list. A separate exception list would not cancel blocks in the original list. [WebKit action evaluation](https://github.com/WebKit/WebKit/blob/d2a4fe37e7063e6d4fd61ab2f84badc14c87981f/Source/WebCore/contentextensions/ContentExtensionsBackend.cpp)

ABP defines `^` as a separator or the URL's end, `subdocument` as an embedded page, and a `$document` exception as page allowlisting. These are distinct meanings that a converter must preserve. [ABP filter syntax](https://help.adblockplus.org/adblock-plus-help-center/how-to-write-filters)

`badfilter` disables an existing filter, while `important` overrides ordinary exceptions. The converter handles the former and skips the latter because preserving compatibility exceptions takes priority. This is an intentional subset, not full uBlock compatibility. [uBlock static filter syntax](https://github.com/gorhill/uBlock/wiki/Static-filter-syntax)

The public `WKWebpagePreferences` API has no content-blocker toggle. `_contentBlockersEnabled` is private API. The Settings control uses public rule-list attachment/removal instead. [Public preferences](https://developer.apple.com/documentation/webkit/wkwebpagepreferences), [released private declarations](https://github.com/WebKit/WebKit/blob/d2a4fe37e7063e6d4fd61ab2f84badc14c87981f/Source/WebKit/UIProcess/API/Cocoa/WKWebpagePreferencesPrivate.h)

## Compatibility policy and remaining limits

EasyPrivacy deliberately targets anti-bot services. Blocking such requests can conflict with sign-in or checkout. Retain the existing challenge-service exceptions and third-party-only default for generic filters. Site-scoped and explicit first-party filters retain their meaning. This trades some tracking coverage for compatibility. [EasyList and EasyPrivacy policies](https://easylist.to/pages/policy.html)

Top-level navigation protection prevents Nerda's own ad and tracker lists from denying the document; the dangerous-site lists are deliberately outside it (see below). It cannot guarantee that every site's scripts, authentication, network connection or installed extension will work. The global toggle provides recovery for a previously unknown list regression. Per-site controls would require correct controller ownership across popup windows or recompilation; they are not part of this patch.

Unsupported blocking rules are skipped rather than translated into broader blocks. Unsupported exception syntax remains a compatibility risk; the supported subset needs continued regression checks as upstream lists evolve. Mixed-domain exception broadening is deliberate. WebKit's `if-domain` targets the top document, while ABP domain restrictions can refer to embedded document contexts, so this converter does not provide exact frame-domain equivalence. [WebKit condition parser](https://github.com/WebKit/WebKit/blob/d2a4fe37e7063e6d4fd61ab2f84badc14c87981f/Source/WebCore/contentextensions/ContentExtensionParser.cpp)

Scriptlets, procedural cosmetic filters, redirects and response rewriting remain unsupported. Native network blocking cannot remove ads delivered inside otherwise necessary page content; plain element hiding (below) covers part of that.

Authenticated LinkedIn feed stalls were not reproduced or timed in this audit. The earlier `/sensorCollect/` and challenge-service explanation remains a prior diagnosis, not a newly demonstrated cause. A public or signed-out page load cannot validate the authenticated feed. No LinkedIn speed improvement is claimed.

## Verification and performance

`swift test` passed all 62 tests. The local HTTP test checks navigation, blocked and allowed requests, disabled filters with reordered options, XHR-only filtering, ad and ordinary frames, and disabling/re-enabling blocking across a list refresh without removing another rule list. Removing the navigation exemption made that test fail with WebKit error 104. `./build.sh debug` built Nerda Dev successfully.

The same downloaded EasyList snapshot, version `202609250334`, and EasyPrivacy snapshot, version `202609250325`, were compiled before and after the changes with an optimized standalone Swift executable using `ContentRules.encode` and `WKContentRuleListStore`. The executable retained the encoded and decoded JSON while compiling, so its peak RSS includes those audit allocations:

| Measurement | Before | After |
|---|---:|---:|
| Compiled input rules | 114,704 | 111,720 |
| Encoded JSON | 17.30 MB | 16.36 MB |
| Encoding time | 1.164 s | 1.570 s |
| WebKit compilation time | 3.965 s | 4.034 s |
| Compiler peak RSS | 698 MB | 712 MB |

These single-run compiler measurements show a smaller ruleset with modest extra conversion cost. They do not establish faster page loading or reduced browser memory. Compilation remains outside the browser process and only occurs during updates. The measured page results follow.


### Page benchmark

`./bench.sh` produced `build/bench/2026-09-25-0838/pages.json` before the changes and `build/bench/2026-09-25-0919/pages.json` after them. Each site was opened five times. The table uses Bench.swift's median, the upper middle of the four return visits. The first run was interrupted after its page phase, so its launch results are unavailable. Neither run isolated public network and site variation, and other settings commits landed in the same worktree between runs. These measurements do not establish a causal speedup.

| Site | Before, ms | After, ms |
|---|---:|---:|
| www.google.com | 971 | 1178 |
| en.wikipedia.org | 3460 | 3507 |
| github.com | 234 | 266 |
| www.youtube.com | 1023 | 786 |
| www.amazon.com | 1068 | 1293 |
| www.reddit.com | 1811 | 2660 |
| www.nytimes.com | 1453 | 1257 |
| news.ycombinator.com | 324 | 326 |
| stackoverflow.com | 732 | 735 |
| www.apple.com | 403 | 625 |

| Browser measurement | Before | After |
|---|---:|---:|
| Total memory, ten tabs awake | 2,821 MB | 2,650 MB |
| Nerda process, ten tabs awake | 103 MB | 88 MB |
| CPU at rest | 3.8% | 1.1% |
| Tab-switch median | 6.8 ms | 7.7 ms |
| Total memory, one tab awake | 552 MB | 496 MB |
| Wake-to-load median | 988 ms | 658 ms |

All 50 measured page loads completed within the benchmark timeout in the final run. This proves load completion only, not authenticated functionality. Memory and idle CPU were lower in this run, while page latency varied in both directions. The confirmed improvement is compatibility and recovery, with no added per-request application work. The final app fetched and compiled the new cache in 6.8 seconds; the baseline reused an existing cache, so their readiness times are not comparable.


The completed final benchmark also measured ten launches each: window-ready median 290 ms for an empty session and 340 ms restoring ten tabs; the selected restored page loaded in 1,160 ms. These launch values have no corresponding pre-change sample in this audit.

## Element hiding and dangerous-site lists (2026-10-19)

Two gaps remained. Element-hiding filters (`##`) were dropped, so the cookie-notice and annoyance lists in the catalogue did almost nothing and first-party ad containers were never hidden. And the Phishing URL Blocklist and Online Malicious URL Blocklist never stopped the dangerous page itself: the final top-frame `ignore-previous-rules` exemption let every document through, so only subresources were blocked.

### Element hiding

`ContentRules.hiding` reads `##selector`, `a.com,b.com##selector` (`if-domain`, `*` for subdomains) and `~a.com##selector` (`unless-domain`). Lines mixing sites and `~` exclusions are skipped, since WebKit takes one or the other. `ContentRules.hide` applies `#@#` exceptions conservatively: a selector excepted everywhere, or everywhere but some sites, is dropped; one excepted on named sites gets those sites as `unless-domain` on its generic rule, and its site-scoped rules are dropped rather than guess where the scopes meet. `@@…$elemhide`, `$ehide`, `$generichide`, `$ghide` and `$document` become `ignore-previous-rules` with `if-top-url` in the hiding list, turning all hiding off on those pages; `$generichide` is broadened this way rather than leave generic selectors on a page a list says they break.

Skipped before WebKit sees them: uBlock and AdGuard separators (`#?#`, `#$#`, `#%#`, `#@?#`…), `##+js(…)`, `##^…` HTML filters, procedural pseudo-classes (`:has-text`, `:-abp-*`, `:style`, `:matches-*`, `:xpath`, `:upward`, `:remove*`, `:contains`, `:min-text-length`, `:watch-attr`, `:others`, `:if`, `:if-not`, `:nth-ancestor`, `:properties`), `example.*` entity domains, and selectors that aren't closed (an unbalanced quote, bracket or parenthesis, a trailing backslash, `/*`).

WebKit's parser skips a `css-display-none` rule whose selector its CSS parser rejects, without failing the list ("Skip rules with invalid selectors to be backwards-compatible"). [ContentExtensionParser.cpp `loadAction`](https://github.com/WebKit/WebKit/blob/d2a4fe37e7063e6d4fd61ab2f84badc14c87981f/Source/WebCore/contentextensions/ContentExtensionParser.cpp) The check covers the whole selector list of one rule, so a comma-joined group would be dropped whole for one bad selector. Nerda therefore emits one rule per selector and does not group them itself: WebKit's compiler already joins the validated selectors of rules with identical condition-free triggers into one comma-separated action. [ContentExtensionCompiler.cpp `serializeActions`](https://github.com/WebKit/WebKit/blob/d2a4fe37e7063e6d4fd61ab2f84badc14c87981f/Source/WebCore/contentextensions/ContentExtensionCompiler.cpp) Because WebKit joins them with plain commas, a selector that parses alone but is left open (`[title="x`) would swallow the next; that is what the closedness check prevents. Site-scoped rules are not joined by WebKit ("Anything with condition is just pushed").

`ignore-previous-rules` cancels every earlier action in its list for that load, `css-display-none` included, and a load that saw one also skips the list's global display-none style sheet. [ContentExtensionsBackend.cpp](https://github.com/WebKit/WebKit/blob/d2a4fe37e7063e6d4fd61ab2f84badc14c87981f/Source/WebCore/contentextensions/ContentExtensionsBackend.cpp) In the network list, the top-frame exemption would therefore cancel hiding for the page. Hiding rules are encoded into parts of their own after the network parts, with only the hiding exceptions at their end. `compiledListsHideAndRefuseDangerousSites` loads a local page under `||127.0.0.1^$~third-party` plus `##.ad`: the page opens and `.ad` is hidden; `localhost##.scoped` hides only on `localhost`; `.keep:no-such-pseudo-class`, `:has-text`, `#?#`, `+js` and an unclosed selector in the same list leave compilation and the other rules intact.

### Dangerous-site lists

`FilterList.dangerous` (Phishing URL Blocklist, Online Malicious URL Blocklist, uBlock filters – Badware risks, CERT.PL's Warning List) is fetched as before but encoded separately with `ContentRules.encode(…, dangerous: true)`: no top-frame or popup exemption, no third-party default, a bare domain line (the Phishing URL Blocklist's and CERT.PL's format) read as `||domain^`, and a `$doc` block (Badware risks' format) kept as a block of the page itself, as uBlock's strict blocking does; in an ad list, a `$doc` block is still skipped. Its parts follow the ad and hiding parts under the same `blocklist-v5-N` identifiers. Ad and tracker lists keep the exemption: they never refuse a page you open. A list's exceptions now only undo blocks in its own group, so an EasyList `@@` rule no longer cancels a dangerous-site block.

When WebKit refuses a top-frame load (`WebKitErrorDomain` 104), `Browser.show` asks `Blocker.dangerousList(for:)`, which reads the chosen dangerous lists' kept copies off the main thread and tries only lines naming the host or a parent domain as rules. A match shows the tab's failure page titled "Dangerous Site", naming the list and saying to turn off Ads and trackers for the site in Site Settings, then reload. That per-site switch passes every Nerda rule list identifier to `_setContentRuleListsEnabled:exceptions:`, so it lifts the dangerous-site parts too; a standalone `WKWebView` check confirmed a 104 refusal turns into a normal load once the list's identifier is excepted, and the test above repeats it. Without the SPI, the page points to the global switch in Settings › Security & Privacy instead.

### Cost

Measured on 2026-10-19 with that day's lists, encoded by a debug build and compiled with `WKContentRuleListStore` in a test process: EasyList plus EasyPrivacy gave 111,566 network rules (compiled in 4.5 s) and a second part of 23,910 rules, 23,741 of them `css-display-none` (compiled in 0.74 s); encoding both took 4.4 s in the debug build. Badware risks became 2 parts (544 KB of rules) and CERT.PL's Warning List 1 part (2.0 MB, 16,800 domains); both compiled without errors. Each part stays well under the 145,000 per-part limit.

Performance risk: generic selectors become one global style sheet per compiled hiding list, parsed once and shared, but matched during style resolution on every page and frame; site-scoped selectors are added to each matching page. More rules also lengthen the helper's compile time and memory. The compiled list version moved from `blocklist-v4-` to `blocklist-v5-`: the v4 parts stay in use until the next scheduled refresh (they are due at once, so within the first 15 to 45 minutes) and are then removed.

`./bench.sh` on 2026-10-19, v0.0.25 (`build/bench/2026-10-19-1207` in a worktree of `7662395`) against this change with the rest of that day's fixes, first still on the v4 lists (`2026-10-19-1213`), then with the v5 lists compiled first by running the helper by hand (`2026-10-19-1218`), as the scheduled refresh would:

| Measurement | v0.0.25 | After, v4 lists | After, hiding on |
|---|---:|---:|---:|
| Memory, 10 sites awake | 2,754 MB | 2,642 MB | 2,712 MB |
| Memory, all but one asleep | 575 MB | 543 MB | 535 MB |
| CPU at rest, all processes | 3.0% | 1.5% | 1.7% |
| Wake-ups at rest, per second | 92 | 58 | 49 |
| Tab switch, 10 real sites, median / p90 | 18.3 / 27.6 ms | 22.6 / 40.9 ms | 22.8 / 34.4 ms |
| Window ready, empty / 10 tabs, median | 474 / 555 ms | 464 / 567 ms | 462 / 557 ms |
| Restored page loaded, median | 1,289 ms | 1,842 ms | 1,868 ms |
| Typing, 20,000 pages, median per key | 6.7 ms | 5.3 ms | 6.2 ms |

The restored-page and real-site switch rows were checked again, since they moved the wrong way. Restored launches, the two builds alternated, five each, three rounds: medians 1,911, 1,918 and 1,843 ms before against 2,013, 1,964 and 1,654 ms after, so the 1,289 ms of the first run was that run's network, not the build. Plain pages, 300 switches, alternated, three rounds: medians 15.4, 15.5 and 15.4 ms before, 15.3, 15.5 and 15.0 ms after, p90 lower after. The real-site switch difference appears with the v4 lists too, without hiding; it was not reproduced on plain pages and stays within the run-to-run spread of real sites.
