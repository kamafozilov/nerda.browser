// Adapted from Browser.swift and Tab.swift in Yab (https://github.com/yetanotherbrowser/yab), Apache License 2.0, Copyright 2026 Serafim Korablev; changed for Nerda.
import WebKit

/// One page kept ready for each regular data store (Personal's, each
/// profile's): a blank page whose process is already running. The next
/// page that store's tabs make for the web, a new tab's or a link's opened
/// in one, or a sleeping tab's woken, is that page, so it starts loading at
/// once rather than after its process starts: Yab measured 101–116 ms →
/// 60–66 ms a new tab, for about 10 MB. Another is made a moment after one
/// is taken. None in Low Power Mode, nor for an incognito window, whose
/// store is in memory. NERDA_SPARE_PAGE=0 turns it off for one run.
enum SparePages {
    static var isOn: Bool { Speedups.isOn("SPARE_PAGE") }

    /// How long after one is taken the next is made: the tab that took it
    /// gets the time to load first.
    static let renewal: TimeInterval = 1.5

    private final class Kept {
        let store: WKWebsiteDataStore
        var page: SwipingWebView?
        var timer: Timer?

        init(store: WKWebsiteDataStore) { self.store = store }
    }

    private static var kept: [Kept] = []

    /// `store` keeps a spare from now on, the first made in `seconds`.
    /// Never for a store in memory (incognito).
    static func keep(for store: WKWebsiteDataStore, in seconds: TimeInterval = renewal) {
        guard isOn, store.isPersistent else { return }
        _ = watchingPower
        let spare = kept.first { $0.store === store } ?? {
            let new = Kept(store: store)
            kept.append(new)
            return new
        }()
        if spare.page == nil { renew(spare, in: seconds) }
    }

    /// The spare page for a page `store`'s tab is making for the web, if
    /// there is one; the next is made in a moment.
    static func take(for store: WKWebsiteDataStore) -> SwipingWebView? {
        guard isOn, let spare = kept.first(where: { $0.store === store }), let page = spare.page else { return nil }
        spare.page = nil
        renew(spare, in: renewal)
        return page
    }

    /// The spare `store` has now, untouched.
    static func page(for store: WKWebsiteDataStore) -> WKWebView? {
        kept.first { $0.store === store }?.page
    }

    /// `store` keeps none any more, its page let go: a profile deleted,
    /// as WebKit removes a store only once no page uses it.
    static func drop(for store: WKWebsiteDataStore) {
        guard let index = kept.firstIndex(where: { $0.store === store }) else { return }
        kept[index].timer?.invalidate()
        kept.remove(at: index)
    }

    private static let watcher = NSObject()
    private static let watchingPower: Void = LowPowerMode.watch(watcher) { powerChanged($0) }

    /// Low Power Mode on, the spares go; off, they come back.
    private static func powerChanged(_ on: Bool) {
        for spare in kept {
            if on {
                spare.timer?.invalidate()
                spare.timer = nil
                spare.page = nil
            } else if spare.page == nil {
                renew(spare, in: renewal)
            }
        }
    }

    /// Made on a turn of the run loop in its default mode only, so never in
    /// the middle of a drag or a scroll.
    private static func renew(_ spare: Kept, in seconds: TimeInterval) {
        guard spare.timer == nil else { return }
        let timer = Timer(timeInterval: seconds, repeats: false) { [weak spare] _ in
            MainActor.assumeIsolated {
                guard let spare else { return }
                spare.timer = nil
                guard spare.page == nil, !LowPowerMode.isOn, kept.contains(where: { $0 === spare }) else { return }
                spare.page = Tab.sparePage(for: spare.store)
            }
        }
        RunLoop.main.add(timer, forMode: .default)
        spare.timer = timer
    }
}
