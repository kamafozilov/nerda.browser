import SwiftUI

/// What the Vault's add and edit sheet holds; `old` is the one being changed.
struct VaultDraft: Identifiable {
    let id = UUID()
    var old: Account?
    var site = ""
    var user = ""
    var password = ""
    /// The service it signs in with, for one that has no password.
    var provider: String?
    var note = ""

    init() {}

    init(editing login: Vault.Login) {
        old = login.account
        site = login.host
        user = login.user
        password = login.password
        provider = login.provider
        note = login.note ?? ""
    }

    /// As it would be kept; nil while the website isn't one.
    var account: Account? {
        VaultWindow.host(of: site).map { Account(host: $0, user: user.trimmingCharacters(in: .whitespaces), provider: provider) }
    }

    /// Typed as a plain http address.
    var clear: Bool { site.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("http://") }

    var isComplete: Bool { account != nil && (provider != nil || !password.isEmpty) }
}

/// A sign-in added by hand, or one changed: a password, which can be one
/// Nerda makes up, or a sign-in with a service; and a note for either.
struct VaultEditor: View {
    @State var draft: VaultDraft
    let done: (VaultDraft?) -> Void
    @State private var showing = false

    /// The kind, as the picker at the top has it.
    private var service: Binding<Bool> {
        Binding(get: { draft.provider != nil },
                set: { draft.provider = $0 ? (draft.provider ?? SocialSignIn.providers[0].id) : nil })
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                Text(draft.old == nil ? "Add to the Vault" : "Edit")
                    .font(.headline)
                Picker("Kind", selection: service) {
                    Text("Password").tag(false)
                    Text("Sign-In with a Service").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            .padding(.top, 20)

            Form {
                Section {
                    TextField("Website", text: $draft.site, prompt: Text("example.com"))
                    TextField(draft.provider == nil ? "User Name" : "Account", text: $draft.user, prompt: Text("Optional"))
                    if draft.provider == nil {
                        passwordField
                    } else {
                        Picker("Signs In With", selection: Binding(get: { draft.provider ?? "" }, set: { draft.provider = $0 })) {
                            ForEach(SocialSignIn.providers) { provider in
                                Text(provider.name).tag(provider.id)
                            }
                        }
                    }
                }
                Section("Note") {
                    TextEditor(text: $draft.note)
                        .font(.body)
                        .frame(minHeight: 54, maxHeight: 120)
                        .scrollContentBackground(.hidden)
                        .accessibilityLabel("Note")
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { done(nil) }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { done(draft) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!draft.isComplete)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Typed, or made up with the wand; how hard it is to guess under it.
    private var passwordField: some View {
        LabeledContent("Password") {
            VStack(alignment: .trailing, spacing: 6) {
                HStack(spacing: 8) {
                    Group {
                        if showing {
                            TextField("Password", text: $draft.password, prompt: Text("Required"))
                        } else {
                            SecureField("Password", text: $draft.password, prompt: Text("Required"))
                        }
                    }
                    .labelsHidden()
                    .font(draft.password.isEmpty ? .body : .body.monospaced())
                    Button { showing.toggle() } label: { Image(systemName: showing ? "eye.slash" : "eye") }
                        .buttonStyle(.borderless)
                        .help(showing ? "Hide Password" : "Show Password")
                        .accessibilityLabel(showing ? "Hide Password" : "Show Password")
                    Button {
                        draft.password = PasswordCheck.strong()
                        showing = true
                    } label: { Image(systemName: "wand.and.stars") }
                        .buttonStyle(.borderless)
                        .help("Make Up a Strong Password")
                        .accessibilityLabel("Make Up a Strong Password")
                }
                if !draft.password.isEmpty {
                    StrengthBadge(strength: PasswordCheck.strength(draft.password))
                }
            }
        }
    }
}
