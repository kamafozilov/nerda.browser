import AppKit
import SwiftUI

/// What the Vault window lists: a kind of sign-in, or the passwords to look
/// at again.
enum VaultCategory: Hashable, CaseIterable {
    case all, passwords, services, weak, reused

    var title: String {
        switch self {
        case .all: "All Items"
        case .passwords: "Passwords"
        case .services: "Sign-Ins with Services"
        case .weak: "Weak"
        case .reused: "Reused"
        }
    }

    var icon: String {
        switch self {
        case .all: "square.grid.2x2.fill"
        case .passwords: "key.fill"
        case .services: "person.crop.circle.badge.checkmark"
        case .weak: "exclamationmark.triangle.fill"
        case .reused: "arrow.triangle.2.circlepath"
        }
    }

    var tint: Color {
        switch self {
        case .all: .blue
        case .passwords: .gray
        case .services: .indigo
        case .weak: .orange
        case .reused: .yellow
        }
    }

    func holds(_ name: Vault.Name, _ issues: PasswordCheck.Issues) -> Bool {
        switch self {
        case .all: true
        case .passwords: name.provider == nil
        case .services: name.provider != nil
        case .weak: issues.weak.contains(name.account)
        case .reused: issues.reused.contains(name.account)
        }
    }
}

/// The window's three columns: the kinds, the list of the one picked, and
/// the sign-in picked in it. What it does with them is here; how each
/// column looks is in VaultList.swift, VaultDetail.swift and VaultEditor.swift.
struct VaultView: View {
    let profile: Profile

    @State private var names: [Vault.Name] = []
    @State private var issues = PasswordCheck.Issues()
    @State private var category: VaultCategory? = .all
    @State private var query = ""
    @State private var selection: Account?
    /// Shown with its password and note, each for a quarter of a minute.
    @State private var seen: [Account: Vault.Login] = [:]
    @State private var draft: VaultDraft?
    @State private var removing: Account?

    private var vault: Vault { profile.vault }

    /// Those of the kind picked that match the search, by site and then
    /// name, in the order of the alphabet.
    private var found: [Vault.Name] {
        let query = query.trimmingCharacters(in: .whitespaces)
        return names
            .filter { (category ?? .all).holds($0, issues) }
            .filter { query.isEmpty || $0.host.localizedCaseInsensitiveContains(query) || $0.user.localizedCaseInsensitiveContains(query) }
            .sorted { ($0.host, $0.user.lowercased()) < ($1.host, $1.user.lowercased()) }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 220)
            Divider()
            VaultList(names: found, total: names.count, category: category ?? .all, issues: issues, query: $query,
                      selection: $selection, add: { draft = VaultDraft() }, menu: menu(for:), remove: { removing = $0 })
                .frame(width: 300)
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 900, minHeight: 480)
        .ignoresSafeArea(edges: .top)
        .task { await reload() }
        // A search, or another kind, that hides the one picked picks the first it finds.
        .onChange(of: query) { pickFirstIfHidden() }
        .onChange(of: category) { pickFirstIfHidden() }
        // Saved from a page, or imported, while the window was open.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            // Only this window's: any other window becoming key isn't a reason to read the list again.
            guard note.object as? NSWindow === VaultWindow.window else { return }
            Task { await reload() }
        }
        .sheet(item: $draft) { draft in
            VaultEditor(draft: draft) { self.draft = nil; if let done = $0 { keep(done) } }
        }
        .confirmationDialog(removing.map { "Remove \(Self.title(of: $0)) from the Vault?" } ?? "",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Remove", role: .destructive) {
                if let removing { remove(removing) }
            }
        } message: {
            Text("It won't be offered on the site any more.")
        }
    }

    // MARK: The kinds

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Vault")
                        .font(.title3.weight(.semibold))
                    if Profiles.shared.many {
                        Text(profile.name)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 16)
            // Below the window's buttons, which sit over the column's top.
            .padding(.top, 48)
            .padding(.bottom, 10)

            List(selection: $category) {
                Section {
                    ForEach([VaultCategory.all, .passwords, .services], id: \.self) { kind in
                        CategoryRow(kind: kind, count: names.count(where: { kind.holds($0, issues) }))
                    }
                }
                Section("Security") {
                    ForEach([VaultCategory.weak, .reused], id: \.self) { kind in
                        CategoryRow(kind: kind, count: names.count(where: { kind.holds($0, issues) }))
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)

            VStack(alignment: .leading, spacing: 2) {
                SidebarButton(title: "Import Passwords…", icon: "square.and.arrow.down") {
                    Windows.show(profile).importPasswords()
                }
                SidebarButton(title: "Export Passwords…", icon: "square.and.arrow.up") { VaultWindow.export(profile) }
                    .disabled(names.allSatisfy { $0.provider != nil })
            }
            .padding(8)
            Label("In your Mac's keychain, on this Mac only", systemImage: "lock.fill")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
        }
        .background(.background.secondary)
    }

    @ViewBuilder private func menu(for account: Account) -> some View {
        Button("Copy User Name") { VaultWindow.copy(account.user, secret: false) }
            .disabled(account.user.isEmpty)
        if account.provider == nil {
            Button("Copy Password") { withLogin(of: account) { VaultWindow.copy($0.password) } }
        }
        Divider()
        Button("Edit…") { edit(account) }
        Button("Remove…", role: .destructive) { removing = account }
    }

    // MARK: The one picked

    @ViewBuilder private var detail: some View {
        if names.isEmpty {
            ContentUnavailableView {
                Label("Nothing in the Vault Yet", systemImage: "lock.shield")
            } description: {
                Text("Passwords, and sign-ins with Google and other services, are kept here as you sign in to sites and say Save. Bring in those from Passwords, Safari or Chrome with Import Passwords.")
            } actions: {
                Button("Add an Item") { draft = VaultDraft() }
            }
        } else if let account = selection, let name = found.first(where: { $0.account == account }) {
            VaultDetail(profile: profile, name: name, login: seen[account], issues: issues,
                        reveal: { reveal(account) },
                        copyPassword: { withLogin(of: account) { VaultWindow.copy($0.password) } },
                        edit: { edit(account) },
                        remove: { removing = account })
                .id(account)
        } else if found.isEmpty, category == .weak || category == .reused {
            ContentUnavailableView(category == .weak ? "No Weak Passwords" : "No Reused Passwords",
                                   systemImage: "checkmark.shield",
                                   description: Text(category == .weak ? "Every password kept is hard to guess."
                                                     : "Each password kept is used on one site only."))
        } else {
            ContentUnavailableView("Nothing Selected", systemImage: "lock.shield",
                                   description: found.isEmpty ? nil : Text("Choose one in the list to see it."))
        }
    }

    // MARK: Doing

    static func title(of account: Account) -> String {
        account.user.isEmpty ? account.host : "\(account.user) on \(account.host)"
    }

    private func pickFirstIfHidden() {
        if !found.contains(where: { $0.account == selection }) { selection = found.first?.account }
    }

    /// The list, and what is wrong with the passwords: the window opened
    /// only once the person at the Mac said it was them, so the keychain is
    /// read for the check, and only what it finds is kept.
    private func reload() async {
        names = await vault.all()
        if let logins = await vault.everything() { issues = PasswordCheck.issues(logins) }
        if selection.map({ picked in !names.contains { $0.account == picked } }) ?? true {
            selection = found.first?.account
        }
    }

    private func reveal(_ account: Account) {
        if seen[account] != nil { return seen[account] = nil }
        withLogin(of: account) { login in
            seen[account] = login
            Task {
                try? await Task.sleep(for: .seconds(15))
                if seen[account]?.password == login.password { seen[account] = nil }
            }
        }
    }

    private func edit(_ account: Account) {
        withLogin(of: account) { draft = VaultDraft(editing: $0) }
    }

    /// With its password and note, from the keychain.
    private func withLogin(of account: Account, _ use: @escaping (Vault.Login) -> Void) {
        Task {
            guard let login = await vault.login(for: account) else {
                return Browser.tell("Couldn't read the Vault", "The keychain didn't hand it over.")
            }
            use(login)
        }
    }

    private func remove(_ account: Account) {
        // The one after it is picked next, or else the one before.
        let list = found.map(\.account)
        let next = list.firstIndex(of: account).flatMap { at in
            list.indices.contains(at + 1) ? list[at + 1] : (at > 0 ? list[at - 1] : nil)
        }
        Task {
            await vault.forget(account)
            seen[account] = nil
            if selection == account { selection = next }
            await reload()
        }
    }

    private func keep(_ draft: VaultDraft) {
        guard let account = draft.account else { return }
        let password = draft.provider == nil ? draft.password : ""
        let note = draft.note.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            var kept: Bool
            if let old = draft.old {
                kept = await vault.change(old, to: account, password: password, note: note)
            } else {
                kept = await vault.save([(account, password)], clear: draft.clear)
                if kept, !note.isEmpty { kept = await vault.change(account, to: account, password: password, note: note) }
            }
            guard kept else { return Browser.tell("Couldn't save it in the Vault", "The keychain didn't take it.") }
            if let old = draft.old { seen[old] = nil }
            seen[account] = nil
            if !(category ?? .all).holds(Vault.Name(host: account.host, user: account.user, saved: .now, provider: account.provider), issues) {
                category = .all
            }
            selection = account
            await reload()
        }
    }
}

/// A kind, with its tile and how many it holds.
private struct CategoryRow: View {
    let kind: VaultCategory
    let count: Int

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: kind.icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(kind.tint.gradient, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            Text(kind.title)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text("\(count)")
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .tag(kind)
    }
}

/// A quiet button at the foot of the kinds.
private struct SidebarButton: View {
    let title: String
    let icon: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hovering ? Palette.hover : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .onHover { hovering = $0 }
    }
}
