import AppKit
import Observation
import os
import Security

/// A signed program other than Nerda's own command line that connected to
/// the agent socket: told apart by its designated requirement, which its
/// signature was checked to meet, and named for the owner by its file.
nonisolated struct AgentProgram: Codable, Hashable, Sendable {
    /// Its designated requirement, in the code signing language: the same
    /// for every run and update of the program, as its signer decides.
    let id: String
    /// What the owner knows it as: its app's name, or its file's.
    let name: String
    let path: String

    init(id: String, name: String, path: String) {
        self.id = id
        self.name = name
        self.path = path
    }

    /// The program running as `code`, if it is signed and meets its own
    /// designated requirement; a program claiming another's requirement
    /// doesn't.
    init?(_ code: SecCode) {
        var designated: SecRequirement?, text: CFString?, url: CFURL?, file: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &file) == errSecSuccess, let file,
              SecCodeCopyDesignatedRequirement(file, [], &designated) == errSecSuccess, let designated,
              SecCodeCheckValidity(code, [], designated) == errSecSuccess,
              SecRequirementCopyString(designated, [], &text) == errSecSuccess, let text,
              SecCodeCopyPath(file, [], &url) == errSecSuccess, let url = url as URL? else { return nil }
        self.init(id: text as String, name: Self.name(of: url), path: url.path)
    }

    /// An app's name for a program inside its bundle, else the file's.
    private static func name(of url: URL) -> String {
        var folder = url
        while folder.pathComponents.count > 1 {
            if folder.pathExtension == "app" { return FileManager.default.displayName(atPath: folder.path) }
            folder.deleteLastPathComponent()
        }
        return url.lastPathComponent
    }
}

/// The owner's say over which other programs may drive Nerda: each one is
/// asked about once, on a sheet, and gets status only until allowed. Allow
/// once lasts until Nerda quits; Always and Don't allow are kept, and listed
/// in Settings › Security & Privacy › Agents to be removed.
@MainActor
@Observable
final class AgentApprovals {
    enum Choice: String, Codable, Sendable {
        /// Until Nerda quits.
        case once
        case always
        case never
    }

    /// Asks the owner about a program; nil when they made no choice, as
    /// when the window closed under the sheet.
    typealias Ask = @MainActor (AgentProgram) async -> Choice?

    /// A kept choice.
    struct Remembered: Codable, Hashable, Identifiable {
        let program: AgentProgram
        let allowed: Bool
        var id: String { program.id }
    }

    static let key = "agentPrograms"

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let ask: Ask
    /// The choices kept, by name.
    private(set) var remembered: [Remembered]
    /// Allowed once, until Nerda quits.
    @ObservationIgnored private var allowedOnce: Set<String> = []
    /// Programs to ask about, the first being asked.
    @ObservationIgnored private var asking: [AgentProgram] = []

    init(defaults: UserDefaults = .standard, ask: @escaping Ask = AgentApprovals.sheet) {
        self.defaults = defaults
        self.ask = ask
        remembered = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([Remembered].self, from: $0) } ?? []
    }

    /// Whether the owner allowed the program (true), didn't (false), or
    /// hasn't said yet (nil).
    func decision(for program: AgentProgram) -> Bool? {
        if allowedOnce.contains(program.id) { return true }
        return remembered.first { $0.program.id == program.id }?.allowed
    }

    /// Asks the owner about the program, unless they are already asked.
    func askAbout(_ program: AgentProgram) {
        guard decision(for: program) == nil, !asking.contains(where: { $0.id == program.id }) else { return }
        asking.append(program)
        if asking.count == 1 { Task { await askInTurn() } }
    }

    /// Forgets the owner's choice: the program is asked about again.
    func forget(_ program: AgentProgram) {
        allowedOnce.remove(program.id)
        remembered.removeAll { $0.program.id == program.id }
        save()
    }

    /// One question at a time, in the order the programs came.
    private func askInTurn() async {
        while let program = asking.first {
            let choice = await ask(program)
            asking.removeFirst()
            switch choice {
            case .once: allowedOnce.insert(program.id)
            case .always, .never:
                remembered.removeAll { $0.program.id == program.id }
                remembered.append(Remembered(program: program, allowed: choice == .always))
                remembered.sort { $0.program.name.localizedStandardCompare($1.program.name) == .orderedAscending }
                save()
            case nil: break
            }
        }
    }

    private func save() {
        defaults.set(try? JSONEncoder().encode(remembered), forKey: Self.key)
    }

    // MARK: The sheet

    /// Asks on a sheet over the owner's window, which doesn't bring Nerda
    /// forward. With no window open, it waits for the owner to open one.
    static func sheet(_ program: AgentProgram) async -> Choice? {
        let window = await ownersWindow()
        let alert = NSAlert()
        alert.messageText = "Allow “\(program.name)” to use Nerda?"
        alert.informativeText = """
            It wants to open pages and act in them as you, signed in to your sites. \
            Allow only a program you trust. Allow once lasts until Nerda quits.

            \(program.path)
            """
        alert.addButton(withTitle: "Allow once")
        alert.addButton(withTitle: "Always")
        alert.addButton(withTitle: "Don't allow")
        // Return pressed while typing in the window mustn't let a program in.
        alert.buttons[0].keyEquivalent = ""
        alert.buttons[2].keyEquivalent = "\u{1b}"
        return switch await alert.beginSheetModal(for: window) {
        case .alertFirstButtonReturn: .once
        case .alertSecondButtonReturn: .always
        case .alertThirdButtonReturn: .never
        default: nil
        }
    }

    /// The owner's window in front of the others, not an incognito one and
    /// not one already showing a sheet; once there is one.
    private static func ownersWindow() async -> NSWindow {
        while true {
            let window = NSApp.orderedWindows.first {
                guard let window = $0 as? BrowserWindow else { return false }
                return window.isVisible && !window.browser.isPrivate && window.attachedSheet == nil
            }
            if let window { return window }
            // A rare wait (no window yet, as after a hidden start), cheaply looked at.
            try? await Task.sleep(for: .seconds(1))
        }
    }
}
