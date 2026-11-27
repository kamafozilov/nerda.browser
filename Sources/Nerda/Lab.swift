import AppKit
import WebKit

/// Nerda Test driven by a lab run (`./lab.sh`, Tests/NerdaLab): real sites
/// in the owner's kind of tab, measured without the owner. Only Nerda Test
/// (`./build.sh test`, data of its own) answers, and only when started with
/// `--lab <address>`: it then asks the run at that address what to do next,
/// does it and says how it went, until the run says quit or is gone.
///
/// Nothing of it may reach the owner. Its window is parked off every screen
/// and never comes forward, never key, never full screen (a page's full
/// screen stays inside it); the app has no Dock icon and is never active;
/// every page plays at a thousandth of its volume from before its first
/// load; no tabs come back from a run before and none are kept for the
/// next; and a page asking to open another app is told no.
enum Lab {
    /// Where the run is, when this launch is a lab run.
    static let address: URL? = {
        #if DEBUG
        guard Bundle.main.bundleIdentifier == "dev.nerda.browser.test",
              let flag = CommandLine.arguments.firstIndex(of: argument),
              flag + 1 < CommandLine.arguments.count else { return nil }
        return URL(string: CommandLine.arguments[flag + 1])
        #else
        return nil
        #endif
    }()

    static let argument = "--lab"
    static var isOn: Bool { address != nil }

    /// What every page plays at, of what it asks for: the media test bed's
    /// 0.001, −60 dB below the page's own volume, which the bed's sound at
    /// −20 dB puts at −80 dB. The element's own `volume` is left as the page
    /// set it, so a video still plays "with sound" to the floating rule.
    static let volume: Float = 0.001

    /// A page made for a tab or ahead of one: quiet, and hearing nothing of
    /// its window being off screen, which WebKit would take for hidden and
    /// pause its video for.
    static func prepare(_ page: WKWebView) {
        guard isOn else { return }
        let quieter = NSSelectorFromString("_setMediaVolumeForTesting:")
        if page.responds(to: quieter) {
            typealias Setter = @convention(c) (AnyObject, Selector, Float) -> Void
            unsafeBitCast(page.method(for: quieter), to: Setter.self)(page, quieter, volume)
        } else {
            quiet = false
        }
        page.hearsWindowCovered(false)
    }

    /// Whether every page could be made quiet: false once WebKit lacked the
    /// call, which the run hears and stops for.
    static var quiet = true

    /// Sound a page makes itself (Web Audio) goes through a gain of
    /// `volume` on its way out, as media elements' does in WebKit.
    static let webAudio = WKUserScript(source: """
        (() => {
            const connect = AudioNode.prototype.connect;
            const quieter = new WeakMap();
            AudioNode.prototype.connect = function (target, ...rest) {
                if (target instanceof AudioDestinationNode) {
                    let gain = quieter.get(target);
                    if (!gain) {
                        gain = this.context.createGain();
                        gain.gain.value = \(volume);
                        connect.call(gain, target);
                        quieter.set(target, gain);
                    }
                    return connect.call(this, gain, ...rest);
                }
                return connect.call(this, target, ...rest);
            };
        })();
        """, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)

    /// Where the run's scripts run: a world of their own, apart from the
    /// page's scripts and Nerda's.
    static let world = WKContentWorld.world(name: "NerdaLab")

    // MARK: - the window

    /// Where a window is kept: left of every screen, as Agent tabs' window is.
    static func park(_ window: NSWindow) {
        window.setFrameOrigin(AgentWindow.parking(beside: NSScreen.screens.map(\.frame), size: window.frame.size))
    }

    // MARK: - talking to the run

    static var client: Client?

    /// Any window of the app moved onto a screen is put back off it at
    /// once and told of (`state`'s `windows`): the run's own watch sees
    /// what is left of it, and the log says what moved it.
    static var strayed: [String] = []

    /// Something the run should know of, with where it was asked from:
    /// in /tmp/dev.nerda.lab.windows.log.
    static func told(_ what: String) {
        strayed.append(what + ": " + Thread.callStackSymbols.dropFirst(2).prefix(12).map { $0.split(separator: " ", maxSplits: 3).last.map(String.init) ?? $0 }.joined(separator: " | "))
        try? (strayed.joined(separator: "\n") + "\n").write(toFile: "/tmp/dev.nerda.lab.windows.log", atomically: true, encoding: .utf8)
    }

    static func floats(_ window: NSWindow) -> Bool { String(describing: type(of: window)) == "PIPPanel" }

    static func guardWindows() {
        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            MainActor.assumeIsolated {
                // The system's floating window (`PIPPanel`, made in the app's
                // own process) is the one window allowed on screen.
                for window in NSApp.windows where window.isVisible && !Lab.floats(window)
                    && NSScreen.screens.contains(where: { $0.frame.intersects(window.frame) }) {
                    let said = "\(type(of: window)) at \(window.frame), level \(window.level.rawValue), alpha \(window.alphaValue), "
                        + "parent \(window.parent.map { "\(type(of: $0))" } ?? "none"), content \(window.contentView.map { "\(type(of: $0))" } ?? "none")"
                    strayed.append(said)
                    try? (strayed.joined(separator: "\n") + "\n").write(toFile: "/tmp/dev.nerda.lab.windows.log", atomically: true, encoding: .utf8)
                    if window is BrowserWindow { park(window) } else { window.orderOut(nil) }
                }
            }
        }
    }

    /// Starts asking the run what to do, for `browser`'s window.
    static func start(_ browser: Browser) {
        guard let address else { return }
        browser.pictureInPictureSettings = settings
        settings.removePersistentDomain(forName: settingsName)
        guardWindows()
        client = Client(address: address, browser: browser)
        client?.run()
    }

    private static let settingsName = "dev.nerda.browser.test.lab"
    /// Auto Picture-in-Picture as the run sets it, apart from Nerda Test's own.
    static let settings = UserDefaults(suiteName: settingsName)!

    /// One thing the run asks.
    struct Command: Decodable {
        var id: Int
        var op: String
        var tab: Int?
        var url: String?
        var script: String?
        var frame: Int?
        var on: Bool?
        /// `page` for the page's own world, as its own scripts run.
        var world: String?
        var value: Double?
    }

    /// Asks the run for the next command, does it and answers, until told
    /// to quit; the run gone (no answer twice running), it quits too, so a
    /// run that died leaves nothing behind.
    final class Client {
        let address: URL
        let browser: Browser
        private var tabs: [Int: Tab] = [:]
        private var frames: [Int: [WKFrameInfo]] = [:]
        private var nextTab = 1
        private var missed = 0
        private let session: URLSession = {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 60
            return URLSession(configuration: configuration)
        }()

        init(address: URL, browser: Browser) {
            self.address = address
            self.browser = browser
        }

        func run() {
            Task { @MainActor in
                while true {
                    guard let command = await next() else {
                        missed += 1
                        if missed >= 2 { NSApp.terminate(nil) }
                        try? await Task.sleep(for: .milliseconds(500))
                        continue
                    }
                    missed = 0
                    // Each on its own, so a page's script that never ends
                    // holds up only the run's wait for it, not every command after.
                    Task { @MainActor in
                        let answer: [String: Any]
                        do {
                            answer = ["id": command.id, "ok": true, "value": try await self.perform(command)]
                        } catch {
                            answer = ["id": command.id, "ok": false, "error": "\(error)"]
                        }
                        await self.reply(answer)
                        if command.op == "quit" { NSApp.terminate(nil) }
                    }
                }
            }
        }

        /// The next command, waiting for it as long as the run holds the
        /// request; nil when the run didn't answer.
        private func next() async -> Command? {
            var parts = URLComponents(url: address.appending(path: "next"), resolvingAgainstBaseURL: false)!
            parts.queryItems = [URLQueryItem(name: "pid", value: "\(getpid())")]
            while true {
                guard let (data, response) = try? await session.data(from: parts.url!),
                      let status = (response as? HTTPURLResponse)?.statusCode else { return nil }
                if status == 204 { continue }
                guard status == 200 else { return nil }
                return try? JSONDecoder().decode(Command.self, from: data)
            }
        }

        private func reply(_ answer: [String: Any]) async {
            var request = URLRequest(url: address.appending(path: "done"))
            request.httpMethod = "POST"
            request.httpBody = (try? JSONSerialization.data(withJSONObject: answer, options: [.fragmentsAllowed]))
                ?? Data(#"{"id":\#(answer["id"] ?? 0),"ok":false,"error":"answer not JSON"}"#.utf8)
            _ = try? await session.data(for: request)
        }

        struct Failure: Error, CustomStringConvertible {
            var description: String
        }

        private func tab(_ command: Command) throws -> Tab {
            guard let id = command.tab, let tab = tabs[id], browser.tabs.contains(where: { $0 === tab }) else {
                throw Failure(description: "no such tab")
            }
            return tab
        }

        private func perform(_ command: Command) async throws -> Any {
            switch command.op {
            case "hello":
                return ["pid": Int(getpid()), "quiet": Lab.quiet]
            case "open":
                guard let url = command.url.flatMap(URL.init(string:)) else { throw Failure(description: "no address") }
                let tab = browser.open(url)
                let id = nextTab
                nextTab += 1
                tabs[id] = tab
                return id
            case "select":
                browser.select(try tab(command).id)
                return true
            case "close":
                let tab = try tab(command)
                // The window goes with its last tab, and its pages out of sight with it.
                if browser.tabs.count == 1 { browser.open(URL(string: "about:blank")!, inBackground: true) }
                browser.close(tab.id, discarding: true)
                return true
            case "floating":
                settings.set(command.on ?? false, forKey: PictureInPicture.key)
                return true
            case "state":
                let tab = try tab(command)
                let url: String = tab.page?.url?.absoluteString ?? tab.url?.absoluteString ?? ""
                let timings: [[String: Any]] = browser.recorder.timings().map { timing in
                    let kind: Any = timing.kind.rawValue, ms: Any = timing.seconds * 1000, age: Any = timing.age
                    return ["kind": kind, "ms": ms, "age": age]
                }
                var state: [String: Any] = ["url": url, "timings": timings, "quiet": Lab.quiet]
                state["loading"] = tab.page?.isLoading ?? false
                state["selected"] = browser.selected === tab
                state["floating"] = tab.isFloating
                state["playsAudio"] = tab.playsAudio
                state["chosen"] = browser.videoToFloat(in: tab) != nil
                state["strayed"] = Lab.strayed.map { String($0.prefix(200)) }
                return state
            case "frames":
                let tab = try tab(command)
                guard let page = tab.page else { throw Failure(description: "the tab has no page") }
                let found = await Lab.frames(in: page)
                frames[command.tab!] = found
                return found.map { ["url": $0.request.url?.absoluteString ?? "", "main": $0.isMainFrame] }
            case "run":
                let tab = try tab(command)
                guard let page = tab.page else { throw Failure(description: "the tab has no page") }
                page.hearsWindowCovered(false)
                let frame = command.frame.flatMap { index in frames[command.tab!].flatMap { index < $0.count ? $0[index] : nil } }
                if command.frame ?? 0 > 0, frame == nil { throw Failure(description: "no such frame") }
                // As a click would: WebKit gives a script of the browser's a user gesture.
                let world = command.world == "page" ? WKContentWorld.page : Lab.world
                let value = try await page.callAsyncJavaScript(command.script ?? "", arguments: [:], in: frame, contentWorld: world)
                return value ?? NSNull()
            case "volume":
                // The run's check that pages play quiet: never louder than a page's own.
                let page = try tab(command).page
                let quieter = NSSelectorFromString("_setMediaVolumeForTesting:")
                guard let page, page.responds(to: quieter) else { throw Failure(description: "no page volume") }
                typealias Setter = @convention(c) (AnyObject, Selector, Float) -> Void
                unsafeBitCast(page.method(for: quieter), to: Setter.self)(page, quieter, Float(min(max(command.value ?? 0, 0), 1)))
                return true
            case "windows":
                // The system's floating window shows as a window of this process (`PIPPanel`).
                return NSApp.windows.filter(Lab.floats).map(\.windowNumber)
            case "quit":
                return true
            default:
                throw Failure(description: "unknown op \(command.op)")
            }
        }
    }

    /// Every frame of `page`, the main one first, through WebKit SPI
    /// (`_frames:`); the main frame alone should it go.
    static func frames(in page: WKWebView) async -> [WKFrameInfo] {
        let selector = NSSelectorFromString("_frames:")
        guard page.responds(to: selector) else { return [] }
        typealias Frames = @convention(c) (AnyObject, Selector, @escaping @convention(block) (NSObject?) -> Void) -> Void
        return await withCheckedContinuation { (done: CheckedContinuation<[WKFrameInfo], Never>) in
            unsafeBitCast(page.method(for: selector), to: Frames.self)(page, selector) { tree in
                var found: [WKFrameInfo] = []
                func walk(_ node: NSObject?) {
                    guard let node else { return }
                    if let info = node.value(forKey: "info") as? WKFrameInfo { found.append(info) }
                    for child in node.value(forKey: "childFrames") as? [NSObject] ?? [] { walk(child) }
                }
                walk(tree)
                done.resume(returning: found)
            }
        }
    }
}
