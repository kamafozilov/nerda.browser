import SwiftUI

/// How tabs live: how soon one left alone sleeps, when one opened behind
/// loads, what loads at launch, and the card a tab shows under the pointer.
struct TabsSettings: View {
    @AppStorage(TabSleep.key) private var sleep = TabSleep.halfHour
    @AppStorage(Browser.waitsKey) private var waits = false
    @AppStorage(Session.loadsPinsKey) private var loadsPins = true
    @AppStorage(TabPreviews.key) private var previews = true

    var body: some View {
        SettingsGroup(title: "Memory") {
            SettingsRow(title: "Sleep inactive tabs",
                        detail: "Unused tabs free memory, ones over \(Browser.heavy >> 20) MB after \(Int(Browser.heavyAfter / 60)) min",
                        icon: "moon.zzz") {
                DropdownButton(label: sleep.name,
                               options: TabSleep.allCases.map {
                                   DropdownOption(id: "\($0.rawValue)", title: $0.name, separated: $0 == .fourHours)
                               },
                               selected: "\(sleep.rawValue)") { sleep = Int($0).flatMap(TabSleep.init) ?? .halfHour }
            }
            SettingsRow(title: "Load background tabs when shown",
                        detail: "Links opened in the background load when you go to them",
                        icon: "hourglass") {
                SettingsToggle(title: "Load background tabs when shown", isOn: $waits)
            }
        }
        SettingsGroup(title: "Startup") {
            SettingsRow(title: "Load pinned tabs at launch", detail: "Off, pinned tabs load when you open them",
                        icon: "pin") {
                SettingsToggle(title: "Load pinned tabs at launch", isOn: $loadsPins)
            }
        }
        SettingsGroup(title: "Previews") {
            SettingsRow(title: "Tab previews", detail: "Show a tab's page, title and memory when you point at it",
                        icon: "rectangle.on.rectangle") {
                SettingsToggle(title: "Tab previews", isOn: $previews)
            }
        }
    }
}
