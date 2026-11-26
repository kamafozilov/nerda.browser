import AppKit
import SwiftUI

/// AI agents on this Mac and Nerda: whether they may use it at all, each
/// one connected or not with a button for it (what `Nerda setup` does from
/// Terminal), and the other programs that asked.
struct AgentsSettings: View {
    @AppStorage(AgentServer.isOnKey) private var agentsCanUseNerda = true
    /// Other programs the owner allowed or not, when they asked to use Nerda.
    private let approvals = AgentServer.shared.approvals
    private var connections: AgentConnections { .shared }

    var body: some View {
        SettingsGroup {
            SettingsRow(title: "Agents can use Nerda",
                        detail: "Agents browse in tabs of their own, signed in as you",
                        icon: "sparkles") {
                SettingsToggle(title: "Agents can use Nerda", isOn: $agentsCanUseNerda)
            }
        }
        .task { await connections.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await connections.refresh() }
        }
        SettingsGroup(title: "Connect your agents") {
            if let setup = connections.setup {
                ForEach(AgentSetup.Part.allCases) { part in
                    ConnectionRow(part: part, name: setup.name, places: setup.places)
                }
            } else {
                SettingsRow(title: "\(Edition.name) doesn't connect to agents", detail: "Agents use Nerda itself", icon: "sparkles") {
                    EmptyView()
                }
            }
        }
        if !approvals.remembered.isEmpty {
            SettingsGroup(title: "Other programs") {
                ForEach(approvals.remembered) { choice in
                    SettingsRow(title: choice.program.name,
                                detail: (choice.allowed ? "Always allowed" : "Not allowed") + " · " + choice.program.path,
                                icon: choice.allowed ? "terminal" : "nosign") {
                        Button("Remove") { approvals.forget(choice.program) }
                            .buttonStyle(SettingsButtonStyle())
                            .fixedSize()
                            .help("Ask again the next time \(choice.program.name) tries to use Nerda")
                    }
                }
            }
        }
    }
}

/// One agent, or the command: how it stands, and the one thing to do about it.
private struct ConnectionRow: View {
    let part: AgentSetup.Part
    /// What Nerda registers as: nerda-browser, or nerda-browser-dev.
    let name: String
    let places: AgentSetup.Places
    private var connections: AgentConnections { .shared }

    var body: some View {
        let link = connections.links[part]
        SettingsRow(title: title, detail: connections.problems[part] ?? link.map(detail), icon: icon) {
            if connections.busy.contains(part) {
                ProgressView().controlSize(.small)
            } else {
                switch link {
                case .on?:
                    Button(part == .command ? "Remove" : "Disconnect") { Task { await connections.disconnect(part) } }
                        .buttonStyle(SettingsButtonStyle())
                        .fixedSize()
                case .off?, .other?:
                    Button(part == .command ? "Install" : "Connect") { Task { await connections.connect(part) } }
                        .buttonStyle(SettingsButtonStyle(prominent: true))
                        .fixedSize()
                case .missing?, .taken?, nil:
                    EmptyView()
                }
            }
        }
    }

    private var title: String {
        switch part {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .command: "Command line"
        }
    }

    private var icon: String {
        switch part {
        case .claude: "asterisk"
        case .codex: "curlybraces"
        case .command: "terminal"
        }
    }

    private func detail(_ link: AgentSetup.Link) -> String {
        let command = places.show(places.commands.appending(path: name))
        return switch (part, link) {
        case (.claude, .missing): "Not on this Mac. Install Claude Code, then connect it here"
        case (.codex, .missing): "Not on this Mac. Install Codex, then connect it here"
        case (.command, .on): "Installed as \(command)"
        case (.command, .off): "Lets scripts and agents run \(name) in Terminal"
        case (.command, .other): "\(command) runs another copy of Nerda. Install to run this one"
        case (.command, _): "\(command) is another program's. Nerda leaves it alone"
        case (_, .on): "Connected as \(name). New sessions can use Nerda"
        case (_, .other): "Connected to another copy of Nerda. Connect to use this one"
        case (_, _): "Not connected"
        }
    }
}
