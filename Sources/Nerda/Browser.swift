import Foundation
import Observation

struct Tab: Identifiable, Equatable {
    let id = UUID()
    var url: URL
    var title: String

    init(url: URL) {
        self.url = url
        // Until the page can say its own title: the site's name.
        let host = url.host(percentEncoded: false) ?? url.absoluteString
        title = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

/// One browser window: its tabs, newest first, which one is showing, and what
/// is open around them. A tab only exists once there is somewhere to go, so
/// there are no empty "New Tab" tabs.
@Observable
final class Browser {
    private(set) var tabs: [Tab] = []
    var selectedID: Tab.ID?
    var sidebarOpen = true
    /// Open at launch too: there are no tabs until you say where to go.
    var commandBarOpen = true

    var selected: Tab? { tabs.first { $0.id == selectedID } }

    func open(_ url: URL) {
        let tab = Tab(url: url)
        tabs.insert(tab, at: 0)
        selectedID = tab.id
    }

    /// Closing the tab on screen hands the screen to the one that slides into
    /// its place, or to the one above when there is none below, as browsers do.
    func close(_ id: Tab.ID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs.remove(at: index)
        if selectedID == id {
            selectedID = tabs.indices.contains(index) ? tabs[index].id : tabs.last?.id
        }
    }
}

/// What was typed, as somewhere to go: an address as it is, anything else
/// as a Google search.
nonisolated enum Address {
    static func url(from input: String) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if text.contains("://") { return URL(string: text) }

        let host = text.split(separator: "/", maxSplits: 1).first.map(String.init) ?? text
        let looksLikeAddress = !text.contains(" ") && (host.contains(".") || host.hasPrefix("localhost"))
        if looksLikeAddress, let url = URL(string: (host.hasPrefix("localhost") ? "http://" : "https://") + text) {
            return url
        }

        var search = URLComponents(string: "https://www.google.com/search")!
        search.queryItems = [URLQueryItem(name: "q", value: text)]
        return search.url
    }
}
