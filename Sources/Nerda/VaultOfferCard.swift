import SwiftUI

/// After a sign-in that worked, over the top of its page: keep it in the
/// Vault? The site, the user name (to put right, as a site's page doesn't
/// always say it where Nerda can see), and the password, hidden until asked,
/// or the service it signs in with. Return keeps it.
struct VaultOfferCard: View {
    let browser: Browser
    let offer: PasswordOffer

    @State private var user: String
    @State private var showing = false
    @FocusState private var naming: Bool

    init(browser: Browser, offer: PasswordOffer) {
        self.browser = browser
        self.offer = offer
        _user = State(initialValue: offer.account.user)
    }

    private var provider: SocialSignIn.Provider? { SocialSignIn.provider(offer.account.provider) }

    private var title: String {
        if let provider { return "Save your \(provider.name) sign-in?" }
        return offer.replaces ? "Update the saved password?" : "Save this password?"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                SiteIcon(host: offer.account.host, size: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                    Text(offer.account.host)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.muted)
                        .truncationMode(.middle)
                }
                .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "lock.shield")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.muted)
                    .help("Kept in the Vault, in your Mac's keychain")
            }
            fields
            if provider == nil, PasswordCheck.strength(offer.password) == .weak {
                Label("This password is easy to guess. Change it on the site when you can.", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }
            HStack(spacing: 8) {
                Button("Never for This Site", action: browser.neverSavePasswords)
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
                    .help("Don't offer to save sign-ins on \(Site.of(offer.account.host))")
                Spacer(minLength: 12)
                PromptButton(title: "Not Now", action: browser.dropPasswordOffer)
                PromptButton(title: offer.replaces ? "Update" : "Save", prominent: true, action: keep)
            }
        }
        .padding(16)
        .frame(width: 380)
        .glassPanel(cornerRadius: 18)
        // Another sign-in's offer in its place.
        .onChange(of: offer.account) {
            user = offer.account.user
            showing = false
        }
    }

    /// The user name, to type over, and under it the password or the service.
    private var fields: some View {
        VStack(spacing: 0) {
            FieldRow(icon: "person") {
                TextField("User name", text: $user, prompt: Text(provider == nil ? "No user name" : "\(provider!.name) account"))
                    .textFieldStyle(.plain)
                    .focused($naming)
                    .onSubmit(keep)
            }
            Rectangle().fill(Palette.rim).frame(height: 1).padding(.leading, 36)
            if let provider {
                FieldRow(icon: nil) {
                    HStack(spacing: 8) {
                        SiteIcon(host: provider.icon, size: 12)
                        Text("Signs in with \(provider.name)")
                            .foregroundStyle(Palette.ink)
                    }
                }
            } else {
                FieldRow(icon: "key") {
                    HStack(spacing: 8) {
                        Text(showing ? offer.password : String(repeating: "•", count: min(max(offer.password.count, 8), 16)))
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(Palette.ink)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .contentTransition(.opacity)
                        Spacer(minLength: 0)
                        Button { showing.toggle() } label: {
                            Image(systemName: showing ? "eye.slash" : "eye")
                                .foregroundStyle(Palette.muted)
                                .frame(width: 20, height: 20)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(showing ? "Hide Password" : "Show Password")
                        .accessibilityLabel(showing ? "Hide Password" : "Show Password")
                    }
                    .animation(.easeOut(duration: 0.15), value: showing)
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.wash))
    }

    private func keep() {
        browser.keepOfferedPassword(as: user)
    }

    private struct FieldRow<Content: View>: View {
        let icon: String?
        @ViewBuilder let content: Content

        var body: some View {
            HStack(spacing: 10) {
                Group {
                    if let icon { Image(systemName: icon) } else { Color.clear }
                }
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
                .frame(width: 16)
                content
                    .font(.system(size: 13))
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
        }
    }
}
