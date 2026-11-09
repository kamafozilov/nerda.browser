import SwiftUI

/// Every key the browser answers to, by what it works on. Written out here,
/// as the menu bar has no room for what each does.
struct ShortcutsSettings: View {
    typealias Shortcut = (title: String, detail: String, keys: String)

    static let groups: [(title: String, shortcuts: [Shortcut])] = [
        ("Tabs", [
            ("New Tab", "Open a new tab", "⌘T"),
            ("Close Tab", "Close the tab on screen. A pinned site keeps its tile", "⌘W"),
            ("Reopen Closed Tab", "Restore the last closed tab", "⇧⌘T"),
            ("Search Tabs", "Find an open tab, or a site from your history", "⇧⌘A"),
            ("Next Tab", "Go to the next tab, round from the last to the first. ⇧⌘] and ⌥⌘→ do it too", "⌃Tab"),
            ("Previous Tab", "Go to the tab before. ⇧⌘[ and ⌥⌘← do it too", "⌃⇧Tab"),
            ("Go to a Tab", "The first eight tabs, in order", "⌘1 – ⌘8"),
            ("Last Tab", "Go to the last tab", "⌘9"),
            ("Collapse Tabs", "Show or hide the sidebar", "⌘S"),
        ]),
        ("Page", [
            ("Open Location", "Type an address or a search", "⌘L"),
            ("Open File", "Open HTML or PDF files from your Mac", "⌘O"),
            ("Back", "Go to the previous page", "⌘["),
            ("Forward", "Go to the next page", "⌘]"),
            ("Reload Page", "Load the page again", "⌘R"),
            ("Hard Reload Page", "Load the page again, fresh from the site", "⇧⌘R"),
            ("Show Reader", "Read an article alone, without the rest of the page", "⌃⌘R"),
            ("Find", "Search for text on the page", "⌘F"),
            ("Find Next", "Go to the next match", "⌘G"),
            ("Find Previous", "Go to the match before", "⇧⌘G"),
            ("Use Selection for Find", "Look for the text you selected on the page", "⌘E"),
            ("Bookmark This Tab", "Keep the page in your bookmarks, or take it out", "⌘D"),
            ("Print", "Print the page, or save it as a PDF from the print sheet", "⌘P"),
            ("Zoom In", "Make the page bigger", "⌘+"),
            ("Zoom Out", "Make the page smaller", "⌘−"),
            ("Actual Size", "Back to the zoom pages open at", "⌘0"),
        ]),
        ("Nerda", [
            ("New Window", "Bring your profile's window to the front, on a new tab", "⌘N"),
            ("New Incognito Window", "Browse without saving history", "⇧⌘N"),
            ("Close Window", "Close the window and its tabs", "⇧⌘W"),
            ("Show All History", "Every page you have visited", "⌘Y"),
            ("Downloads", "Show the files you downloaded, or put the list away", "⌥⌘L"),
            ("Vault", "Your saved passwords and sign-ins", "⌥⌘P"),
            ("Settings", "Open Nerda's settings", "⌘,"),
            ("Minimize", "Put the window in the Dock", "⌘M"),
            ("Hide Nerda", "Hide Nerda's windows", "⌘H"),
            ("Hide Others", "Hide every app's windows but Nerda's", "⌥⌘H"),
            ("Quit Nerda", "Close Nerda. Your tabs come back next time", "⌘Q"),
        ]),
        ("Developer", [
            ("Developer Tools", "Open the page's Web Inspector", "⌥⌘I"),
            ("JavaScript Console", "Open the inspector on its console", "⌥⌘J"),
            ("Inspect Element", "Pick something on the page to inspect", "⌥⌘C"),
            ("Responsive Design Mode", "See the page as a phone or a tablet shows it", "⌥⌘R"),
            ("View Page Source", "The page's HTML, in a tab of its own", "⌥⌘U"),
        ]),
    ]

    var body: some View {
        ForEach(Self.groups, id: \.title) { group in
            SettingsGroup(title: group.title) {
                ForEach(group.shortcuts, id: \.title) { shortcut in
                    SettingsRow(title: shortcut.title, detail: shortcut.detail) {
                        Text(shortcut.keys)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Palette.ink)
                            .padding(.horizontal, 9)
                            .frame(height: 26)
                            .background(Color.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                }
            }
        }
    }
}
