import SwiftUI

/// Profiles, as Safari's: browsing kept apart, each with its own history,
/// bookmarks, tabs, cookies, site settings and passwords, in a window of its
/// own. Personal, the browsing there was before, comes first and stays.
struct ProfilesSettings: View {
    let browser: Browser
    let edit: (ProfileDraft) -> Void

    private var profiles: Profiles { .shared }

    var body: some View {
        SettingsGroup {
            ForEach(profiles.all) { profile in
                let here = profile === browser.profile
                SettingsRow(title: profile.name, detail: here && profiles.many ? "This window" : nil,
                            icon: profile.symbol, tint: profile.color.color) {
                    HStack(spacing: 8) {
                        if !here {
                            Button("Open") { Windows.show(profile) }
                                .accessibilityLabel("Open \(profile.name) Window")
                        }
                        Button("Edit…") { edit(ProfileDraft(profile)) }
                            .accessibilityLabel("Edit \(profile.name)")
                    }
                    .buttonStyle(SettingsButtonStyle())
                    .fixedSize()
                }
            }
            SettingsRow(title: "New profile",
                        detail: profiles.many ? nil : "Each has its own history, bookmarks, tabs, cookies and passwords",
                        icon: "plus") {
                Button("Add…") { edit(ProfileDraft(taken: profiles.all)) }
                    .buttonStyle(SettingsButtonStyle())
                    .fixedSize()
            }
        }
    }
}

/// What a profile is made or changed to, until it is saved.
struct ProfileDraft: Identifiable {
    let id = UUID()
    /// The one being changed; nil for a new one.
    var profile: Profile?
    var name = ""
    var symbol = "briefcase"
    var color = Palette.Accent.orange

    init(_ profile: Profile) {
        self.profile = profile
        (name, symbol, color) = (profile.name, profile.symbol, profile.color)
    }

    /// A new one, with a symbol and a colour no other has yet, while there are some.
    init(taken: [Profile]) {
        symbol = Profile.symbols.map(\.symbol).first { symbol in !taken.contains { $0.symbol == symbol } } ?? symbol
        color = Palette.Accent.allCases.first { color in !taken.contains { $0.color == color } } ?? color
    }
}

/// A profile's name, symbol and colour, as Safari asks for them; any but
/// Personal is deleted from here too.
struct ProfileDialog: View {
    let escapes: Bool
    let delete: (Profile) -> Void
    let done: () -> Void

    @State private var draft: ProfileDraft
    @FocusState private var naming: Bool

    init(draft: ProfileDraft, escapes: Bool, delete: @escaping (Profile) -> Void, done: @escaping () -> Void) {
        _draft = State(initialValue: draft)
        self.escapes = escapes
        self.delete = delete
        self.done = done
    }

    private var name: String { draft.name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        SettingsDialog(width: 400, escapes: escapes, cancel: done) {
            Text(draft.profile == nil ? "New profile" : "Edit profile")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Palette.ink)
            label("Name")
                .padding(.top, 16)
            TextField("Name", text: $draft.name, prompt: Text("Work"))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .focused($naming)
                .onSubmit(save)
            label("Symbol")
                .padding(.top, 16)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(52), spacing: 8), count: 6), alignment: .leading, spacing: 8) {
                ForEach(Profile.symbols, id: \.symbol) { symbol in
                    choice(symbol.name, picked: draft.symbol == symbol.symbol) { draft.symbol = symbol.symbol } label: {
                        Image(systemName: symbol.symbol)
                            .font(.system(size: 16))
                            .foregroundStyle(draft.symbol == symbol.symbol ? draft.color.color : Palette.muted)
                            .frame(width: 52, height: 36)
                    }
                }
            }
            label("Colour")
                .padding(.top, 16)
            HStack(spacing: 8) {
                ForEach(Palette.Accent.allCases) { color in
                    choice(color.name, picked: draft.color == color) { draft.color = color } label: {
                        Circle()
                            .fill(color.color)
                            .frame(width: 18, height: 18)
                            .frame(width: 37, height: 32)
                    }
                }
            }
            HStack(spacing: 8) {
                if let profile = draft.profile, !profile.isMain {
                    Button("Delete…", role: .destructive) {
                        done()
                        delete(profile)
                    }
                    .buttonStyle(SettingsButtonStyle())
                }
                Spacer()
                Button("Cancel", action: done)
                    .buttonStyle(SettingsButtonStyle())
                Button(draft.profile == nil ? "Create" : "Save", action: save)
                    .buttonStyle(SettingsButtonStyle(prominent: true))
                    .disabled(name.isEmpty)
            }
            .padding(.top, 22)
        }
        .onAppear { naming = true }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Palette.ink)
            .padding(.bottom, 8)
    }

    /// One of the symbols or colours, ringed when it is the one picked.
    private func choice(_ title: String, picked: Bool, pick: @escaping () -> Void, @ViewBuilder label: () -> some View) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        return Button(action: pick) {
            label()
                .background(picked ? Palette.wash : Color.primary.opacity(0.045), in: shape)
                .overlay(shape.strokeBorder(picked ? Palette.ink.opacity(0.5) : .clear, lineWidth: 1.5))
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(picked ? .isSelected : [])
    }

    private func save() {
        guard !name.isEmpty else { return }
        if let profile = draft.profile {
            (profile.name, profile.symbol, profile.color) = (name, draft.symbol, draft.color)
            Profiles.shared.save()
        } else {
            Profiles.shared.add(name: name, symbol: draft.symbol, color: draft.color)
        }
        Windows.retitle()
        done()
    }
}

/// Deleting a profile, once asked: all it kept goes from this Mac, and its window closes.
struct DeleteProfileDialog: View {
    let profile: Profile
    let escapes: Bool
    let done: () -> Void

    var body: some View {
        SettingsDialog(width: 380, escapes: escapes, cancel: done) {
            Text("Delete “\(profile.name)”?")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Palette.ink)
            Text("Its history, bookmarks, open tabs, site settings, saved passwords, cookies and website data are deleted from this Mac, and its window closes.")
                .font(.system(size: 13))
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel", action: done)
                    .buttonStyle(SettingsButtonStyle())
                Button("Delete", role: .destructive, action: delete)
                    .buttonStyle(SettingsButtonStyle())
            }
            .padding(.top, 22)
        }
    }

    /// Once this click is over: the window it is in may be the profile's,
    /// which closes.
    private func delete() {
        let profile = profile
        done()
        DispatchQueue.main.async {
            VaultWindow.close(profile)
            Windows.forget(profile)
            Task {
                await Profiles.shared.remove(profile)
                Windows.retitle()
            }
        }
    }
}
