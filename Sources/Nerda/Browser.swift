import Foundation
import Observation

struct Tab: Identifiable, Equatable {
    let id = UUID()
    var title = "New Tab"
}

/// The open tabs and which one is showing. Newest first, the way the sidebar
/// lists them under its New Tab button.
@Observable
final class Browser {
    private(set) var tabs: [Tab]
    var selectedID: Tab.ID?

    init() {
        let first = Tab()
        tabs = [first]
        selectedID = first.id
    }

    var selected: Tab? { tabs.first { $0.id == selectedID } }

    func newTab() {
        let tab = Tab()
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
