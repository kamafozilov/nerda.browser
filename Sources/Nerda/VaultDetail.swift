import SwiftUI

/// The sign-in picked in the Vault window: its site, what is wrong with its
/// password if anything is, its user name and password (or the service it
/// signs in with), each with a way to copy it, its note, and the site, to go to.
struct VaultDetail: View {
    let profile: Profile
    let name: Vault.Name
    /// With its password and note while they are shown; nil while hidden.
    let login: Vault.Login?
    let issues: PasswordCheck.Issues
    let reveal: () -> Void
    let copyPassword: () -> Void
    let edit: () -> Void
    let remove: () -> Void

    private var account: Account { name.account }
    private var provider: SocialSignIn.Provider? { SocialSignIn.provider(name.provider) }

    var body: some View {
        Form {
            Section {
                if let warning {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(warning.title).fontWeight(.semibold)
                            Text(warning.detail).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                    Button("Change It on \(account.host)…", action: open)
                }
            } header: {
                header
            }
            Section {
                LabeledContent("User Name") {
                    HStack(spacing: 8) {
                        Text(account.user.isEmpty ? "None" : account.user)
                            .foregroundStyle(account.user.isEmpty ? .secondary : .primary)
                            .textSelection(.enabled)
                        CopyButton(help: "Copy User Name") { VaultWindow.copy(account.user, secret: false) }
                            .disabled(account.user.isEmpty)
                    }
                }
                if let provider {
                    LabeledContent("Signs In With") {
                        HStack(spacing: 6) {
                            SiteIcon(host: provider.icon, size: 12)
                            Text(provider.name)
                        }
                    }
                } else {
                    LabeledContent("Password") {
                        HStack(spacing: 8) {
                            Text(login?.password ?? "••••••••••")
                                .font(.body.monospaced())
                                .foregroundStyle(login == nil ? .secondary : .primary)
                                .textSelection(.enabled)
                                .contentTransition(.opacity)
                            if let password = login?.password { StrengthBadge(strength: PasswordCheck.strength(password)) }
                            Button(action: reveal) { Image(systemName: login == nil ? "eye" : "eye.slash") }
                                .buttonStyle(.borderless)
                                .help(login == nil ? "Show Password" : "Hide Password")
                                .accessibilityLabel(login == nil ? "Show Password" : "Hide Password")
                            CopyButton(help: "Copy Password", action: copyPassword)
                        }
                        .animation(.easeOut(duration: 0.15), value: login?.password)
                    }
                }
                LabeledContent("Website") {
                    Button(account.host, action: open)
                        .buttonStyle(.link)
                        .help("Open \(account.host) in a New Tab")
                }
                if name.clear == true {
                    LabeledContent("Connection") {
                        Label("Not secure (http)", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if name.noted == true {
                Section("Note") {
                    if let note = login?.note {
                        Text(note)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Button("Show Note", action: reveal)
                            .buttonStyle(.link)
                    }
                }
            }
            Section {
            } footer: {
                Text("Saved \(name.saved.formatted(date: .long, time: .omitted)) · in your Mac's keychain")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .padding(.top, 34)
    }

    private var header: some View {
        HStack(spacing: 14) {
            SiteIcon(host: account.host, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(account.host)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(name.used.map { "Last used \($0.formatted(.relative(presentation: .named)))" } ?? "Not used yet")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            Spacer(minLength: 12)
            Button("Edit…", action: edit)
            Button(role: .destructive, action: remove) { Image(systemName: "trash") }
                .help("Remove from the Vault")
                .accessibilityLabel("Remove…")
        }
        .textCase(nil)
        .padding(.bottom, 10)
    }

    /// Why the password wants changing, for one the check found.
    private var warning: (title: String, detail: String)? {
        if issues.reused.contains(account) {
            return ("Used on another site",
                    "A leak at one of them opens your account at the others. Give each site a password of its own.")
        }
        if issues.weak.contains(account) {
            return ("Easy to guess", "It is short, or one of the passwords everyone tries first.")
        }
        return nil
    }

    /// In a new tab of the profile's window, brought forward.
    private func open() {
        guard let url = URL(string: "\(name.clear == true ? "http" : "https")://\(account.host)") else { return }
        Windows.show(profile).open(url)
    }
}

/// How hard a password is to guess, in a word and a colour.
struct StrengthBadge: View {
    let strength: PasswordCheck.Strength

    var body: some View {
        let (word, color): (String, Color) = switch strength {
        case .weak: ("Weak", .orange)
        case .fair: ("Fair", .yellow)
        case .strong: ("Strong", .green)
        }
        Text(word)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(color.opacity(0.15), in: Capsule())
    }
}

/// Copies, and says so for a moment with a tick.
private struct CopyButton: View {
    let help: String
    let action: () -> Void
    @State private var copied = false

    var body: some View {
        Button {
            action()
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.2))
                copied = false
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 16)
        }
        .buttonStyle(.borderless)
        .help(help)
        .accessibilityLabel(help)
    }
}
