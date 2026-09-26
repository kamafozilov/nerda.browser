#if DEBUG
import AppKit
import WebKit

/// Nerda Bench (`./bench.sh`): times what people wait on in a browser, and
/// what it costs them: launching, opening pages, switching tabs, waking a
/// sleeping one, memory and CPU at rest, and the web's own benchmarks. Runs
/// only when NERDA_BENCH names a folder for the results, and quits when done.
enum Bench {
    private static let environment = ProcessInfo.processInfo.environment

    /// Sites of every kind people spend their day on: a search, an article, a
    /// store, videos, news, code, forums.
    static let sites = [
        "https://www.google.com/search?q=web+browser",
        "https://en.wikipedia.org/wiki/Web_browser",
        "https://github.com/WebKit/WebKit",
        "https://www.youtube.com/",
        "https://www.amazon.com/",
        "https://www.reddit.com/",
        "https://www.nytimes.com/",
        "https://news.ycombinator.com/",
        "https://stackoverflow.com/questions",
        "https://www.apple.com/",
    ].compactMap(URL.init(string:))

    /// How often each site is opened: first with nothing cached, then as a return visit.
    static let rounds = Int(environment["NERDA_BENCH_ROUNDS"] ?? "") ?? 5

    static func start(_ browser: Browser, _ window: NSWindow) {
        guard let path = environment["NERDA_BENCH"] else { return }
        let folder = URL(filePath: path)
        setvbuf(stdout, nil, _IOLBF, 0)
        // The first turn of the run loop: the window is up, drawn, and takes clicks.
        DispatchQueue.main.async {
            window.displayIfNeeded()
            let launched = sinceStart()
            Task {
                switch environment["NERDA_BENCH_MODE"] {
                case "launch": await launch(launched, browser, folder)
                case "web": await web(browser, folder)
                case "switch": await switching(browser)
                case "frames": var results: [String: Any] = [:]; await frames(browser, into: &results)
                default: await pages(browser, folder)
                }
                exit(0)
            }
        }
    }

    // MARK: Launch

    /// One line to launch.tsv: until the window is ready and, with a page to
    /// open again from the last session, until it has loaded.
    private static func launch(_ launched: Double, _ browser: Browser, _ folder: URL) async {
        var line = String(format: "%.1f", launched)
        if let tab = browser.selected, tab.hasPage, let loaded = await load(tab) {
            line += String(format: "\t%.1f", sinceStart() - since(loaded))
        }
        append(line + "\n", to: folder.appending(path: "launch.tsv"))
    }

    // MARK: Pages and tabs

    private static func pages(_ browser: Browser, _ folder: URL) async {
        var results: [String: Any] = [:]
        // Pages timed as they load for people: with ads and trackers blocked.
        let blocking = Date.now
        Blocker.shared.start()
        await Blocker.shared.ready()
        say(String(format: "Block list %@ in %.1f s; Nerda then %.0f MB", Blocker.shared.rules.isEmpty ? "missing" : "ready",
                   since(blocking) / 1000, memory()["nerda"] ?? 0))

        typing(into: &results)
        await frames(browser, into: &results)

        say("Opening each site in a new tab, \(rounds) times (the first with nothing cached), ms:")
        say(row("site", "first", "fcp", "again", "fcp", "ttfb", "overhead"))
        var loads: [[String: Any]] = []
        for site in sites {
            var samples: [[String: Double]] = []
            for _ in 0..<rounds {
                let start = Date.now
                browser.open(site)
                guard let tab = browser.selected else { continue }
                let loaded = await load(tab)
                var sample = await timings(of: tab.webView)
                let open = (loaded ?? .now).timeIntervalSince(start) * 1000
                sample["open"] = open
                // What the page's own clock doesn't see: the tab and its page
                // made, WebKit's process started, Nerda's say on the navigation.
                // Up to where that clock starts, as it said how long ago that
                // was: `open` ends with the page's last load, and a site that
                // sends itself on (github.com, nytimes.com) came out below zero
                // against the load time of a document other than the one timed.
                if let age = sample.removeValue(forKey: "age") {
                    sample["overhead"] = Date.now.timeIntervalSince(start) * 1000 - age
                }
                if loaded == nil { sample["timedOut"] = 1 }
                samples.append(sample)
                browser.close(tab.id)
                try? await Task.sleep(for: .milliseconds(300))
            }
            let again = Array(samples.dropFirst())
            say(row(site.host() ?? "", samples.first?["open"], samples.first?["fcp"],
                    median(again, "open"), median(again, "fcp"), median(again, "ttfb"), median(again, "overhead")))
            loads.append(["site": site.absoluteString, "samples": samples])
        }
        results["loads"] = loads

        say("\nAll \(sites.count) sites open at once:")
        var tabs: [Tab] = []
        for site in sites {
            browser.open(site, inBackground: true)
            tabs.append(browser.tabs[browser.pinnedCount])
        }
        browser.select(tabs[0].id)
        for tab in tabs { _ = await until(60) { !tab.isLoading } }
        // At rest as tabs are most of the time: a minute on, past the bustle
        // of loading, with the pages out of sight slowed down as they are then.
        try? await Task.sleep(for: .seconds(60))
        let awake = memory()
        say("  memory, all awake: \(describe(awake))")
        results["memoryAwake"] = awake

        // Each page's process named by its site, to tell which one is busy.
        var sites: [pid_t: String] = [:]
        for tab in tabs {
            if let pid = (tab.page?.value(forKey: "_webProcessIdentifier") as? NSNumber)?.int32Value {
                sites[pid] = tab.url?.host() ?? "?"
            }
        }
        let idle = await cpu(over: 10, naming: sites)
        say(String(format: "  at rest a minute on, one page on screen: %.1f%% CPU, %.0f wake-ups/s", idle.percent, idle.wakeups))
        let busiest = idle.by.sorted { $0.value > $1.value }.prefix(5)
        say("    busiest: " + busiest.map { String(format: "%@ %.1f%%", $0.key, $0.value) }.joined(separator: ", "))
        results["idle"] = ["cpuPercent": idle.percent, "wakeupsPerSecond": idle.wakeups, "by": idle.by]

        // Until the page is on screen, and the window drawn with it.
        var switches: [Double] = []
        for _ in 0..<3 {
            for tab in tabs.dropFirst() + [tabs[0]] {
                let start = Date.now
                browser.select(tab.id)
                _ = await until(2) { tab.page?.isHidden == false }
                tab.page?.window?.displayIfNeeded()
                switches.append(since(start))
            }
        }
        say(String(format: "  switching tabs: median %.1f ms, p90 %.1f ms, slowest %.1f ms", median(switches),
                   switches.sorted()[switches.count * 9 / 10], switches.max() ?? 0))
        results["tabSwitch"] = switches

        for tab in tabs where tab.id != browser.selectedID { tab.sleep() }
        // Long enough for the pages' processes to be let go of, and their
        // sites' service workers (Tab.endServiceWorkers).
        try? await Task.sleep(for: .seconds(35))
        let asleep = memory()
        say("  memory, all but one asleep: \(describe(asleep))")
        // What is still up besides the page on screen: a page's process let go of late, or kept.
        let shown = (browser.selected?.page?.value(forKey: "_webProcessIdentifier") as? NSNumber)?.int32Value
        for (pid, usage) in processes() where ["pages", ""].contains(kind(of: pid)) {
            say(String(format: "    page process %d %@%@: %.0f MB", pid, sites[pid] ?? "?", pid == shown ? " (on screen)" : "",
                       Double(usage.ri_phys_footprint) / 1_048_576))
        }
        results["memoryAsleep"] = asleep

        // Until it is drawn (what is seen), and until it is loaded.
        var wakes: [[String: Double]] = []
        for tab in tabs.dropFirst().prefix(3) {
            let start = Date.now
            browser.select(tab.id)
            let loaded = await load(tab)
            var sample = await timings(of: tab.webView)
            sample["open"] = (loaded ?? .now).timeIntervalSince(start) * 1000
            wakes.append(sample)
        }
        say(String(format: "  waking a sleeping tab: median %.0f ms drawn, %.0f ms loaded",
                    median(wakes, "fcp") ?? 0, median(wakes, "open") ?? 0))
        results["wake"] = wakes

        // For ./bench.sh's launches that open these tabs again.
        browser.saveSession()
        write(results, to: folder.appending(path: "pages.json"))
    }

    /// What each key costs the address bar, with as much history as is kept
    /// (History.limit). On its own, so that history is gone before memory is measured.
    private static func typing(into results: inout [String: Any]) {
        let history = History()
        // As long as real ones: addresses of 80 to 140 characters, titles of 40 to 90.
        let sites = ["www.youtube.com", "github.com", "en.wikipedia.org", "stackoverflow.com", "developer.apple.com",
                     "www.reddit.com", "medium.com", "news.ycombinator.com"]
        let names = ["YouTube", "GitHub", "Wikipedia", "Stack Overflow", "Apple Developer", "Reddit", "Medium", "Hacker News"]
        let words = ["swift", "concurrency", "actors", "memory", "layout", "performance", "server", "rendering",
                     "pipeline", "release", "notes", "design", "system", "tutorial", "guide", "review", "benchmark",
                     "network", "storage", "privacy", "search", "history", "window", "keyboard"]
        for page in 0..<20_000 {
            let news = page % 5 == 4
            let site = news ? "news.site\(page % 500).com" : sites[page % sites.count]
            let slug = (0..<(3 + page % 4)).map { words[(page / (3 + $0) + $0 * 7) % words.count] }
            let url = "https://\(site)/\(slug[0])/\(page)/\(slug.joined(separator: "-"))?utm_source=newsletter&ref=\(page % 97)"
            let title = slug.map(\.capitalized).joined(separator: " ") + ", topic \(page % 97) - "
                + (news ? "Daily News" : names[page % names.count])
            history.visit(URL(string: url)!, title: title)
        }
        let indexed = Date.now
        _ = history.recent(1)
        let indexing = since(indexed)
        var keys: [Double] = []
        for typed in ["y", "yo", "you", "yout", "youtu", "youtub", "youtube", "topic", "topic 4", "swift book"] {
            let start = Date.now
            _ = CommandBar.suggestions(for: typed, guesses: [], history: history)
            keys.append(since(start))
        }
        say(String(format: "Typing in the address bar, 20,000 pages in history: median %.1f ms a key, slowest %.1f ms (indexed once, in %.0f ms)\n",
                    median(keys), keys.max() ?? 0, indexing))
        results["typing"] = keys
        results["historyIndex"] = indexing
    }

    /// How often a page that animates from script is drawn (the screen's
    /// rate, or WebKit's 60), and what that costs, on screen. Each frame it
    /// draws on a canvas, as a chart or a game does: the dearer kind of
    /// animation, where a CSS one is mostly left to the graphics card.
    private static func frames(_ browser: Browser, into results: inout [String: Any]) async {
        browser.open(URL(string: """
            data:text/html,<canvas width=800 height=600></canvas><script>
            const c = document.querySelector('canvas').getContext('2d'); window.n = 0;
            const step = t => { n++; c.clearRect(0, 0, 800, 600);
                for (let i = 0; i < 200; i++) c.fillRect(400 + 300 * Math.sin(t / 500 + i), 300 + 250 * Math.cos(t / 700 + i), 20, 20);
                requestAnimationFrame(step); };
            requestAnimationFrame(step);</script>
            """.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!)!)
        guard let tab = browser.selected else { return }
        _ = await load(tab)
        try? await Task.sleep(for: .seconds(2))
        let count = "return window.n"
        let before = try? await tab.webView.callAsyncJavaScript(count, contentWorld: .page) as? Double
        let start = Date.now
        let busy = await cpu(over: 10)
        let after = try? await tab.webView.callAsyncJavaScript(count, contentWorld: .page) as? Double
        let perSecond = ((after ?? 0) - (before ?? 0)) / (since(start) / 1000)
        say(String(format: "A page drawing from script, on screen: %.0f frames/s, %.1f%% CPU, %.0f wake-ups/s\n",
                   perSecond, busy.percent, busy.wakeups))
        results["frames"] = ["perSecond": perSecond, "cpuPercent": busy.percent, "wakeupsPerSecond": busy.wakeups]
        browser.close(tab.id)
    }

    /// Switching tabs alone, over and over, for a profiler to watch
    /// (`NERDA_BENCH_MODE=switch`): ten plain pages, 300 switches.
    private static func switching(_ browser: Browser) async {
        var tabs: [Tab] = []
        for n in 0..<10 {
            browser.open(URL(string: "data:text/html,page-\(n)")!)
            tabs.append(browser.selected!)
            _ = await load(tabs.last!)
        }
        try? await Task.sleep(for: .seconds(2))
        var switches: [Double] = []
        for round in 0..<30 {
            for tab in tabs {
                let start = Date.now
                browser.select(tab.id)
                _ = await until(2) { tab.page?.isHidden == false }
                tab.page?.window?.displayIfNeeded()
                if round > 0 { switches.append(since(start)) }
            }
        }
        say(String(format: "switching tabs: median %.1f ms, p90 %.1f ms, slowest %.1f ms", median(switches),
                   switches.sorted()[switches.count * 9 / 10], switches.max() ?? 0))
    }

    /// Waits for the tab's page to start loading, then to be done: when it
    /// was, or nil if not in time. A page that sends itself on (a consent or
    /// bot check, a script's redirect) loads again at once: it is done once
    /// it stays done.
    private static func load(_ tab: Tab) async -> Date? {
        _ = await until(5) { tab.isLoading }
        var loaded: Date
        repeat {
            guard await until(60, { !tab.isLoading }) else { return nil }
            loaded = .now
        } while await until(0.5, { tab.isLoading })
        return loaded
    }

    /// The page's own clock, from the start of its navigation, in ms.
    private static func timings(of page: WKWebView) async -> [String: Double] {
        let values = try? await page.callAsyncJavaScript(timingScript, contentWorld: .defaultClient) as? [String: Any]
        return (values ?? [:]).compactMapValues { $0 as? Double }
    }

    private static let timingScript = """
        const n = performance.getEntriesByType('navigation')[0];
        const fcp = performance.getEntriesByName('first-contentful-paint')[0];
        let lcp = null;
        if (PerformanceObserver.supportedEntryTypes.includes('largest-contentful-paint')) {
            lcp = await new Promise(done => {
                new PerformanceObserver(list => done(list.getEntries().at(-1).startTime))
                    .observe({ type: 'largest-contentful-paint', buffered: true });
                setTimeout(() => done(null), 50);
            });
        }
        return { ttfb: n?.responseStart, fcp: fcp?.startTime, lcp, dcl: n?.domContentLoadedEventEnd,
                 load: n?.loadEventEnd, requests: performance.getEntriesByType('resource').length, age: performance.now() };
        """

    // MARK: The web's benchmarks

    /// The suites browser makers measure their engines with. Nerda's engine is
    /// Safari's: a score below Safari's on the same Mac is Nerda's own doing.
    private static let suites: [(name: String, url: String, start: String?, score: String)] = [
        ("Speedometer 3.1", "https://browserbench.org/Speedometer3.1/?startAutomatically",
         nil, "return document.getElementById('result-number')?.textContent"),
        ("JetStream 3.0", "https://browserbench.org/JetStream3.0/?startAutomatically=true",
         nil, "return document.querySelector('#result-summary.done .score')?.textContent"),
        ("MotionMark 1.3.1", "https://browserbench.org/MotionMark1.3.1/",
         "benchmarkController.startBenchmark()", "return document.querySelector('#results .score')?.textContent"),
    ]

    private static func web(_ browser: Browser, _ folder: URL) async {
        var scores: [String: String] = [:]
        for suite in suites {
            guard let url = URL(string: suite.url) else { continue }
            say("\(suite.name)…")
            browser.open(url)
            guard let tab = browser.selected else { continue }
            _ = await load(tab)
            try? await Task.sleep(for: .seconds(2))
            if let start = suite.start { _ = try? await tab.webView.callAsyncJavaScript(start, contentWorld: .page) }
            var score: String?
            let deadline = Date.now.addingTimeInterval(20 * 60)
            while Date.now < deadline {
                try? await Task.sleep(for: .seconds(3))
                let text = try? await tab.webView.callAsyncJavaScript(suite.score, contentWorld: .page) as? String
                if let text, !text.trimmingCharacters(in: .whitespaces).isEmpty { score = text; break }
            }
            scores[suite.name] = score ?? "timed out"
            say("  \(suite.name): \(score ?? "timed out")")
            browser.close(tab.id)
        }
        write(scores, to: folder.appending(path: "web.json"))
    }

    // MARK: Memory and CPU

    /// Nerda and the WebKit processes working for it (its pages, their
    /// network and graphics), found as Activity Monitor finds them: by whom
    /// they work for. Nerda must be opened by LaunchServices (`open`), or
    /// they work for the terminal it was started from.
    private static func processes() -> [(pid: pid_t, usage: rusage_info_v4)] {
        var pids = [pid_t](repeating: 0, count: 8192)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        let me = getpid()
        return pids.prefix(max(count, 0)).compactMap { pid in
            guard pid == me || responsiblePID(pid) == me else { return nil }
            var usage = rusage_info_v4()
            let read = withUnsafeMutablePointer(to: &usage) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            }
            return read == 0 ? (pid, usage) : nil
        }
    }

    /// Footprint in MB, as Activity Monitor's Memory column: Nerda's own, and its WebKit processes' by kind.
    private static func memory() -> [String: Double] {
        var memory: [String: Double] = [:]
        for (pid, usage) in processes() {
            let kind = pid == getpid() ? "nerda" : kind(of: pid)
            memory[kind, default: 0] += Double(usage.ri_phys_footprint) / 1_048_576
            if kind == "pages" { memory["pageProcesses", default: 0] += 1 }
        }
        memory["total"] = memory.filter { $0.key != "pageProcesses" }.values.reduce(0, +)
        return memory
    }

    private static func kind(of pid: pid_t) -> String {
        var name = [CChar](repeating: 0, count: 256)
        proc_name(pid, &name, UInt32(name.count))
        let process = String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        if process.contains("WebContent") { return "pages" }
        if process.contains("Networking") { return "network" }
        if process.contains("GPU") { return "graphics" }
        return process
    }

    /// CPU time, as a share of one core, and wake-ups from idle, of Nerda and its processes over `seconds`.
    private static func cpu(over seconds: Double, naming sites: [pid_t: String] = [:]) async
        -> (percent: Double, wakeups: Double, by: [String: Double]) {
        let before = Dictionary(processes().map { ($0.pid, $0.usage) }) { a, _ in a }
        try? await Task.sleep(for: .seconds(seconds))
        var info = mach_timebase_info()
        mach_timebase_info(&info)
        var time = 0.0, wakeups = 0.0
        var by: [String: Double] = [:]
        for (pid, after) in processes() {
            guard let start = before[pid] else { continue }
            // In ticks of the Mac's clock, not nanoseconds, on Apple silicon.
            let ticks = (after.ri_user_time + after.ri_system_time) - (start.ri_user_time + start.ri_system_time)
            let spent = Double(ticks) * Double(info.numer) / Double(info.denom) / 1e9
            time += spent
            let name = pid == getpid() ? "nerda" : sites[pid] ?? kind(of: pid)
            by[name, default: 0] += spent / seconds * 100
            wakeups += Double((after.ri_pkg_idle_wkups + after.ri_interrupt_wkups) - (start.ri_pkg_idle_wkups + start.ri_interrupt_wkups))
        }
        return (time / seconds * 100, wakeups / seconds, by)
    }

    private static func describe(_ memory: [String: Double]) -> String {
        String(format: "%.0f MB (Nerda %.0f, %.0f pages' processes %.0f, network %.0f, graphics %.0f)",
               memory["total"] ?? 0, memory["nerda"] ?? 0, memory["pageProcesses"] ?? 0,
               memory["pages"] ?? 0, memory["network"] ?? 0, memory["graphics"] ?? 0)
    }

    // MARK: Helpers

    /// Checks `done` every millisecond, for up to `timeout` seconds: whether it came true.
    private static func until(_ timeout: Double, _ done: () -> Bool) async -> Bool {
        let deadline = Date.now.addingTimeInterval(timeout)
        while !done() {
            if Date.now > deadline { return false }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return true
    }

    /// Since the process started (before any of Nerda's code ran), in ms.
    private static func sinceStart() -> Double {
        var process = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var query = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        sysctl(&query, 4, &process, &size, nil, 0)
        let start = process.kp_proc.p_un.__p_starttime
        return (Date.now.timeIntervalSince1970 - (Double(start.tv_sec) + Double(start.tv_usec) / 1e6)) * 1000
    }

    private static func since(_ start: Date) -> Double { Date.now.timeIntervalSince(start) * 1000 }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
    }

    private static func median(_ samples: [[String: Double]], _ key: String) -> Double? {
        let values = samples.compactMap { $0[key] }
        return values.isEmpty ? nil : median(values)
    }

    private static func row(_ name: String, _ values: Double?...) -> String {
        name.padding(toLength: 24, withPad: " ", startingAt: 0)
            + values.map { ($0.map { String(format: "%.0f", $0) } ?? "–").leftPadded(9) }.joined()
    }

    private static func row(_ name: String, _ headings: String...) -> String {
        name.padding(toLength: 24, withPad: " ", startingAt: 0) + headings.map { $0.leftPadded(9) }.joined()
    }

    private static func say(_ line: String) { print(line) }

    private static func write(_ value: Any, to file: URL) {
        let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        try? data?.write(to: file)
    }

    private static func append(_ text: String, to file: URL) {
        if let handle = try? FileHandle(forWritingTo: file) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        } else {
            try? Data(text.utf8).write(to: file)
        }
    }
}

private extension String {
    func leftPadded(_ width: Int) -> String { String(repeating: " ", count: max(width - count, 0)) + self }
}

/// Who a process works for, as the system counts it for privacy prompts and
/// Activity Monitor: a WebKit process works for the app whose page it runs.
@_silgen_name("responsibility_get_pid_responsible_for_pid")
private func responsiblePID(_ pid: pid_t) -> pid_t
#endif
