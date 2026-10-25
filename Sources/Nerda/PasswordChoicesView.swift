import SwiftUI

/// The accounts kept for the site, hanging from the sign-in box, or the
/// addresses or cards kept, from a box of a form. A click puts one in, or
/// for a sign-in with another service, presses the site's button for it;
/// right-click an account to forget it.
// ponytail: always below the box; one at the window's bottom edge would want it above.
struct PasswordChoicesView: View {
    let browser: Browser
    let choices: PasswordChoices

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(choices.accounts, id: \.self) { account in
                let provider = SocialSignIn.provider(account.provider)
                ChoiceRow(icon: "key.fill", site: provider?.icon,
                          title: provider.map { "Continue with \($0.name)" } ?? (account.user.isEmpty ? "No user name" : account.user),
                          detail: provider == nil || account.user.isEmpty ? account.host : account.user) {
                    browser.fill(account)
                }
                .contextMenu {
                    Button(provider == nil ? "Remove Saved Password" : "Remove Saved Sign-In") { browser.forget(account) }
                }
            }
            ForEach(choices.addresses) { address in
                ChoiceRow(icon: "person.text.rectangle", title: address.title, detail: address.summary) { browser.fill(address) }
            }
            ForEach(choices.cards) { card in
                ChoiceRow(icon: "creditcard", title: card.title, detail: "Expires \(card.expiry)") { browser.fill(card) }
            }
        }
        .padding(4)
        .frame(width: max(240, min(340, choices.spot.width)))
        .glassPanel(cornerRadius: 12)
    }

    private struct ChoiceRow: View {
        let icon: String
        /// Whose icon to show in its place: the service a sign-in is with.
        var site: String? = nil
        let title: String
        let detail: String
        let pick: () -> Void
        @State private var hovering = false

        var body: some View {
            Button(action: pick) {
                HStack(spacing: 10) {
                    Group {
                        if let site { SiteIcon(host: site, size: 12) } else { Image(systemName: icon) }
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.muted)
                    .frame(width: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title)
                            .foregroundStyle(Palette.ink)
                        if !detail.isEmpty {
                            Text(detail)
                                .font(.caption)
                                .foregroundStyle(Palette.muted)
                        }
                    }
                    .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .frame(height: 38)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? Palette.hover : .clear))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
        }
    }
}

