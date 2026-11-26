import AppKit
import SwiftUI

/// AI agents on this Mac and Nerda: whether they may use it at all, how it
/// goes in three steps, each agent with its mark, whether it is connected
/// and the button for it (what `Nerda setup` does from Terminal), the
/// command for scripts, and the other programs that asked.
struct AgentsSettings: View {
    let browser: Browser

    @AppStorage(AgentServer.isOnKey) private var agentsCanUseNerda = true
    /// Other programs the owner allowed or not, when they asked to use Nerda.
    private let approvals = AgentServer.shared.approvals
    var connections = AgentConnections.shared

    var body: some View {
        SettingsGroup {
            SettingsRow(title: "Agents can use Nerda", detail: "Agents browse in tabs of their own, signed in as you",
                        icon: "sparkles") {
                SettingsToggle(title: "Agents can use Nerda", isOn: $agentsCanUseNerda)
            }
        }
        .task { await connections.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await connections.refresh() }
        }
        if let setup = connections.setup {
            SettingsGroup(title: "How it works") {
                Step(number: 1, title: "Connect your agent",
                     detail: "Press Connect beside your agent below. Nerda adds itself, with a guide to using it")
                Step(number: 2, title: "Ask it for something on the web",
                     detail: "In a new session, for example: “Check my GitHub notifications” or “Find my last order on Amazon”")
                Step(number: 3, title: "It works in tabs of its own",
                     detail: "Signed in as you, out of your way. Watch it from the sidebar. Sign-ins, codes and payments come to you")
            }
            SettingsGroup(title: "Your agents") {
                ConnectedAgentRow(part: .claude, browser: browser, connections: connections)
                ConnectedAgentRow(part: .codex, browser: browser, connections: connections)
            }
            SettingsGroup(title: "For scripts") {
                CommandRow(name: setup.name, places: setup.places, connections: connections)
            }
        } else {
            SettingsGroup(title: "Your agents") {
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

/// One of the three steps, by its number.
private struct Step: View {
    let number: Int
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.ink)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.primary.opacity(0.08)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13.5))
                    .foregroundStyle(Palette.ink)
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
                    .lineSpacing(1.5)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
    }
}

/// An agent: its mark, its name, whether it is connected, and the one
/// thing to do about it.
private struct ConnectedAgentRow: View {
    let part: AgentSetup.Part
    let browser: Browser
    let connections: AgentConnections

    var body: some View {
        let link = connections.links[part]
        HStack(spacing: 12) {
            logo
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(Palette.ink)
                    if let link { Status(link: link) }
                }
                Text(connections.problems[part] ?? link.map(detail) ?? " ")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
                    .lineSpacing(1.5)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 16)
            if connections.busy.contains(part) {
                ProgressView().controlSize(.small)
            } else {
                switch link {
                case .on?:
                    Button("Disconnect") { Task { await connections.disconnect(part) } }
                        .buttonStyle(SettingsButtonStyle())
                        .fixedSize()
                case .off?, .other?:
                    Button("Connect") { Task { await connections.connect(part) } }
                        .buttonStyle(SettingsButtonStyle(prominent: true))
                        .fixedSize()
                case .missing?:
                    Button("Get \(title)") { _ = browser.open(site) }
                        .buttonStyle(SettingsButtonStyle())
                        .fixedSize()
                case .taken?, nil:
                    EmptyView()
                }
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 12)
        .frame(minHeight: 64)
    }

    private var title: String { part == .claude ? "Claude Code" : "Codex" }

    /// Where to get it.
    private var site: URL {
        URL(string: part == .claude ? "https://claude.com/product/claude-code" : "https://openai.com/codex/")!
    }

    /// The agent's mark on a tile, as an app's is on the Dock.
    private var logo: some View {
        let image = part == .claude ? AgentLogo.claude : AgentLogo.openAI
        return Image(nsImage: image)
            .resizable()
            .renderingMode(part == .claude ? .original : .template)
            .foregroundStyle(Palette.ink)
            .aspectRatio(contentMode: .fit)
            .frame(width: 20, height: 20)
            .frame(width: 36, height: 36)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
    }

    private func detail(_ link: AgentSetup.Link) -> String {
        switch link {
        case .missing: "Not on this Mac yet. Install it, then connect it here"
        case .off: "Connect to let \(title) use Nerda"
        case .on: "Ready. New sessions can use Nerda"
        case .other: "Connected to another copy of Nerda. Connect to use this one"
        case .taken: ""
        }
    }
}

/// Connected or not, as a coloured dot and a word.
private struct Status: View {
    let link: AgentSetup.Link

    var body: some View {
        let (word, color): (String, Color) = switch link {
        case .on: ("Connected", .green)
        case .other: ("Needs connecting", .orange)
        case .missing: ("Not installed", Palette.muted)
        case .off, .taken: ("Not connected", Palette.muted)
        }
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(word)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(link == .on ? Palette.ink : Palette.muted)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
    }
}

/// The `nerda-browser` command, for scripts and for agents that run
/// commands rather than connect.
private struct CommandRow: View {
    let name: String
    let places: AgentSetup.Places
    let connections: AgentConnections

    var body: some View {
        let link = connections.links[.command]
        SettingsRow(title: "\(name) command", detail: connections.problems[.command] ?? link.map(detail), icon: "terminal") {
            if connections.busy.contains(.command) {
                ProgressView().controlSize(.small)
            } else {
                switch link {
                case .on?:
                    Button("Remove") { Task { await connections.disconnect(.command) } }
                        .buttonStyle(SettingsButtonStyle())
                        .fixedSize()
                case .off?, .other?:
                    Button("Install") { Task { await connections.connect(.command) } }
                        .buttonStyle(SettingsButtonStyle())
                        .fixedSize()
                case .missing?, .taken?, nil:
                    EmptyView()
                }
            }
        }
    }

    private func detail(_ link: AgentSetup.Link) -> String {
        let command = places.show(places.commands.appending(path: name))
        return switch link {
        case .on: "Installed as \(command). Try \(name) open nerda.dev"
        case .other: "\(command) runs another copy of Nerda. Install to run this one"
        case .taken: "\(command) is another program's. Nerda leaves it alone"
        case .off, .missing: "Use Nerda from Terminal and scripts"
        }
    }
}
