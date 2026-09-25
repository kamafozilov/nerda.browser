import SwiftUI
import WebKit

/// Responsive Design Mode: the page as a phone, a tablet or another screen
/// shows it, at that screen's width and height, and saying it is the browser
/// that screen would have, so sites send their mobile pages.
struct Responsive: Equatable {
    var width: CGFloat
    var height: CGFloat
    /// The device picked; nil once its size is changed by hand.
    var device: String?
    /// The browser it says it is; nil for Nerda's own.
    var agent: String?

    init(_ device: Device) {
        width = device.width
        height = device.height
        self.device = device.name
        agent = device.agent
    }

    /// Where Responsive Design Mode opens, as in Chrome: no device, only the
    /// room the page has, less the bar and the margin round it, as Nerda.
    init(fitting tab: Tab) {
        let room = tab.page?.superview?.bounds.size ?? CGSize(width: 1280, height: 800)
        let bar = tab.responsive == nil ? ResponsiveBar.height : 0
        width = max((room.width - 2 * PageStage.margin).rounded(.down), 50)
        height = max((room.height - bar - 2 * PageStage.margin).rounded(.down), 50)
    }

    var size: CGSize { CGSize(width: width, height: height) }
}

struct Device: Hashable {
    let name: String
    let width: CGFloat
    let height: CGFloat
    var agent: String?

    // Safari on an iPad says it is a Mac, and so does Nerda.
    static let iPhoneAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1"
    static let androidAgent = "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Mobile Safari/537.36"

    /// Each screen's size in CSS pixels, as its browser lays pages out.
    static let groups: [(name: String, devices: [Device])] = [
        ("Phones", [
            Device(name: "iPhone SE", width: 375, height: 667, agent: iPhoneAgent),
            Device(name: "iPhone 17", width: 402, height: 874, agent: iPhoneAgent),
            Device(name: "iPhone Air", width: 420, height: 912, agent: iPhoneAgent),
            Device(name: "iPhone 17 Pro Max", width: 440, height: 956, agent: iPhoneAgent),
            Device(name: "Android Phone", width: 412, height: 915, agent: androidAgent),
        ]),
        ("Tablets", [
            Device(name: "iPad mini", width: 744, height: 1133),
            Device(name: "iPad Air 11″", width: 820, height: 1180),
            Device(name: "iPad Pro 13″", width: 1032, height: 1376),
        ]),
        ("Computers", [
            Device(name: "Laptop", width: 1280, height: 800),
            Device(name: "Laptop L", width: 1440, height: 900),
            Device(name: "Desktop", width: 1920, height: 1080),
        ]),
    ]

}

/// Over the page in Responsive Design Mode: which device, its size (typed
/// in, or turned on its side), and the way out.
struct ResponsiveBar: View {
    let tab: Tab
    let responsive: Responsive

    static let height: CGFloat = 36

    var body: some View {
        HStack(spacing: 10) {
            DevicePicker(tab: tab, responsive: responsive)

            HStack(spacing: 4) {
                SizeField(value: responsive.width) { tab.resize(width: $0) }
                Text("×").foregroundStyle(Palette.muted)
                SizeField(value: responsive.height) { tab.resize(height: $0) }
            }

            BarButton(icon: "rectangle.portrait.rotate", help: "Rotate") {
                tab.resize(width: responsive.height, height: responsive.width)
            }

            Spacer(minLength: 0)

            BarButton(icon: "xmark", help: "Exit Responsive Design Mode") { tab.responsive = nil }
        }
        .font(.system(size: 12))
        .foregroundStyle(Palette.ink)
        .padding(.horizontal, 12)
        .frame(height: Self.height)
        .background(Palette.ground)
        .overlay(alignment: .bottom) { Palette.hairline.frame(height: 1) }
    }
}

/// Which device the page is shown as: its name, and a chevron set apart,
/// lit under the pointer as the bar's other buttons are. In the menu, each
/// device with its size under its name.
private struct DevicePicker: View {
    let tab: Tab
    let responsive: Responsive

    @State private var hovering = false

    var body: some View {
        Menu {
            Toggle(isOn: Binding(get: { responsive.device == nil }, set: { _ in tab.responsive = Responsive(fitting: tab) })) {
                Text("Responsive")
                Text("The size the page has room for")
            }
            ForEach(Device.groups, id: \.name) { group in
                Section(group.name) {
                    ForEach(group.devices, id: \.self) { device in
                        Toggle(isOn: Binding(get: { responsive.device == device.name }, set: { _ in tab.responsive = Responsive(device) })) {
                            Text(device.name)
                            // Verbatim: 1 133 would otherwise be grouped by the locale.
                            Text(verbatim: "\(Int(device.width)) × \(Int(device.height))")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(responsive.device ?? "Responsive")
                    .foregroundStyle(Palette.ink)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Palette.muted)
            }
            .padding(.leading, 9)
            .padding(.trailing, 8)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hovering ? Palette.hover : .clear))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Choose a Device")
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.14), value: hovering)
    }
}

/// A width or a height, in CSS pixels: taken once Return is pressed or the field is left.
private struct SizeField: View {
    let value: CGFloat
    let commit: (CGFloat) -> Void

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain)
            .multilineTextAlignment(.center)
            .monospacedDigit()
            .focused($focused)
            .frame(width: 44, height: 22)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Palette.hover))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Palette.hairline))
            .onAppear { text = "\(Int(value))" }
            .onChange(of: value) { text = "\(Int(value))" }
            .onSubmit(take)
            .onChange(of: focused) { if !focused { take() } }
    }

    /// Between 50 and 4000; anything else goes back to what it was.
    private func take() {
        guard let number = Double(text.trimmingCharacters(in: .whitespaces)), (50...4000).contains(number) else {
            text = "\(Int(value))"
            return
        }
        if CGFloat(number.rounded()) != value { commit(CGFloat(number.rounded())) }
    }
}

/// Where a page sits in its `PageSlot`: all of it, or in Responsive Design
/// Mode, a device's screen at the top, scaled down to fit when it is larger.
/// WebKit's inspector docks beside this rather than beside the page, so it
/// keeps the card's width whatever the page's.
final class PageStage: NSView {
    var device: CGSize? {
        didSet { if device != oldValue { place() } }
    }
    /// Under the device's screen: its shadow, and ground while the page is see-through.
    private let screen = NSView()
    static let margin: CGFloat = 16

    init() {
        super.init(frame: .zero)
        screen.wantsLayer = true
        screen.isHidden = true
        addSubview(screen)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func resizeSubviews(withOldSize oldSize: NSSize) { place() }

    /// Put here by PageView, or back by WebKit from its full screen.
    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        if subview is WKWebView { place() }
    }

    /// None while WebKit has it in its own full screen.
    private var page: WKWebView? { subviews.lazy.compactMap { $0 as? WKWebView }.first }

    func place() {
        guard let page else { return }
        guard let device else {
            screen.isHidden = true
            Self.scale(page, 1)
            page.frame = bounds
            return
        }
        let room = CGSize(width: bounds.width - 2 * Self.margin, height: bounds.height - 2 * Self.margin)
        let scale = max(min(1, room.width / device.width, room.height / device.height), 0.1)
        let size = CGSize(width: (device.width * scale).rounded(), height: (device.height * scale).rounded())
        // Scaled down, the page still lays out at the device's width.
        Self.scale(page, scale)
        page.frame = CGRect(x: ((bounds.width - size.width) / 2).rounded(), y: bounds.height - Self.margin - size.height,
                            width: size.width, height: size.height)
        screen.frame = page.frame
        screen.isHidden = false
        effectiveAppearance.performAsCurrentDrawingAppearance {
            screen.layer?.backgroundColor = NSColor(Palette.ground).cgColor
        }
        screen.shadow = {
            let shadow = NSShadow()
            shadow.shadowColor = .black.withAlphaComponent(0.25)
            shadow.shadowBlurRadius = 14
            shadow.shadowOffset = NSSize(width: 0, height: -3)
            return shadow
        }()
    }

    /// The page drawn at this scale, laid out as `frame ÷ scale` wide, as
    /// Safari's Responsive Design Mode does: WebKit's layout mode 2
    /// (`_WKLayoutModeDynamicSizeComputedFromViewScale`); 0 is the frame's own size.
    // WebKit SPI: should it go, a device larger than the card is cut off.
    private static func scale(_ page: WKWebView, _ scale: CGFloat) {
        let mode = NSSelectorFromString("_setLayoutMode:"), setter = NSSelectorFromString("_setViewScale:")
        guard page.responds(to: mode), page.responds(to: setter),
              page.value(forKey: "_viewScale") as? CGFloat != scale else { return }
        typealias Mode = @convention(c) (AnyObject, Selector, UInt) -> Void
        unsafeBitCast(page.method(for: mode), to: Mode.self)(page, mode, scale == 1 ? 0 : 2)
        typealias Setter = @convention(c) (AnyObject, Selector, CGFloat) -> Void
        unsafeBitCast(page.method(for: setter), to: Setter.self)(page, setter, scale)
    }
}

extension Tab {
    /// A size typed in: no longer a device's, though still its browser.
    /// Turned on its side, still the device.
    func resize(width: CGFloat? = nil, height: CGFloat? = nil) {
        guard var responsive else { return }
        responsive.width = width ?? responsive.width
        responsive.height = height ?? responsive.height
        let size = [responsive.width, responsive.height]
        responsive.device = Device.groups.flatMap(\.devices).first {
            $0.agent == responsive.agent && ([$0.width, $0.height] == size || [$0.height, $0.width] == size)
        }?.name
        self.responsive = responsive
    }

    /// The cookies, storage, cache and service workers of the page's site
    /// (its domain, subdomains included), and nothing of any other site's;
    /// then the page again, as it is without them.
    func clearSiteData() async {
        guard let host = site?.host(percentEncoded: false)?.lowercased() else { return }
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        // WebKit keeps them by domain: example.com's hold www.example.com's too.
        let records = await dataStore.dataRecords(ofTypes: types)
            .filter { host == $0.displayName || host.hasSuffix("." + $0.displayName) }
        await dataStore.removeData(ofTypes: types, for: records)
        reload()
    }
}

/// view-source: pages, as in Chrome and Safari: the HTML a site sends, as it
/// sent it, fetched again with the page's cookies, numbered by line and
/// coloured; its links go to their own sources.
final class ViewSource: NSObject, WKURLSchemeHandler {
    static let scheme = "view-source"
    static let handler = ViewSource()

    static func url(for page: URL) -> URL? { URL(string: "\(scheme):\(page.absoluteString)") }

    /// Answers not yet sent, which WebKit may call off (the tab closed, or went elsewhere).
    private var running: Set<ObjectIdentifier> = []

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        let id = ObjectIdentifier(task)
        running.insert(id)
        guard let url = task.request.url else { return }
        Task {
            let page = URL(string: String(url.absoluteString.dropFirst(Self.scheme.count + 1)))
            let body: [String: String]
            if let page, page.scheme.map({ ["http", "https", "file"].contains($0.lowercased()) }) == true {
                do {
                    body = ["url": page.absoluteString, "source": try await Self.source(of: page, as: webView)]
                } catch {
                    body = ["url": page.absoluteString, "error": error.localizedDescription]
                }
            } else {
                body = ["url": page?.absoluteString ?? "", "error": "Only a web page or a file has a source to show."]
            }
            guard running.remove(id) != nil else { return }
            let data = Self.page(body)
            task.didReceive(URLResponse(url: url, mimeType: "text/html", expectedContentLength: data.count, textEncodingName: "utf-8"))
            task.didReceive(data)
            task.didFinish()
        }
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {
        running.remove(ObjectIdentifier(task))
    }

    /// The page's HTML, in the encoding the site says it is in.
    private static func source(of url: URL, as page: WKWebView) async throws -> String {
        let data: Data
        var encoding: String.Encoding?
        if url.isFileURL {
            data = try Data(contentsOf: url)
        } else {
            // The page's cookies and its browser's name, so a site signed in
            // to sends the page it showed, not its sign-in page.
            let configuration = URLSessionConfiguration.ephemeral
            for cookie in await page.configuration.websiteDataStore.httpCookieStore.allCookies() {
                configuration.httpCookieStorage?.setCookie(cookie)
            }
            let session = URLSession(configuration: configuration)
            defer { session.finishTasksAndInvalidate() }
            var request = URLRequest(url: url)
            // WebKit SPI: should it go, sites are told URLSession's name.
            if page.responds(to: NSSelectorFromString("_userAgent")), let agent = page.value(forKey: "_userAgent") as? String {
                request.setValue(agent, forHTTPHeaderField: "User-Agent")
            }
            let response: URLResponse
            (data, response) = try await session.data(for: request)
            if let name = response.textEncodingName {
                let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
                if cf != kCFStringEncodingInvalidId { encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf)) }
            }
        }
        return encoding.flatMap { String(data: data, encoding: $0) } ?? String(decoding: data, as: UTF8.self)
    }

    /// The viewer, with what it shows in it as JSON. Every `<` in it escaped,
    /// so no source can end the script it is in.
    private static func page(_ body: [String: String]) -> Data {
        let json = (try? JSONEncoder().encode(body)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return Data((viewer.replacing("/*DATA*/", with: json.replacing("<", with: "\\u003c"))).utf8)
    }

    private static let viewer = #"""
        <!doctype html>
        <html><head><meta charset="utf-8"><meta name="color-scheme" content="light dark"><title>Source</title>
        <style>
        :root { --bg: #fff; --fg: #1f1f1f; --muted: #9a9a9e; --line: rgba(0,0,0,.08); --bar: rgba(246,246,246,.85);
                --tag: #881280; --attr: #994500; --value: #1a1aa6; --comment: #236e25; --doctype: #8a8a8e; }
        @media (prefers-color-scheme: dark) {
            :root { --bg: #1c1c1e; --fg: #e3e3e3; --muted: #6e6e73; --line: rgba(255,255,255,.1); --bar: rgba(44,44,46,.85);
                    --tag: #5db0d7; --attr: #9bbbdc; --value: #f29766; --comment: #898989; --doctype: #7f7f84; }
        }
        html { background: var(--bg); color: var(--fg); }
        body { margin: 0; font: 12px/1.6 ui-monospace, "SF Mono", Menlo, monospace; }
        main { padding: 10px 0 32px; counter-reset: line; width: max-content; min-width: 100%; box-sizing: border-box; }
        body.wrap main { width: auto; }
        .line { display: flex; }
        .line:hover { background: var(--line); }
        .line::before { counter-increment: line; content: counter(line); flex: none; width: var(--digits);
                        padding: 0 16px 0 14px; text-align: right; color: var(--muted); user-select: none; }
        .code { white-space: pre; min-width: 0; padding-right: 16px; }
        body.wrap .code { white-space: pre-wrap; overflow-wrap: anywhere; }
        .tag { color: var(--tag); } .attr { color: var(--attr); } .value { color: var(--value); }
        .comment { color: var(--comment); } .doctype { color: var(--doctype); }
        a.value { text-decoration: underline; text-decoration-color: color-mix(in srgb, currentColor 35%, transparent); }
        label { position: fixed; top: 10px; right: 14px; display: flex; gap: 6px; align-items: center; padding: 5px 10px;
                font: 12px system-ui; border-radius: 8px; background: var(--bar); border: 1px solid var(--line);
                -webkit-backdrop-filter: blur(20px); backdrop-filter: blur(20px); user-select: none; }
        label input { margin: 0; }
        .error { padding: 48px; font: 13px system-ui; color: var(--muted); text-align: center; width: auto; }
        </style></head>
        <body>
        <label><input type="checkbox" id="wrap"> Wrap Lines</label>
        <main></main>
        <script type="application/json" id="data">/*DATA*/</script>
        <script>
        const { url, source, error } = JSON.parse(document.getElementById('data').textContent);
        document.title = 'view-source:' + url;
        const main = document.querySelector('main');

        const wrap = document.getElementById('wrap');
        try { wrap.checked = localStorage.wrap === '1'; } catch {}
        const wrapped = () => document.body.classList.toggle('wrap', wrap.checked);
        wrap.onchange = () => { wrapped(); try { localStorage.wrap = wrap.checked ? '1' : '0'; } catch {} };
        wrapped();

        if (error) {
            main.className = 'error';
            main.textContent = error;
        } else {
            show(source.replace(/\r\n?/g, '\n'));
        }

        // The HTML in pieces: tags, their attributes and values, comments and
        // doctypes; script and style bodies as they are. Each line its own row.
        function show(text) {
            const lower = text.toLowerCase();
            const lines = [[]];
            const push = (kind, piece, link) => piece.split('\n').forEach((part, index) => {
                if (index) lines.push([]);
                if (part) lines[lines.length - 1].push([kind, part, link]);
            });
            const match = (pattern, at) => { pattern.lastIndex = at; return pattern.exec(text)?.[0]; };
            const tagStart = /<(\/?)([a-zA-Z][^\s\/>]*)/y, space = /\s+/y, name = /[^\s"'>\/=]+/y,
                  equals = /\s*=\s*/y, value = /"[^"]*"?|'[^']*'?|[^\s>]+/y;
            const rawText = new Set(['script', 'style', 'textarea', 'title', 'xmp', 'iframe', 'noembed', 'noframes', 'plaintext']);
            const linked = new Set(['href', 'src']);
            const link = quoted => {
                try {
                    const target = new URL(quoted.replace(/^["']|["']$/g, '').trim(), url);
                    return /^(https?|file):$/.test(target.protocol) ? 'view-source:' + target.href : null;
                } catch { return null; }
            };
            let at = 0;
            while (at < text.length) {
                let found;
                if (text.startsWith('<!--', at)) {
                    const end = text.indexOf('-->', at + 4), stop = end < 0 ? text.length : end + 3;
                    push('comment', text.slice(at, stop));
                    at = stop;
                } else if (text.startsWith('<!', at) || text.startsWith('<?', at)) {
                    const end = text.indexOf('>', at), stop = end < 0 ? text.length : end + 1;
                    push('doctype', text.slice(at, stop));
                    at = stop;
                } else if ((tagStart.lastIndex = at, found = tagStart.exec(text))) {
                    push('tag', found[0]);
                    at += found[0].length;
                    const tag = found[2].toLowerCase(), closing = found[1] === '/';
                    let attribute = null;
                    while (at < text.length) {
                        let piece;
                        if (text[at] === '>') { push('tag', '>'); at += 1; break; }
                        if (text.startsWith('/>', at)) { push('tag', '/>'); at += 2; break; }
                        if ((piece = match(space, at))) { push('', piece); at += piece.length; continue; }
                        if (attribute && (piece = match(equals, at))) {
                            push('', piece);
                            at += piece.length;
                            if ((piece = match(value, at))) {
                                push('value', piece, linked.has(attribute) ? link(piece) : null);
                                at += piece.length;
                            }
                            attribute = null;
                            continue;
                        }
                        if ((piece = match(name, at))) { push('attr', piece); attribute = piece.toLowerCase(); at += piece.length; continue; }
                        push('tag', text[at]);
                        at += 1;
                        attribute = null;
                    }
                    if (!closing && rawText.has(tag)) {
                        const end = lower.indexOf('</' + tag, at), stop = end < 0 ? text.length : end;
                        push('', text.slice(at, stop));
                        at = stop;
                    }
                } else {
                    const next = text.indexOf('<', at + 1), stop = next < 0 ? text.length : next;
                    push('', text.slice(at, stop));
                    at = stop;
                }
            }
            const rows = document.createDocumentFragment();
            for (const line of lines) {
                const row = document.createElement('div'), code = document.createElement('span');
                row.className = 'line';
                code.className = 'code';
                for (const [kind, part, target] of line) {
                    if (!kind) { code.append(part); continue; }
                    const piece = document.createElement(target ? 'a' : 'span');
                    piece.className = kind;
                    piece.textContent = part;
                    if (target) piece.href = target;
                    code.append(piece);
                }
                row.append(code);
                rows.append(row);
            }
            main.style.setProperty('--digits', String(lines.length).length + 'ch');
            main.append(rows);
        }
        </script>
        </body></html>
        """#
}

/// A JSON answer (an API's), shown as a tree to fold and unfold, as Firefox
/// does, rather than as one long line: coloured, with each object's keys and
/// each array's items counted, and its links to follow. Raw shows it as sent,
/// and Copy copies that. Only a page that is all JSON, and JSON that reads.
enum JSONViewer {
    static let script = WKUserScript(source: #"""
        (() => {
            if (!/^(application|text)\/([\w.-]+\+)?json$/i.test(document.contentType || '')) return;
            const body = document.body, pre = body?.firstElementChild;
            if (!pre || pre.tagName !== 'PRE' || body.children.length !== 1) return;
            const raw = pre.textContent;
            let data;
            try { data = JSON.parse(raw); } catch { return; }

            // A sheet made here, not a <style>: an API's CSP (GitHub's) turns those away.
            const sheet = new CSSStyleSheet();
            sheet.replaceSync(`
                :root { color-scheme: light dark; --bg: #fff; --fg: #1f1f1f; --muted: #8a8a8e; --line: rgba(0,0,0,.08);
                        --hover: rgba(0,0,0,.035); --bar: rgba(246,246,246,.85); --button: rgba(0,0,0,.06); --on: #fff;
                        --key: #0451a5; --string: #a31515; --number: #098658; --literal: #0000ff; }
                @media (prefers-color-scheme: dark) {
                    :root { --bg: #1c1c1e; --fg: #e3e3e3; --muted: #8e8e93; --line: rgba(255,255,255,.1);
                            --hover: rgba(255,255,255,.04); --bar: rgba(44,44,46,.85); --button: rgba(255,255,255,.08);
                            --on: rgba(255,255,255,.18); --key: #9cdcfe; --string: #ce9178; --number: #b5cea8; --literal: #569cd6; }
                }
                html { background: var(--bg); color: var(--fg); }
                body { margin: 0; }
                .jv-bar { position: sticky; top: 0; z-index: 1; display: flex; align-items: center; gap: 4px; padding: 7px 12px;
                          font: 12px system-ui; background: var(--bar); border-bottom: 1px solid var(--line);
                          -webkit-backdrop-filter: saturate(1.8) blur(20px); backdrop-filter: saturate(1.8) blur(20px); }
                .jv-bar button { font: inherit; color: var(--fg); background: none; border: 0; border-radius: 6px; padding: 4px 10px; }
                .jv-bar button:hover { background: var(--button); }
                .jv-tabs { display: flex; padding: 2px; border-radius: 8px; background: var(--button); margin-right: 8px; }
                .jv-tabs button { padding: 3px 12px; }
                .jv-tabs button.jv-on, .jv-tabs button.jv-on:hover { background: var(--on); box-shadow: 0 1px 2px rgba(0,0,0,.15); }
                .jv-spacer { flex: 1; }
                .jv-tree, .jv-raw { margin: 0; padding: 10px 16px 32px; font: 12px/1.65 ui-monospace, "SF Mono", Menlo, monospace; }
                .jv-raw { white-space: pre-wrap; overflow-wrap: anywhere; }
                .jv-line { position: relative; padding-left: 16px; border-radius: 4px; white-space: pre-wrap; overflow-wrap: anywhere; }
                .jv-line:hover { background: var(--hover); }
                .jv-toggle { position: absolute; left: 0; width: 14px; text-align: center; color: var(--muted); user-select: none; }
                .jv-toggle::before { content: '▶'; display: inline-block; font-size: 8px; transition: transform .12s; }
                .jv-node:not(.jv-collapsed) > .jv-line > .jv-toggle::before { transform: rotate(90deg); }
                .jv-children { margin-left: 7px; padding-left: 13px; border-left: 1px solid var(--line); }
                .jv-collapsed > .jv-children, .jv-collapsed > .jv-close, .jv-fold { display: none; }
                .jv-collapsed > .jv-line > .jv-fold { display: inline; }
                .jv-key { color: var(--key); } .jv-string { color: var(--string); } .jv-number { color: var(--number); }
                .jv-literal { color: var(--literal); } .jv-punct { color: var(--muted); }
                .jv-string a { color: inherit; text-decoration-color: color-mix(in srgb, currentColor 40%, transparent); }
                .jv-count { margin-left: 8px; color: var(--muted); font: 11px system-ui; user-select: none; }
                [hidden] { display: none !important; }
            `);
            document.adoptedStyleSheets = [...document.adoptedStyleSheets, sheet];

            const element = (tag, kind, text) => {
                const made = document.createElement(tag);
                if (kind) made.className = kind;
                if (text != null) made.textContent = text;
                return made;
            };
            const isContainer = value => value !== null && typeof value === 'object';
            const count = value => Array.isArray(value) ? value.length : Object.keys(value).length;

            const scalar = value => {
                if (typeof value !== 'string') {
                    return element('span', typeof value === 'number' ? 'jv-number' : 'jv-literal', String(value));
                }
                const shown = element('span', 'jv-string');
                const quoted = JSON.stringify(value);
                if (/^https?:\/\/\S+$/.test(value)) {
                    const link = element('a', null, quoted.slice(1, -1));
                    link.href = value;
                    shown.append('"', link, '"');
                } else {
                    shown.textContent = quoted;
                }
                return shown;
            };

            // One value: a line of its own, or for an object or array with
            // anything in it, its first line, its insides (made once it is
            // first opened) and its last.
            const node = (value, key, comma) => {
                const box = element('div', 'jv-node'), head = element('div', 'jv-line');
                if (key !== undefined) head.append(element('span', 'jv-key', JSON.stringify(key)), element('span', 'jv-punct', ': '));
                if (!isContainer(value) || !count(value)) {
                    head.append(isContainer(value) ? element('span', 'jv-punct', Array.isArray(value) ? '[]' : '{}') : scalar(value));
                    if (comma) head.append(element('span', 'jv-punct', ','));
                    box.append(head);
                    return box;
                }
                const array = Array.isArray(value), size = count(value), [open, close] = array ? ['[', ']'] : ['{', '}'];
                box.classList.add('jv-collapsed');
                box.value = value;
                head.classList.add('jv-open');
                head.prepend(element('span', 'jv-toggle'));
                head.append(element('span', 'jv-punct', open), element('span', 'jv-punct jv-fold', ' … ' + close + (comma ? ',' : '')),
                            element('span', 'jv-count jv-fold', size + ' ' + (array ? (size === 1 ? 'item' : 'items') : (size === 1 ? 'key' : 'keys'))));
                const last = element('div', 'jv-line jv-close');
                last.append(element('span', 'jv-punct', close + (comma ? ',' : '')));
                box.append(head, element('div', 'jv-children'), last);
                return box;
            };

            const expand = box => {
                if (!box.value || !box.classList.contains('jv-collapsed')) return;
                const inside = box.children[1];
                if (!inside.firstChild) {
                    const value = box.value, keys = Array.isArray(value) ? null : Object.keys(value), size = count(value);
                    const nodes = document.createDocumentFragment();
                    for (let index = 0; index < size; index++) {
                        nodes.append(keys ? node(value[keys[index]], keys[index], index < size - 1) : node(value[index], undefined, index < size - 1));
                    }
                    inside.append(nodes);
                }
                box.classList.remove('jv-collapsed');
            };
            const containers = box => [...box.children[1].children].filter(child => child.value);
            const expandAll = box => {
                for (const stack = [box]; stack.length;) {
                    const next = stack.pop();
                    expand(next);
                    stack.push(...containers(next));
                }
            };
            const collapseAll = box => box.querySelectorAll('.jv-node:not(.jv-collapsed)').forEach(inner => {
                if (inner.value) inner.classList.add('jv-collapsed');
            });

            const tree = element('div', 'jv-tree'), rawView = element('pre', 'jv-raw', raw);
            const root = node(data, undefined, false);
            tree.append(root);
            rawView.hidden = true;

            // Open at first as far down as a couple of thousand lines, breadth first.
            let budget = 2000;
            for (const queue = [root]; queue.length;) {
                const box = queue.shift();
                if (!box.value) continue;
                const size = count(box.value);
                if (box !== root && size > budget) break;
                budget -= size;
                expand(box);
                queue.push(...containers(box));
            }

            tree.addEventListener('click', event => {
                const head = event.target.closest('.jv-open');
                if (!head || event.target.closest('a') || getSelection().type === 'Range') return;
                const box = head.parentElement, closed = box.classList.contains('jv-collapsed');
                // ⌥-click opens or closes all inside it too.
                if (event.altKey) { closed ? expandAll(box) : (collapseAll(box), box.classList.add('jv-collapsed')); }
                else if (closed) { expand(box); }
                else { box.classList.add('jv-collapsed'); }
            });

            const bar = element('div', 'jv-bar'), tabs = element('div', 'jv-tabs');
            const button = (title, action) => { const made = element('button', null, title); made.onclick = action; return made; };
            const treeTab = button('JSON', () => show(false)), rawTab = button('Raw', () => show(true));
            const collapseButton = button('Collapse All', () => { collapseAll(root); expand(root); });
            const expandButton = button('Expand All', () => expandAll(root));
            const copyButton = button('Copy', async () => {
                try { await navigator.clipboard.writeText(raw); } catch {
                    const field = element('textarea');
                    field.value = raw;
                    body.append(field);
                    field.select();
                    document.execCommand('copy');
                    field.remove();
                }
                copyButton.textContent = 'Copied';
                setTimeout(() => { copyButton.textContent = 'Copy'; }, 1200);
            });
            const show = asRaw => {
                treeTab.classList.toggle('jv-on', !asRaw);
                rawTab.classList.toggle('jv-on', asRaw);
                tree.hidden = collapseButton.hidden = expandButton.hidden = asRaw;
                rawView.hidden = !asRaw;
            };
            tabs.append(treeTab, rawTab);
            bar.append(tabs, element('span', 'jv-spacer'), collapseButton, expandButton, copyButton);
            show(false);
            body.replaceChildren(bar, tree, rawView);
        })();
        """#, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient)
}
