import AppKit
import LocalAuthentication
import SwiftUI

/// Passwords (the sidebar's menu, Window, ⌥⌘L): every saved sign-in down the
/// left, to search, and the one picked on the right, to see, copy, change,
/// open or remove; more are added by hand with +. It opens after Touch ID or
/// the Mac's password, and asks again the next time it opens.
enum PasswordsWindow {
    fileprivate static var window: NSWindow?
    private static var closing: (any NSObjectProtocol)?
    /// Asking the person at the Mac who they are, before it opens.
    private static var asking = false

    static func show() {
        if let window { return window.makeKeyAndOrderFront(nil) }
        guard !asking else { return }
        asking = true
        Task {
            defer { asking = false }
            let context = LAContext()
            if context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) {
                guard (try? await context.evaluatePolicy(.deviceOwnerAuthentication,
                                                         localizedReason: "show your saved passwords")) == true
                else { return }
            }
            open()
        }
    }

    private static func open() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 540),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.title = "Passwords"
            // The list runs up under the window's buttons, as in Mail or Passwords.
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isReleasedWhenClosed = false
            // As big as it was left, not as big as the list: a search that
            // finds little would shrink it.
            let content = NSHostingView(rootView: PasswordsView())
            content.sizingOptions = [.minSize]
            window.contentView = content
            if !window.setFrameUsingName("Passwords") { window.center() }
            window.setFrameAutosaveName("Passwords")
            // Let go of when closed: the passwords seen go with it, and it
            // asks again next time.
            // Taken off as it fires: each open makes a new window, and a new observer.
            closing = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
                MainActor.assumeIsolated {
                    Self.window = nil
                    if let closing = Self.closing { NotificationCenter.default.removeObserver(closing) }
                    Self.closing = nil
                }
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

    /// A password onto the clipboard of this Mac only, not other devices',
    /// marked for clipboard managers to leave out, and taken off after a
    /// minute and a half unless something else was copied meanwhile. A user
    /// name, not secret, is copied as any text is.
    static func copy(_ text: String, secret: Bool = true) {
        let board = NSPasteboard.general
        guard secret else {
            board.clearContents()
            board.setString(text, forType: .string)
            return
        }
        board.prepareForNewContents(with: .currentHostOnly)
        board.setString(text, forType: .string)
        board.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        board.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        let copied = board.changeCount
        Task {
            try? await Task.sleep(for: .seconds(90))
            if board.changeCount == copied { board.clearContents() }
        }
    }
}


private struct PasswordsView: View {
    /// What the add and edit sheet holds; `old` is the one being changed.
    struct Draft: Identifiable {
        let id = UUID()
        var old: Account?
        var site = ""
        var user = ""
        var password = ""
    }

    @State private var names: [Vault.Name] = []
    @State private var query = ""
    @State private var selection: Account?
    /// Passwords on screen, each for a quarter of a minute.
    @State private var seen: [Account: String] = [:]
    @State private var draft: Draft?
    @State private var removing: Account?
    @FocusState private var searching: Bool

    private var vault: Vault { .shared }

    /// Those that match the search, by site and then name, in the order of the alphabet.
    private var found: [Vault.Name] {
        let query = query.trimmingCharacters(in: .whitespaces)
        return names
            .filter { query.isEmpty || $0.host.localizedCaseInsensitiveContains(query) || $0.user.localizedCaseInsensitiveContains(query) }
            .sorted { ($0.host, $0.user.lowercased()) < ($1.host, $1.user.lowercased()) }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 260)
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 640, minHeight: 400)
        .ignoresSafeArea(edges: .top)
        .task { await reload() }
        // A search that hides the one picked picks the first it finds.
        .onChange(of: query) {
            if !found.contains(where: { $0.account == selection }) { selection = found.first?.account }
        }
        // Saved from a page while the window was open.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            // Only this window's: any other window becoming key isn't a reason to read the list again.
            guard note.object as? NSWindow === PasswordsWindow.window else { return }
            Task { await reload() }
        }
        .sheet(item: $draft) { draft in
            DraftSheet(draft: draft) { self.draft = nil; if let done = $0 { keep(done) } }
        }
        .confirmationDialog(removing.map { "Remove the password for \(Self.title(of: $0))?" } ?? "",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Remove", role: .destructive) {
                if let removing { remove(removing) }
            }
        } message: {
            Text("It won't be offered on the site any more.")
        }
    }

    // MARK: The list

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search", text: $query)
                        .textFieldStyle(.plain)
                        .focused($searching)
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .help("Clear the Search")
                            .accessibilityLabel("Clear the Search")
                    }
                }
                .padding(.horizontal, 8)
                .frame(height: 28)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                Button { draft = Draft() } label: { Image(systemName: "plus").font(.system(size: 14, weight: .medium)) }
                    .buttonStyle(.borderless)
                    .help("Add a Password")
            }
            .padding(.horizontal, 12)
            // Below the window's buttons, which sit over the list's top.
            .padding(.top, 40)
            .padding(.bottom, 8)

            List(selection: $selection) {
                ForEach(found, id: \.account) { name in
                    AccountRow(account: name.account)
                        .tag(name.account)
                        .contextMenu { menu(for: name.account) }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .onDeleteCommand { removing = selection }
            .overlay {
                if !names.isEmpty && found.isEmpty { ContentUnavailableView.search(text: query) }
            }

            if !names.isEmpty {
                Text(query.isEmpty ? (names.count == 1 ? "1 password" : "\(names.count) passwords")
                                   : "\(found.count) of \(names.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
        }
        .background(.background.secondary)
        // ⌘F puts the caret in the search, as in any Mac app's list.
        .background {
            Button("") { searching = true }.keyboardShortcut("f").hidden()
        }
    }

    @ViewBuilder private func menu(for account: Account) -> some View {
        Button("Copy User Name") { PasswordsWindow.copy(account.user, secret: false) }
            .disabled(account.user.isEmpty)
        Button("Copy Password") { withPassword(of: account) { PasswordsWindow.copy($0) } }
        Divider()
        Button("Edit…") { edit(account) }
        Button("Remove…", role: .destructive) { removing = account }
    }

    // MARK: The one picked

    @ViewBuilder private var detail: some View {
        if names.isEmpty {
            ContentUnavailableView {
                Label("No Saved Passwords", systemImage: "key")
            } description: {
                Text("Passwords you save as you sign in to sites are kept here. Bring in those from Passwords, Safari or Chrome with File › Import Passwords…")
            } actions: {
                Button("Add a Password") { draft = Draft() }
            }
        } else if let account = selection, let name = found.first(where: { $0.account == account }) {
            AccountDetail(name: name, password: seen[account],
                          reveal: { reveal(account) },
                          copyPassword: { withPassword(of: account) { PasswordsWindow.copy($0) } },
                          edit: { edit(account) },
                          remove: { removing = account })
                .id(account)
        } else {
            ContentUnavailableView("No Password Selected", systemImage: "key",
                                   description: found.isEmpty ? nil : Text("Choose one on the left to see it."))
        }
    }

    // MARK: Doing

    static func title(of account: Account) -> String {
        account.user.isEmpty ? account.host : "\(account.user) on \(account.host)"
    }

    private func reload() async {
        names = await vault.all()
        if selection.map({ picked in !names.contains { $0.account == picked } }) ?? true {
            selection = found.first?.account
        }
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

    private func edit(_ account: Account) {
        withPassword(of: account) { draft = Draft(old: account, site: account.host, user: account.user, password: $0) }
    }

    /// Its password, from the keychain. The window opened only once the
    /// person at the Mac said it was them.
    private func withPassword(of account: Account, _ use: @escaping (String) -> Void) {
        Task {
            guard let password = await vault.password(for: account) else {
                return Browser.tell("Couldn't read the password", "The keychain didn't hand it over.")
            }
            use(password)
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

    private func keep(_ draft: Draft) {
        guard let host = PasswordsWindow.host(of: draft.site) else { return }
        let account = Account(host: host, user: draft.user.trimmingCharacters(in: .whitespaces))
        Task {
            let kept = if let old = draft.old {
                await vault.change(old, to: account, password: draft.password)
            } else {
                await vault.save([(account, draft.password)],
                                 clear: draft.site.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("http://"))
            }
            guard kept else { return Browser.tell("Couldn't save the password", "The keychain didn't take it.") }
            if let old = draft.old { seen[old] = nil }
            seen[account] = nil
            selection = account
            await reload()
        }
    }
}

/// A saved sign-in in the list: its site's icon and name, and the user name under them.
private struct AccountRow: View {
    let account: Account

    var body: some View {
        HStack(spacing: 10) {
            SiteIcon(host: account.host, size: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(account.host)
                    .fontWeight(.medium)
                Text(account.user.isEmpty ? "No user name" : account.user)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .truncationMode(.middle)
        }
        .padding(.vertical, 3)
    }
}

/// The one picked: what it is for, its name and password, each with a way
/// to copy it, and the site, to go to.
private struct AccountDetail: View {
    let name: Vault.Name
    /// Shown, or nil while hidden.
    let password: String?
    let reveal: () -> Void
    let copyPassword: () -> Void
    let edit: () -> Void
    let remove: () -> Void

    private var account: Account { name.account }

    var body: some View {
        Form {
            Section {
                LabeledContent("User Name") {
                    HStack(spacing: 8) {
                        Text(account.user.isEmpty ? "None" : account.user)
                            .foregroundStyle(account.user.isEmpty ? .secondary : .primary)
                            .textSelection(.enabled)
                        CopyButton(help: "Copy User Name") { PasswordsWindow.copy(account.user, secret: false) }
                            .disabled(account.user.isEmpty)
                    }
                }
                LabeledContent("Password") {
                    HStack(spacing: 8) {
                        Text(password ?? "••••••••••")
                            .font(.body.monospaced())
                            .foregroundStyle(password == nil ? .secondary : .primary)
                            .textSelection(.enabled)
                            .contentTransition(.opacity)
                        Button(action: reveal) { Image(systemName: password == nil ? "eye" : "eye.slash") }
                            .buttonStyle(.borderless)
                            .help(password == nil ? "Show Password" : "Hide Password")
                        CopyButton(help: "Copy Password", action: copyPassword)
                    }
                    .animation(.easeOut(duration: 0.15), value: password)
                }
            } header: {
                header
            }
            Section {
                LabeledContent("Website") {
                    Button(account.host) { open() }
                        .buttonStyle(.link)
                        .help("Open \(account.host) in a New Tab")
                }
                if name.clear == true {
                    LabeledContent("Connection") {
                        Label("Not secure (http)", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text("Saved \(name.saved.formatted(date: .long, time: .omitted))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .padding(.top, 14)
    }

    private var header: some View {
        HStack(spacing: 14) {
            SiteIcon(host: account.host, size: 32)
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
                .help("Remove This Password")
                .accessibilityLabel("Remove…")
        }
        .textCase(nil)
        .padding(.bottom, 10)
    }

    /// In a new tab of the regular window, brought forward.
    private func open() {
        guard let url = URL(string: "\(name.clear == true ? "http" : "https")://\(account.host)"),
              let window = Windows.regular else { return }
        window.browser.open(url)
        window.makeKeyAndOrderFront(nil)
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
    }
}

/// A password added by hand, or one changed.
private struct DraftSheet: View {
    @State var draft: PasswordsView.Draft
    let done: (PasswordsView.Draft?) -> Void
    @State private var showing = false

    private var complete: Bool { PasswordsWindow.host(of: draft.site) != nil && !draft.password.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Website", text: $draft.site, prompt: Text("example.com"))
                    TextField("User Name", text: $draft.user, prompt: Text("Optional"))
                    LabeledContent("Password") {
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
                        }
                    }
                } header: {
                    Text(draft.old == nil ? "Add a Password" : "Edit Password")
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .textCase(nil)
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
                    .disabled(!complete)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// A site's icon on a white tile, as the tabs have it, or, for a site Nerda
/// has no icon of, a globe on a grey one the same size.
private struct SiteIcon: View {
    let host: String
    let size: CGFloat

    var body: some View {
        let site = URL(string: "https://\(host)")
        // Drawn until it is known there is none: Favicon loads it.
        let none = Favicons.origin(of: site).map { Favicons.shared.icon($0) }.map { $0.image == nil && $0.failed } ?? true
        if !none {
            Favicon(site: site, size: size)
        } else {
            Image(systemName: "globe")
                .font(.system(size: size * 0.75))
                .foregroundStyle(.secondary)
                .frame(width: size + 8, height: size + 8)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }
}
