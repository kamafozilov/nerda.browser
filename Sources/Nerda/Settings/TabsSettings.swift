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
                        detail: "A tab left this long frees its memory and loads again when opened. "
                            + "One over \(Browser.heavy >> 20) MB sleeps after \(Int(Browser.heavyAfter / 60)) minutes",
                        icon: "moon.zzz") {
                DropdownButton(label: sleep.name,
                               options: TabSleep.allCases.map {
                                   DropdownOption(id: "\($0.rawValue)", title: $0.name, separated: $0 == .fourHours)
                               },
                               selected: "\(sleep.rawValue)") { sleep = Int($0).flatMap(TabSleep.init) ?? .halfHour }
            }
            SettingsRow(title: "Load background tabs when shown",
                        detail: "A link opened behind the page loads only once you go to its tab",
                        icon: "hourglass") {
                SettingsToggle(title: "Load background tabs when shown", isOn: $waits)
            }
        }
        SettingsGroup(title: "Startup") {
            SettingsRow(title: "Load pinned tabs at launch", detail: "Off, Nerda opens on a new tab and loads a pinned tab when you open it",
                        icon: "pin") {
                SettingsToggle(title: "Load pinned tabs at launch", isOn: $loadsPins)
            }
        }
        SettingsGroup(title: "Previews") {
            SettingsRow(title: "Tab previews", detail: "When the pointer rests on a tab, show its page, its title and the memory it uses",
                        icon: "rectangle.on.rectangle") {
                SettingsToggle(title: "Tab previews", isOn: $previews)
            }
        }
    }
}
