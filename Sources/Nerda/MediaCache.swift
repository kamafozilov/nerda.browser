import WebKit

/// Video and sound played from a file (an .mp4, an .mp3) keep what has
/// loaded, as in Chrome: a step back plays at once, rather than waiting on
/// the server again. WebKit hands such a file to AVFoundation, which keeps
/// only what is ahead of the playhead, and WebKit's cache keeps no media
/// (NetworkCache's `NoDueToStreamingMedia`): each step back asked the server
/// for it again, and a server barely faster than the video stuttered on for
/// minutes after. So a page's address for a file on another site is handed
/// to WebKit as nerda-media:, whose bytes Nerda fetches and keeps on disk by
/// range while it runs; the page reads back the address it set.
// ponytail: only addresses set from script (src, setAttribute); a <video src>
// written in the page's HTML loads as before, as watching every page's
// changes for one would cost them all.
final class MediaCache: NSObject, WKURLSchemeHandler, URLSessionDataDelegate {
    nonisolated static let scheme = "nerda-media"
    static let shared = MediaCache()

    /// The address the page set, for one handed to WebKit.
    nonisolated static func original(_ url: URL) -> URL {
        guard url.scheme == scheme else { return url }
        return URL(string: "https:" + url.absoluteString.dropFirst(scheme.count + 1)) ?? url
    }

    /// WebKit SPI on the pool: without it the scheme counts as insecure, and
    /// an https page would block its media as mixed content. Should it go,
    /// pages keep WebKit's own loading, the script left out.
    static func register(in pool: Any?) -> Bool {
        let secure = NSSelectorFromString("_registerURLSchemeAsSecure:")
        guard let pool = pool as? NSObject, pool.responds(to: secure) else { return false }
        pool.perform(secure, with: scheme)
        return true
    }

    /// In the page's own world, in every frame, before any of the page's
    /// scripts. Left as WebKit loads them: a stream a player builds itself
    /// (blob:), an HLS playlist, an element asking for CORS, and the page's
    /// own files, as its script may read their pixels (a canvas, WebGL),
    /// which an address of another origin forbids. One the page's Content
    /// Security Policy refuses, or that fails before it starts, is loaded
    /// again from its own address, the page none the wiser.
    static let script = WKUserScript(source: #"""
        (() => {
            const scheme = '\#(scheme):';
            const media = HTMLMediaElement.prototype, source = HTMLSourceElement.prototype;
            const plainSrc = new Map([[media, Object.getOwnPropertyDescriptor(media, 'src')], [source, Object.getOwnPropertyDescriptor(source, 'src')]]);
            const currentSrc = Object.getOwnPropertyDescriptor(media, 'currentSrc');
            const { setAttribute, getAttribute } = Element.prototype;
            if ([...plainSrc.values()].some(plain => !plain?.set) || !currentSrc?.get) return;
            const owner = element => element instanceof HTMLSourceElement ? element.parentElement : element;
            const kept = (element, value) => {
                if (element.hasAttribute('crossorigin') || owner(element)?.hasAttribute('crossorigin')) return value;
                let url;
                try { url = new URL(value, document.baseURI); } catch { return value; }
                if (url.protocol !== 'https:' || url.origin === location.origin || /\.m3u8?$/i.test(url.pathname)) return value;
                return scheme + url.href.slice('https:'.length);
            };
            const original = value => typeof value === 'string' && value.startsWith(scheme) ? 'https:' + value.slice(scheme.length) : value;
            for (const [prototype, plain] of plainSrc) {
                Object.defineProperty(prototype, 'src', {
                    get() { return original(plain.get.call(this)); },
                    set(value) { plain.set.call(this, kept(this, String(value))); },
                    enumerable: plain.enumerable, configurable: true,
                });
                const own = {
                    setAttribute(name, value) {
                        return setAttribute.call(this, name, String(name).toLowerCase() === 'src' ? kept(this, String(value)) : value);
                    },
                    getAttribute(name) {
                        const value = getAttribute.call(this, name);
                        return String(name).toLowerCase() === 'src' ? original(value) : value;
                    },
                };
                for (const name of ['setAttribute', 'getAttribute']) {
                    Object.defineProperty(prototype, name, { value: own[name], writable: true, enumerable: true, configurable: true });
                }
            }
            Object.defineProperty(media, 'currentSrc', {
                get() { return original(currentSrc.get.call(this)); },
                enumerable: currentSrc.enumerable, configurable: true,
            });
            // Failed before anything played (refused by the page's policy, or by
            // WebKit): its own addresses again, and the events of the switch unheard.
            const quiet = new WeakSet();
            const proxied = element => getAttribute.call(element, 'src')?.startsWith(scheme);
            addEventListener('error', event => {
                const element = owner(event.target);
                if (!(element instanceof HTMLMediaElement) || element.readyState > 0) return;
                const sources = [element, ...element.querySelectorAll('source')].filter(proxied);
                if (!sources.length) return;
                event.stopImmediatePropagation();
                quiet.add(element);
                for (const one of sources) setAttribute.call(one, 'src', original(getAttribute.call(one, 'src')));
                if (!element.hasAttribute('src')) element.load();
            }, true);
            for (const type of ['abort', 'emptied']) {
                addEventListener(type, event => { if (quiet.has(event.target)) event.stopImmediatePropagation(); }, true);
            }
            addEventListener('loadstart', event => quiet.delete(event.target), true);
        })();
        """#, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)

    /// One file: what has come of it, kept by byte range in a file of its
    /// own, the answers WebKit waits on, and the fetches filling it.
    private final class Stored {
        let url: URL
        let path: URL
        let handle: FileHandle
        /// As WebKit would send them for the page: its browser's name, not
        /// AVFoundation's, the frame's origin as referrer, its cookies.
        var headers: [String: String]?
        /// The whole file's size and type, once its server has said.
        var length: Int64?
        var type: String?
        /// Sorted, apart from each other.
        var have: [Range<Int64>] = []
        var loads: [Load] = []
        var fetches: [Fetch] = []
        var used = Date.now

        init?(url: URL, path: URL) {
            guard FileManager.default.createFile(atPath: path.path, contents: nil),
                  let handle = try? FileHandle(forUpdating: path) else { return nil }
            self.url = url
            self.path = path
            self.handle = handle
        }

        var size: Int64 { have.reduce(0) { $0 + $1.upperBound - $1.lowerBound } }

        func kept(at offset: Int64) -> Range<Int64>? { have.first { $0.contains(offset) } }

        /// Where what is kept or on its way runs out, going on from `offset`.
        func covered(from offset: Int64) -> Int64 {
            var end = offset
            for span in (have + fetches.map { $0.at..<$0.end }).sorted(by: { $0.lowerBound < $1.lowerBound })
            where span.lowerBound <= end {
                end = max(end, span.upperBound)
            }
            return end
        }

        func keep(_ data: Data, at offset: Int64) {
            guard (try? handle.seek(toOffset: UInt64(offset))) != nil, (try? handle.write(contentsOf: data)) != nil else { return }
            var merged = offset..<offset + Int64(data.count)
            have.removeAll { other in
                guard other.lowerBound <= merged.upperBound, merged.lowerBound <= other.upperBound else { return false }
                merged = min(other.lowerBound, merged.lowerBound)..<max(other.upperBound, merged.upperBound)
                return true
            }
            have.append(merged)
            have.sort { $0.lowerBound < $1.lowerBound }
        }

        func read(_ range: Range<Int64>) -> Data? {
            guard (try? handle.seek(toOffset: UInt64(range.lowerBound))) != nil else { return nil }
            return try? handle.read(upToCount: Int(range.upperBound - range.lowerBound))
        }

        func remove() {
            try? handle.close()
            try? FileManager.default.removeItem(at: path)
        }
    }

    /// One answer to WebKit: the bytes it asked for, from what is kept.
    private final class Load {
        let task: any WKURLSchemeTask
        /// The next byte to send, and the last asked for, if any.
        var at: Int64
        let last: Int64?
        /// Asked as a range (206) or for the whole (200).
        let ranged: Bool
        var answered = false
        var over = false
        /// A piece is on its way out: the next goes after a moment.
        var sending = false

        init(task: any WKURLSchemeTask, at: Int64, last: Int64?, ranged: Bool) {
            self.task = task
            self.at = at
            self.last = last
            self.ranged = ranged
        }
    }

    /// Bytes `at` up to `end` asked of the server, kept as they come.
    private final class Fetch {
        let stored: Stored
        var at: Int64
        var end: Int64
        var task: URLSessionDataTask?

        init(stored: Stored, at: Int64, end: Int64) {
            self.stored = stored
            self.at = at
            self.end = end
        }
    }

    /// AVFoundation reads a file a few bytes at a time (a box's header, a
    /// frame) where a scheme handler gives it, and a request for each would
    /// wait on the server each time: so the server is asked a chunk at a
    /// time, and the next before the reading gets there.
    private static let chunk: Int64 = 8 << 20
    private static let ahead: Int64 = 16 << 20
    /// Bytes this close behind a fetch's front are waited for; further on, a fetch of their own.
    private static let near: Int64 = 1 << 20
    /// Sent from disk this much at a time, a moment apart: a whole film kept
    /// would otherwise be pushed into WebKit at once.
    private static let piece: Int64 = 512 << 10
    // ponytail: whole files let go, least recently used first; one larger
    // than this, still playing, stays until it is not.
    private static let limit: Int64 = 2 << 30

    private let folder: URL = {
        let folder = FileManager.default.temporaryDirectory.appending(path: "Nerda Media", directoryHint: .isDirectory)
        // What a run before kept goes: the addresses it was for have expired anyway.
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }()

    private var files: [URL: Stored] = [:]
    private var loads: [ObjectIdentifier: (load: Load, stored: Stored)] = [:]
    private var fetches: [Int: Fetch] = [:]

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        // The page's cookies, and only those WebKit would send (`cookies`).
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        return URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
    }()

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let address = task.request.url else { return task.didFailWithError(URLError(.badURL)) }
        let url = Self.original(address)
        let asked = Self.range(task.request.value(forHTTPHeaderField: "Range"))
        let load = Load(task: task, at: asked?.first ?? 0, last: asked?.last, ranged: asked != nil)
        if let stored = files[url] {
            stored.loads.append(load)
            loads[ObjectIdentifier(task)] = (load, stored)
            return serve(stored)
        }
        guard let stored = Stored(url: url, path: folder.appending(path: UUID().uuidString)) else {
            return task.didFailWithError(URLError(.cannotCreateFile))
        }
        files[url] = stored
        stored.loads.append(load)
        loads[ObjectIdentifier(task)] = (load, stored)
        var headers = ["Accept": "*/*"]
        // WebKit SPI, as ViewSource asks it: should it go, URLSession's own name.
        if webView.responds(to: NSSelectorFromString("_userAgent")), let agent = webView.value(forKey: "_userAgent") as? String {
            headers["User-Agent"] = agent
        }
        if let referrer = Self.referrer(of: task, in: webView) { headers["Referer"] = referrer }
        Task {
            if let cookie = await Self.cookies(for: url, in: webView) { headers["Cookie"] = cookie }
            stored.headers = headers
            serve(stored)
        }
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {
        guard let (load, stored) = loads[ObjectIdentifier(task)] else { return }
        end(load, of: stored)
    }

    /// Answers from what is kept, and asks the server for what is missing or soon will be.
    private func serve(_ stored: Stored) {
        for load in stored.loads where !load.sending { pump(load, of: stored) }
        guard stored.headers != nil else { return }
        for load in stored.loads where stored.length.map({ load.at < $0 }) ?? true {
            if stored.kept(at: load.at) == nil {
                // On its way within a moment: waited for.
                if stored.fetches.contains(where: { $0.at <= load.at && load.at < min($0.end, $0.at + Self.near) }) { continue }
                // Missed: a step elsewhere. What was on its way for no one near gives way,
                // and one coming up behind stops where this one starts.
                for fetch in stored.fetches {
                    if !stored.loads.contains(where: { $0.at < fetch.end && fetch.at - $0.at <= Self.ahead }) {
                        cancel(fetch)
                    } else if fetch.at < load.at, load.at < fetch.end {
                        fetch.end = load.at
                    }
                }
                fetch(stored, from: load.at)
                continue
            }
            let reach = stored.covered(from: load.at)
            if reach - load.at < Self.ahead, stored.length.map({ reach < $0 }) ?? false,
               !stored.fetches.contains(where: { $0.at < reach && load.at < $0.end }) {
                // The next chunk once this stretch's own has come: two at once would
                // share the line, and the bytes wanted now come at half the speed.
                fetch(stored, from: reach)
            }
        }
    }

    /// Sends a load what is kept from where it is; finishes it once all is sent.
    private func pump(_ load: Load, of stored: Stored) {
        guard !load.over, let length = stored.length else { return }
        let end = min(load.last.map { $0 + 1 } ?? length, length)
        if !load.answered {
            guard load.at < length else { return refuse(load, of: stored, length: length) }
            answer(load, length: length, end: end, type: stored.type)
        }
        if load.at >= end {
            load.task.didFinish()
            return self.end(load, of: stored)
        }
        guard let kept = stored.kept(at: load.at) else { return }
        let upTo = min(kept.upperBound, end, load.at + Self.piece)
        guard let data = stored.read(load.at..<upTo), !data.isEmpty else {
            load.task.didFailWithError(URLError(.cannotOpenFile))
            return self.end(load, of: stored)
        }
        load.task.didReceive(data)
        load.at += Int64(data.count)
        guard load.at < end else {
            load.task.didFinish()
            return self.end(load, of: stored)
        }
        load.sending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(10)) {
            load.sending = false
            self.serve(stored)
        }
    }

    /// From the server, a chunk from `at`, up to what is kept after it.
    private func fetch(_ stored: Stored, from at: Int64) {
        guard let headers = stored.headers else { return }
        let next = stored.have.first { $0.lowerBound > at }?.lowerBound
        let end = min(at + Self.chunk, next ?? .max, stored.length ?? .max)
        var request = URLRequest(url: stored.url, cachePolicy: .reloadIgnoringLocalCacheData)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("bytes=\(at)-\(end - 1)", forHTTPHeaderField: "Range")
        let fetch = Fetch(stored: stored, at: at, end: end)
        let task = session.dataTask(with: request)
        fetch.task = task
        stored.fetches.append(fetch)
        fetches[task.taskIdentifier] = fetch
        task.resume()
    }

    private func cancel(_ fetch: Fetch) {
        fetch.stored.fetches.removeAll { $0 === fetch }
        guard let task = fetch.task else { return }
        fetches[task.taskIdentifier] = nil
        task.cancel()
    }

    private func answer(_ load: Load, length: Int64, end: Int64, type: String?) {
        guard let address = load.task.request.url else { return }
        var headers = ["Content-Type": type ?? "application/octet-stream", "Content-Length": String(end - load.at), "Accept-Ranges": "bytes"]
        if load.ranged { headers["Content-Range"] = "bytes \(load.at)-\(end - 1)/\(length)" }
        load.task.didReceive(HTTPURLResponse(url: address, statusCode: load.ranged ? 206 : 200, httpVersion: "HTTP/1.1", headerFields: headers)!)
        load.answered = true
    }

    /// Asked from past the end.
    private func refuse(_ load: Load, of stored: Stored, length: Int64) {
        if let address = load.task.request.url {
            let headers = ["Content-Range": "bytes */\(length)", "Content-Length": "0"]
            load.task.didReceive(HTTPURLResponse(url: address, statusCode: 416, httpVersion: "HTTP/1.1", headerFields: headers)!)
        }
        load.task.didFinish()
        end(load, of: stored)
    }

    private func end(_ load: Load, of stored: Stored) {
        guard !load.over else { return }
        load.over = true
        loads[ObjectIdentifier(load.task)] = nil
        stored.loads.removeAll { $0 === load }
        stored.used = .now
        trim()
    }

    /// The server gave no range (an error, an expired address, a server
    /// without ranges): every answer waiting fails, and the next asks afresh.
    /// Before anything played, the page's script loads the address itself.
    private func drop(_ stored: Stored, _ error: URLError) {
        for fetch in stored.fetches { cancel(fetch) }
        for load in stored.loads {
            load.task.didFailWithError(error)
            end(load, of: stored)
        }
        if files[stored.url] === stored { files[stored.url] = nil }
        stored.remove()
    }

    private func trim() {
        var total = files.values.reduce(0) { $0 + $1.size }
        for stored in files.values.sorted(by: { $0.used < $1.used })
        where total > Self.limit && stored.loads.isEmpty && stored.fetches.isEmpty {
            total -= stored.size
            stored.remove()
            files[stored.url] = nil
        }
    }

    nonisolated func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                                completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        let allowed = MainActor.assumeIsolated { received(response, for: dataTask) }
        completionHandler(allowed ? .allow : .cancel)
    }

    nonisolated func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        MainActor.assumeIsolated {
            guard let fetch = fetches[dataTask.taskIdentifier] else { return }
            let data = data.prefix(Int(fetch.end - fetch.at))
            fetch.stored.keep(data, at: fetch.at)
            fetch.at += Int64(data.count)
            for load in fetch.stored.loads where !load.sending { pump(load, of: fetch.stored) }
            // Cut short by a fetch started further on, which has the rest.
            if fetch.at >= fetch.end {
                cancel(fetch)
                serve(fetch.stored)
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        MainActor.assumeIsolated {
            guard let fetch = fetches.removeValue(forKey: task.taskIdentifier) else { return }
            let stored = fetch.stored
            stored.fetches.removeAll { $0 === fetch }
            // The line dropped, or nothing came of asking (asking again would go round
            // for ever): what waited on this fetch fails, as a load of WebKit's own
            // would, and what is kept stays for the next ask.
            if error != nil || task.countOfBytesReceived == 0 {
                let failure = (error as? URLError) ?? URLError(.zeroByteResource)
                for load in stored.loads where fetch.at <= load.at && load.at < fetch.end && stored.kept(at: load.at) == nil {
                    load.task.didFailWithError(failure)
                    end(load, of: stored)
                }
                return
            }
            serve(stored)
        }
    }

    /// The server's answer to a fetch: the range asked for, or the file is dropped.
    private func received(_ response: URLResponse, for task: URLSessionDataTask) -> Bool {
        guard let fetch = fetches[task.taskIdentifier] else { return false }
        let stored = fetch.stored
        guard let http = response as? HTTPURLResponse, http.statusCode == 206,
              let range = Self.contentRange(http.value(forHTTPHeaderField: "Content-Range")), range.start == fetch.at else {
            drop(stored, URLError(.resourceUnavailable))
            return false
        }
        stored.length = range.length
        stored.type = http.value(forHTTPHeaderField: "Content-Type") ?? stored.type
        fetch.end = min(fetch.end, range.length)
        for load in stored.loads where !load.sending { pump(load, of: stored) }
        return true
    }

    /// `bytes=first-` or `bytes=first-last`, as WebKit asks.
    nonisolated static func range(_ header: String?) -> (first: Int64, last: Int64?)? {
        guard let header, header.hasPrefix("bytes=") else { return nil }
        let parts = header.dropFirst(6).split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, let first = Int64(parts[0]) else { return nil }
        if parts[1].isEmpty { return (first, nil) }
        guard let last = Int64(parts[1]), last >= first else { return nil }
        return (first, last)
    }

    /// `bytes start-end/length`, as servers answer a range.
    nonisolated static func contentRange(_ header: String?) -> (start: Int64, length: Int64)? {
        guard let header, header.hasPrefix("bytes ") else { return nil }
        let parts = header.dropFirst(6).split(separator: "/")
        guard parts.count == 2, let length = Int64(parts[1]),
              let start = parts[0].split(separator: "-").first.flatMap({ Int64($0) }) else { return nil }
        return (start, length)
    }

    /// The origin of the frame that asked, as WebKit sends it to another
    /// origin by default; the tab's, should the SPI (`_frame`) go.
    private static func referrer(of task: any WKURLSchemeTask, in page: WKWebView) -> String? {
        let frame = (task as? NSObject).flatMap {
            $0.responds(to: NSSelectorFromString("_frame")) ? $0.value(forKey: "_frame") as? WKFrameInfo : nil
        }
        if let origin = frame?.securityOrigin, !origin.host.isEmpty {
            return "\(origin.protocol)://\(origin.host)\(origin.port == 0 ? "" : ":\(origin.port)")/"
        }
        guard let url = page.url, let scheme = url.scheme, let host = url.host() else { return nil }
        return "\(scheme)://\(host)\(url.port.map { ":\($0)" } ?? "")/"
    }

    /// The cookies WebKit would send with it: none to another site than the
    /// tab's, as WebKit blocks those, and of the tab's site those whose
    /// domain and path match.
    private static func cookies(for url: URL, in page: WKWebView) async -> String? {
        guard let host = url.host()?.lowercased(), let top = page.url?.host(),
              Site.of(host) == Site.of(top) else { return nil }
        let path = url.path().isEmpty ? "/" : url.path()
        let matching = await page.configuration.websiteDataStore.httpCookieStore.allCookies().filter { cookie in
            let domain = cookie.domain.lowercased()
            let domainMatches = domain.hasPrefix(".") ? host == domain.dropFirst() || host.hasSuffix(domain) : host == domain
            return domainMatches && path.hasPrefix(cookie.path) && (cookie.expiresDate.map { $0 > .now } ?? true)
        }
        return HTTPCookie.requestHeaderFields(with: matching)["Cookie"]
    }
}
