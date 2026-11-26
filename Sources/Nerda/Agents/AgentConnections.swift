import Foundation
import Observation

/// Settings › Agents: whether each agent is connected to Nerda, and the
/// button that connects or disconnects it, the same steps `Nerda setup`
/// takes for all of them at once (`AgentSetup`). The steps read the agents'
/// settings and run `claude`, which takes a few seconds, so they run off
/// the main thread while the row shows a spinner.
@Observable
final class AgentConnections {
    static let shared = AgentConnections(setup: AgentSetup.installed())

    /// The edition's setup; nil where agents don't connect (Nerda Test).
    let setup: AgentSetup?
    /// How each part stood when last read; nil before the first reading.
    private(set) var links: [AgentSetup.Part: AgentSetup.Link] = [:]
    /// The parts being connected or disconnected.
    private(set) var busy: Set<AgentSetup.Part> = []
    /// What went wrong the last time a part was connected or disconnected.
    private(set) var problems: [AgentSetup.Part: String] = [:]

    init(setup: AgentSetup?) {
        self.setup = setup
    }

    /// Reads how each part stands again: when the page opens, and when
    /// Nerda comes back to the front (an agent installed meanwhile).
    func refresh() async {
        guard let setup else { return }
        links = await Self.read(setup)
    }

    func connect(_ part: AgentSetup.Part) async {
        await change(part) { $0.connect(part) }
    }

    func disconnect(_ part: AgentSetup.Part) async {
        await change(part) { $0.disconnect(part) }
    }

    private func change(_ part: AgentSetup.Part, _ step: @escaping @Sendable (AgentSetup) -> AgentSetup.Report) async {
        guard let setup, !busy.contains(part) else { return }
        busy.insert(part)
        problems[part] = nil
        let report = await Task.detached(priority: .userInitiated) { step(setup) }.value
        links = await Self.read(setup)
        busy.remove(part)
        if report.failed {
            // The step's own line, without the agent's name the row shows already.
            let line = report.lines.last { $0.contains("couldn't") || $0.contains("isn't Nerda's") } ?? report.lines.last ?? ""
            problems[part] = line.split(separator: ":", maxSplits: 1).last.map { $0.trimmingCharacters(in: .whitespaces) } ?? line
        }
    }

    @concurrent private static func read(_ setup: AgentSetup) async -> [AgentSetup.Part: AgentSetup.Link] {
        Dictionary(uniqueKeysWithValues: AgentSetup.Part.allCases.map { ($0, setup.link($0)) })
    }
}
