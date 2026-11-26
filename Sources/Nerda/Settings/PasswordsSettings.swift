import SwiftUI

/// Saved sign-ins: where to see them, whether Nerda offers to keep and fill
/// them, and the sites it was told never to ask about.
struct PasswordsSettings: View {
    let browser: Browser

    @AppStorage(Passwords.offersKey) private var offers = true
    @AppStorage(Passwords.fillsKey) private var fills = true
    /// Read once, then changed here and in the defaults together.
    @State private var never = Passwords.never.sorted()

    var body: some View {
        SettingsGroup {
            SettingsLink(title: "Vault", detail: "Your passwords and sign-ins, opened with Touch ID",
                         icon: "lock.shield") { VaultWindow.show(browser.profile) }
            SettingsRow(title: "Import passwords", detail: "From the file Passwords, Safari or Chrome exports", icon: "tray.and.arrow.down") {
                Button("Import…", action: browser.importPasswords)
                    .buttonStyle(SettingsButtonStyle())
                    .fixedSize()
            }
        }
        SettingsGroup(title: "AutoFill") {
            SettingsRow(title: "Offer to save passwords", detail: offerDetail, icon: "square.and.arrow.down.on.square") {
                SettingsToggle(title: "Offer to save passwords", isOn: $offers)
            }
            SettingsRow(title: "Fill in saved passwords", detail: "Offer your accounts under a sign-in box",
                        icon: "rectangle.and.pencil.and.ellipsis") {
                SettingsToggle(title: "Fill in saved passwords", isOn: $fills)
            }
        }
        SettingsGroup(title: "Never saved") {
            if never.isEmpty {
                SettingsRow(title: "No sites", detail: "Sites you told never to save a password",
                            icon: "nosign") { EmptyView() }
            }
            ForEach(never, id: \.self) { site in
                SiteRow(site: URL(string: "https://\(site)"), title: site) {
                    Button("Remove") {
                        never.removeAll { $0 == site }
                        Passwords.never.remove(site)
                    }
                    .buttonStyle(SettingsButtonStyle())
                    .fixedSize()
                    .help("Offer to save passwords on \(site) again")
                }
            }
        }
    }

    private var offerDetail: String {
        if let manager = Extensions.shared.passwordSavingTakenBy { return "\(manager) saves your passwords instead" }
        return "Ask to keep a password or Google sign-in once it works"
    }
}
