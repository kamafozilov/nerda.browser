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

Top-level navigation protection prevents Nerda's own network list from denying the document. It cannot guarantee that every site's scripts, authentication, network connection or installed extension will work. The global toggle provides recovery for a previously unknown list regression. Per-site controls would require correct controller ownership across popup windows or recompilation; they are not part of this patch.

Unsupported blocking rules are skipped rather than translated into broader blocks. Unsupported exception syntax remains a compatibility risk; the supported subset needs continued regression checks as upstream lists evolve. Mixed-domain exception broadening is deliberate. WebKit's `if-domain` targets the top document, while ABP domain restrictions can refer to embedded document contexts, so this converter does not provide exact frame-domain equivalence. [WebKit condition parser](https://github.com/WebKit/WebKit/blob/d2a4fe37e7063e6d4fd61ab2f84badc14c87981f/Source/WebCore/contentextensions/ContentExtensionParser.cpp)

Cosmetic filtering, scriptlets, redirects and response rewriting remain unsupported. Native network blocking cannot remove ads delivered inside otherwise necessary page content. Adding these features requires separate compatibility evidence, including their exceptions, rather than silently interpreting them as network blocks.

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
