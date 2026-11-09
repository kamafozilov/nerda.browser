import AppKit
import LocalAuthentication
import SwiftUI

/// The Vault (the sidebar's menu, Window, ⌥⌘P): every saved sign-in, the
/// passwords and those with another service (Sign in with Google), by kind
/// down the left with the passwords to look at again under Security, the
/// list of the kind picked, to search, and the one picked, to see, copy,
/// change, open or remove. It opens after Touch ID or the Mac's password,
/// and asks again the next time it opens. One profile's at a time: the
/// window in front's.
enum VaultWindow {
    fileprivate(set) static var window: NSWindow?
    private static var profile: Profile?
    private static var closing: (any NSObjectProtocol)?
    /// Asking the person at the Mac who they are, before it opens.
    private static var asking = false

    static func show(_ profile: Profile) {
        if let window {
            if profile === Self.profile { return window.makeKeyAndOrderFront(nil) }
            // Another profile's: it goes, and this one's asks, as a window opening does.
            window.close()
        }
        guard !asking else { return }
        asking = true
        Task {
            defer { asking = false }
            let context = LAContext()
            if context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) {
                guard (try? await context.evaluatePolicy(.deviceOwnerAuthentication,
                                                         localizedReason: "open the Vault of your saved passwords")) == true
                else { return }
            }
            open(profile)
        }
    }

    /// Closed with its profile, as that is deleted.
    static func close(_ profile: Profile) {
        if profile === Self.profile { window?.close() }
    }

    private static func open(_ profile: Profile) {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 600),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.title = Profiles.shared.many ? "\(profile.name) Vault" : "Vault"
            // The kinds run up under the window's buttons, as in Mail or Passwords.
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isReleasedWhenClosed = false
            // As big as it was left, not as big as the list: a search that
            // finds little would shrink it.
            let content = NSHostingView(rootView: VaultView(profile: profile))
            content.sizingOptions = [.minSize]
            window.contentView = content
            if !window.setFrameUsingName("Vault") { window.center() }
            window.setFrameAutosaveName("Vault")
            // Let go of when closed: the passwords seen go with it, and it
            // asks again next time.
            // Taken off as it fires: each open makes a new window, and a new observer.
            closing = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
                MainActor.assumeIsolated {
                    Self.window = nil
                    Self.profile = nil
                    if let closing = Self.closing { NotificationCenter.default.removeObserver(closing) }
                    Self.closing = nil
                }
            }
            Self.window = window
            Self.profile = profile
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

    /// Every password, with its note, into a CSV file the person chooses,
    /// after Touch ID or the Mac's password once more: the file holds them as
    /// plain text, and anyone at the open window could ask for it.
    static func export(_ profile: Profile) {
        Task {
            guard await AutoFill.ownerConfirms("export your saved passwords") else { return }
            guard let logins = await profile.vault.everything() else {
                return Browser.tell("Couldn't export the passwords", "The keychain didn't hand them over.")
            }
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.commaSeparatedText]
            panel.nameFieldStringValue = "Nerda Passwords.csv"
            panel.message = "The file holds your passwords as plain text. Sign-ins with Google and other services have no password, and are left out."
            panel.prompt = "Export"
            guard panel.runModal() == .OK, let file = panel.url else { return }
            do {
                try Data(PasswordsFile.csv(logins).utf8).write(to: file, options: [.atomic, .completeFileProtection])
            } catch {
                Browser.tell("Couldn't export the passwords", error.localizedDescription)
            }
        }
    }
}
