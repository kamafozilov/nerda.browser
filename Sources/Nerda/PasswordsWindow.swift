import AppKit
import LocalAuthentication
import SwiftUI

/// Window › Passwords (⌥⌘L): every saved sign-in, by site, to find, see,
/// copy, change, remove, or add by hand. A password is seen, copied or
/// changed only after Touch ID or the Mac's password, asked once for the
/// next five minutes while the window stays open.
enum PasswordsWindow {
    private static var window: NSWindow?

    static func show() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.title = "Passwords"
            window.isReleasedWhenClosed = false
            // As big as it was left, not as big as the list: a search that
            // finds little would shrink it.
            let content = NSHostingView(rootView: PasswordList())
            content.sizingOptions = [.minSize]
            window.contentView = content
            if !window.setFrameUsingName("Passwords") { window.center() }
            window.setFrameAutosaveName("Passwords")
            // Let go of when closed: the passwords seen go with it, and it
            // asks again next time.
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
                MainActor.assumeIsolated { Self.window = nil }
            }
            Self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
    }

    /// The host a password is kept under, from what was typed for its
    /// website: an address (https://github.com/login) or a bare host.
    nonisolated static func host(of typed: String) -> String? {
        let typed = typed.trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty, !typed.contains(" "),
              let host = URL(string: typed.contains("://") ? typed : "https://" + typed)?.host(),
              !host.isEmpty else { return nil }
        return Site.key(host)
    }

    /// Onto the clipboard of this Mac only, not other devices', marked for
    /// clipboard managers to leave out, and taken off after a minute and a
    /// half unless something else was copied meanwhile.
    static func copy(_ secret: String) {
        let board = NSPasteboard.general
        board.prepareForNewContents(with: .currentHostOnly)
        board.setString(secret, forType: .string)
        board.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        board.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        let copied = board.changeCount
        Task {
            try? await Task.sleep(for: .seconds(90))
            if board.changeCount == copied { board.clearContents() }
        }
    }
}

private struct PasswordList: View {
    /// What the add and change sheet holds; `old` is the one being changed.
    struct Draft: Identifiable {
        let id = UUID()
        var old: Account?
        var site = ""
        var user = ""
        var password = ""
    }

    @State private var names: [Vault.Name] = []
    @State private var query = ""
    /// Passwords on screen, each for a quarter of a minute.
    @State private var seen: [Account: String] = [:]
    @State private var draft: Draft?
    @State private var removing: Account?
    @State private var unlocked: Date?

    private var vault: Vault { .shared }

    /// The accounts that match the search, by site, in the order of the alphabet.
    private var sites: [(host: String, accounts: [Account])] {
        let query = query.trimmingCharacters(in: .whitespaces)
        let found = names.map(\.account).filter {
            query.isEmpty || $0.host.localizedCaseInsensitiveContains(query) || $0.user.localizedCaseInsensitiveContains(query)
        }
        return Dictionary(grouping: found, by: \.host)
            .sorted { $0.key < $1.key }
            .map { ($0.key, $0.value.sorted { $0.user.localizedStandardCompare($1.user) == .orderedAscending }) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search", text: $query).textFieldStyle(.plain)
                }
                .padding(.horizontal, 8)
                .frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 7).fill(.quaternary))
                Button { draft = Draft() } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
                    .help("Add a Password")
            }
            .padding(10)
            Divider()
            if names.isEmpty {
                ContentUnavailableView("No Saved Passwords", systemImage: "key",
                                       description: Text("Passwords you save as you sign in, or bring in with File › Import Passwords…, are kept here."))
                    .frame(maxHeight: .infinity)
            } else if sites.isEmpty {
                ContentUnavailableView.search(text: query)
                    .frame(maxHeight: .infinity)
            } else {
                // Each site's name heads its accounts as a row of the list,
                // not a section header, which would stay stuck at the top.
                List {
                    ForEach(sites, id: \.host) { site in
                        Text(site.host)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.top, site.host == sites.first?.host ? 0 : 10)
                            .listRowSeparator(.hidden)
                        ForEach(site.accounts, id: \.self) { account in row(account) }
                    }
                }
            }
        }
        .frame(minWidth: 420, minHeight: 300)
        .task { await reload() }
        // Saved from a page while the window was open.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            Task { await reload() }
        }
        .sheet(item: $draft) { draft in
            DraftSheet(draft: draft) { self.draft = nil; if let done = $0 { keep(done) } }
        }
        .confirmationDialog(removing.map { "Remove the password for \($0.user.isEmpty ? $0.host : "\($0.user) on \($0.host)")?" } ?? "",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Remove", role: .destructive) {
                guard let account = removing else { return }
                Task {
                    await vault.forget(account)
                    seen[account] = nil
                    await reload()
                }
            }
        } message: {
            Text("It can't be filled in on the site any more.")
        }
    }

    private func row(_ account: Account) -> some View {
        HStack(spacing: 10) {
            Text(account.user.isEmpty ? "No user name" : account.user)
                .foregroundStyle(account.user.isEmpty ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 12)
            Text(seen[account] ?? "••••••••")
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(seen[account] == nil ? .secondary : .primary)
                .lineLimit(1)
                .textSelection(.enabled)
            Button { reveal(account) } label: { Image(systemName: seen[account] == nil ? "eye" : "eye.slash") }
                .help(seen[account] == nil ? "Show Password" : "Hide Password")
            Button { withPassword(of: account) { PasswordsWindow.copy($0) } } label: { Image(systemName: "doc.on.doc") }
                .help("Copy Password")
        }
        .buttonStyle(.borderless)
        .padding(.vertical, 2)
        .contextMenu {
            Button("Copy User Name") { PasswordsWindow.copy(account.user) }.disabled(account.user.isEmpty)
            Button("Copy Password") { withPassword(of: account) { PasswordsWindow.copy($0) } }
            Divider()
            Button("Edit…") {
                withPassword(of: account) { draft = Draft(old: account, site: account.host, user: account.user, password: $0) }
            }
            Button("Remove…") { removing = account }
        }
    }

    private func reload() async {
        names = await vault.all()
    }

    private func reveal(_ account: Account) {
        if seen[account] != nil { return seen[account] = nil }
        withPassword(of: account) { password in
            seen[account] = password
            Task {
                try? await Task.sleep(for: .seconds(15))
                if seen[account] == password { seen[account] = nil }
            }
        }
    }

    /// Its password, once the person at the Mac has said it is them.
    private func withPassword(of account: Account, _ use: @escaping (String) -> Void) {
        Task {
            guard await unlock() else { return }
            guard let password = await vault.password(for: account) else {
                return Browser.tell("Couldn't read the password", "The keychain didn't hand it over.")
            }
            use(password)
        }
    }

    private func unlock() async -> Bool {
        if let unlocked, Date.now.timeIntervalSince(unlocked) < 300 { return true }
        let context = LAContext()
        if context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) {
            guard (try? await context.evaluatePolicy(.deviceOwnerAuthentication,
                                                     localizedReason: "see your saved passwords")) == true
            else { return false }
        }
        unlocked = .now
        return true
    }

    private func keep(_ draft: Draft) {
        guard let host = PasswordsWindow.host(of: draft.site) else { return }
        let account = Account(host: host, user: draft.user.trimmingCharacters(in: .whitespaces))
        Task {
            let kept = if let old = draft.old {
                await vault.change(old, to: account, password: draft.password)
            } else {
                await vault.save([(account, draft.password)])
            }
            guard kept else { return Browser.tell("Couldn't save the password", "The keychain didn't take it.") }
            if let old = draft.old { seen[old] = nil }
            seen[account] = nil
            await reload()
        }
    }
}

/// A password added by hand, or one changed.
private struct DraftSheet: View {
    @State var draft: PasswordList.Draft
    let done: (PasswordList.Draft?) -> Void
    @State private var showing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(draft.old == nil ? "Add a Password" : "Edit Password").font(.headline)
            Form {
                TextField("Website", text: $draft.site, prompt: Text("example.com"))
                TextField("User Name", text: $draft.user)
                HStack {
                    Group {
                        if showing { TextField("Password", text: $draft.password) } else { SecureField("Password", text: $draft.password) }
                    }
                    Button { showing.toggle() } label: { Image(systemName: showing ? "eye.slash" : "eye") }
                        .buttonStyle(.borderless)
                        .help(showing ? "Hide Password" : "Show Password")
                }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { done(nil) }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { done(draft) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(PasswordsWindow.host(of: draft.site) == nil || draft.password.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}
