import AppKit
import WebKit

/// Where what is typed that isn't an address goes, and whose guesses are
/// offered as it is typed. They all answer guesses in the same form (OpenSearch's).
nonisolated enum SearchEngine: String, CaseIterable, Identifiable {
    case google, bing, duckDuckGo, brave, yandex

    static let key = "searchEngine"

    static var current: Self {
        UserDefaults.standard.string(forKey: key).flatMap(Self.init) ?? .google
    }

    var id: Self { self }

    var name: String {
        switch self {
        case .google: "Google"
        case .bing: "Bing"
        case .duckDuckGo: "DuckDuckGo"
        case .brave: "Brave"
        case .yandex: "Yandex"
        }
    }

    /// The site whose icon it is shown with (Brave Search has none of its own).
    var site: URL {
        switch self {
        case .google: URL(string: "https://www.google.com")!
        case .bing: URL(string: "https://www.bing.com")!
        case .duckDuckGo: URL(string: "https://duckduckgo.com")!
        case .brave: URL(string: "https://brave.com")!
        case .yandex: URL(string: "https://yandex.com")!
        }
    }

    func search(_ text: String) -> URL? {
        let (address, name) = switch self {
        case .google: ("https://www.google.com/search", "q")
        case .bing: ("https://www.bing.com/search", "q")
        case .duckDuckGo: ("https://duckduckgo.com/", "q")
        case .brave: ("https://search.brave.com/search", "q")
        case .yandex: ("https://yandex.com/search/", "text")
        }
        var search = URLComponents(string: address)!
        search.queryItems = [URLQueryItem(name: name, value: text)]
        return search.url
    }

    /// Where to ask what it thinks is being typed.
    func guesses(_ text: String) -> URL? {
        let (address, items): (String, [URLQueryItem]) = switch self {
        case .google: ("https://suggestqueries.google.com/complete/search", [
            URLQueryItem(name: "client", value: "firefox"),
            URLQueryItem(name: "ie", value: "utf-8"),
            URLQueryItem(name: "oe", value: "utf-8"),
            URLQueryItem(name: "q", value: text),
        ])
        case .bing: ("https://api.bing.com/osjson.aspx", [URLQueryItem(name: "query", value: text)])
        case .duckDuckGo: ("https://duckduckgo.com/ac/", [URLQueryItem(name: "q", value: text), URLQueryItem(name: "type", value: "list")])
        case .brave: ("https://search.brave.com/api/suggest", [URLQueryItem(name: "q", value: text)])
        case .yandex: ("https://suggest.yandex.com/suggest-ff.cgi", [URLQueryItem(name: "part", value: text)])
        }
        var request = URLComponents(string: address)!
        request.queryItems = items
        return request.url
    }
}

/// A video playing with sound floats over everything when its tab is left,
/// and goes back into its page when the tab is come back to, as in Arc.
enum PictureInPicture {
    static let key = "autoPictureInPicture"

    static var isOn: Bool { UserDefaults.standard.bool(forKey: key) }

    // Run by the app, which counts as a click, as WebKit wants for picture in picture.
    // ponytail: the page's own frame only; a video in an iframe (an embed) stays put.
    static let enter = """
        (() => {
            const playing = [...document.querySelectorAll('video')]
                .filter(v => !v.paused && !v.ended && !v.muted && v.volume > 0 && v.webkitSupportsPresentationMode?.('picture-in-picture'))
                .sort((a, b) => b.clientWidth * b.clientHeight - a.clientWidth * a.clientHeight)[0];
            playing?.webkitSetPresentationMode('picture-in-picture');
        })();
        """

    static let exit = """
        document.querySelectorAll('video').forEach(v => {
            if (v.webkitPresentationMode === 'picture-in-picture') v.webkitSetPresentationMode('inline');
        });
        """
}

/// Copying or saving what the page shows, from its right-click menu.
enum Screenshot {
    static let key = "screenshotInMenu"

    static var isOn: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }

    static func copy(_ page: WKWebView) {
        page.takeSnapshot(with: nil) { image, _ in
            guard let image else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([image])
        }
    }

    static func save(_ page: WKWebView) {
        page.takeSnapshot(with: nil) { image, _ in
            guard let image, let window = page.window,
                  let tiff = image.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.png]
            panel.directoryURL = .downloadsDirectory
            panel.nameFieldStringValue = "Screenshot of \(page.url?.host() ?? "page").png"
            panel.beginSheetModal(for: window) { answer in
                if answer == .OK, let file = panel.url { try? png.write(to: file) }
            }
        }
    }
}

/// Red lines under misspelt words in what is typed into pages. WebKit keeps
/// it on for all of them at once, under this key, and has it off unless told.
enum SpellCheck {
    static let key = "WebContinuousSpellCheckingEnabled"

    /// On by default, as in Safari; read by WebKit when it first checks.
    static func registerDefault() {
        UserDefaults.standard.register(defaults: [key: true])
    }

    /// WebKit changes it only through a page's Check Spelling While Typing,
    /// and tells only that page's process: each open page is told in turn.
    // ponytail: flips pages already told back and forth to reach their processes;
    // WebKit has no other public way to tell them.
    static func set(_ on: Bool, pages: [WKWebView]) {
        let toggle = NSSelectorFromString("toggleContinuousSpellChecking:")
        for page in pages.isEmpty ? [WKWebView()] : pages {
            let item = NSMenuItem(title: "", action: toggle, keyEquivalent: "")
            _ = page.validateUserInterfaceItem(item)
            if (item.state == .on) == on { page.perform(toggle, with: nil) }
            page.perform(toggle, with: nil)
        }
    }
}

/// The language sites are asked for their pages in. WebKit tells them only
/// one, the app's first, which it reads at launch.
enum PreferredLanguage {
    /// The Mac's own languages, in its order.
    static var system: [String] {
        CFPreferencesCopyValue("AppleLanguages" as CFString, kCFPreferencesAnyApplication,
                               kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String] ?? ["en-US"]
    }

    /// The one sites are told this run.
    static let current = Locale.preferredLanguages.first ?? "en-US"

    /// Nerda's own list, which sites are told the first of from the next launch on.
    static var chosen: [String] {
        UserDefaults.standard.stringArray(forKey: "AppleLanguages") ?? [current]
    }

    /// The Mac's own list is no choice at all, so Nerda follows the Mac again.
    static func save(_ languages: [String]) {
        if languages == system {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set(languages, forKey: "AppleLanguages")
        }
    }

    static func name(_ language: String) -> String {
        Locale.current.localizedString(forIdentifier: language) ?? language
    }

    /// Every language with a two-letter code, by name.
    static let all: [String] = Locale.availableIdentifiers
        .filter { $0.count == 2 }
        .sorted { name($0).localizedStandardCompare(name($1)) == .orderedAscending }
}

/// How Nerda looks: as the Mac does, or always light or dark. An incognito
/// window stays dark whatever is chosen (see `BrowserWindow`).
enum Theme: String, CaseIterable {
    case system, light, dark

    static let key = "theme"

    var name: String { rawValue.capitalized }

    var symbol: String {
        switch self {
        case .system: "display"
        case .light: "sun.max"
        case .dark: "moon"
        }
    }

    /// At launch, and on every change: each window follows the app's appearance.
    static func apply() {
        let theme = UserDefaults.standard.string(forKey: key).flatMap(Self.init) ?? .system
        NSApp.appearance = switch theme {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

/// The zoom pages open at, which ⌘0 goes back to. ⌘+ and ⌘− step one tab
/// through the same levels, as Safari's.
enum PageZoom {
    static let key = "pageZoom"

    static let levels: [CGFloat] = [0.5, 0.67, 0.75, 0.85, 1, 1.15, 1.25, 1.5, 1.75, 2, 2.5, 3]

    static var current: CGFloat {
        let zoom = UserDefaults.standard.double(forKey: key)
        return zoom > 0 ? zoom : 1
    }

    static func name(_ zoom: CGFloat) -> String { "\(Int((zoom * 100).rounded()))%" }
}

/// Where the tabs are: down a sidebar, or across the top of the window (`TabStrip`).
enum TabStyle: String, CaseIterable {
    case vertical, horizontal

    static let key = "tabStyle"

    static var current: Self { UserDefaults.standard.string(forKey: key).flatMap(Self.init) ?? .vertical }

    var name: String { rawValue.capitalized }

    /// The title bar is as tall as the row the traffic lights sit on: the
    /// sidebar's top row, level with the address bar (52 pt), or the tab strip (40 pt).
    var toolbarStyle: NSWindow.ToolbarStyle { self == .horizontal ? .unifiedCompact : .unified }
}

/// How much of the desktop shows through the window's glass: all the
/// system's sidebar glass lets through, or tinted, most of the way to solid.
enum Transparency: String, CaseIterable {
    case tinted, transparent

    static let key = "transparency"

    var name: String { rawValue.capitalized }
}
