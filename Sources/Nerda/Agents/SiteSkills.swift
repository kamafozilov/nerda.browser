import AppKit

/// A Site skill (GLOSSARY.md): written know-how about one site, or a few,
/// that an agent is pointed to when it gets there. A file of Markdown with
/// its name, what it is for and the sites it covers on top:
///
///     ---
///     name: github
///     description: Reading repositories, issues and pull requests on GitHub
///     sites: github.com, gist.github.com
///     ---
///
///     What works on the site…
nonisolated struct SiteSkill: Equatable, Sendable {
    let name: String
    /// One line on what it is for, which the hint and the list show.
    let description: String
    /// The hosts it covers, each with every host under it.
    let sites: [String]
    /// The know-how itself.
    let text: String
    /// Nerda's own, shipped in the app, rather than the owner's.
    var isBuiltIn = false

    /// The longest skill an agent may save, its file whole.
    static let mostCharacters = 20_000
    /// The most sites one skill covers.
    static let mostSites = 20

    /// The skill as its file says it.
    var file: String {
        """
        ---
        name: \(name)
        description: \(description)
        sites: \(sites.joined(separator: ", "))
        ---

        \(text)

        """
    }

    init(name: String, description: String, sites: [String], text: String, isBuiltIn: Bool = false) {
        self.name = name
        self.description = description
        self.sites = sites
        self.text = text
        self.isBuiltIn = isBuiltIn
    }

    /// A skill's file read; nil when it has no sites, as then it is no
    /// skill. The name is the file's, `named`, unless it gives one.
    init?(file: String, named: String, isBuiltIn: Bool = false) {
        var lines = file.components(separatedBy: .newlines)[...]
        var fields: [String: String] = [:]
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---" {
            lines = lines.dropFirst()
            while let line = lines.first, line.trimmingCharacters(in: .whitespaces) != "---" {
                lines = lines.dropFirst()
                guard let colon = line.firstIndex(of: ":") else { continue }
                fields[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] =
                    line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            lines = lines.dropFirst()
        }
        let sites = (fields["sites"] ?? "").split(separator: ",").compactMap { Self.host(String($0)) }
        guard !sites.isEmpty else { return nil }
        self.init(name: fields["name"].flatMap { $0.isEmpty ? nil : $0 } ?? named,
                  description: fields["description"] ?? "", sites: sites,
                  text: lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines),
                  isBuiltIn: isBuiltIn)
    }

    /// Whether it covers `host`: one of its sites, or a host under one.
    func covers(_ host: String) -> Bool {
        let host = host.lowercased()
        return sites.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// The host a site is written as, such as "github.com" for
    /// "https://www.github.com/"; nil for none.
    static func host(_ site: String) -> String? {
        let site = site.trimmingCharacters(in: .whitespaces).lowercased()
        guard !site.isEmpty, !site.contains(" ") else { return nil }
        guard var host = URL(string: site.contains("://") ? site : "https://" + site)?.host() else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host.isEmpty ? nil : host
    }

    /// Whether `name` will do as a skill's name and its file's: lowercase
    /// letters, digits and single hyphens, 40 at most.
    static func isName(_ name: String) -> Bool {
        name.count <= 40 && name.wholeMatch(of: /[a-z0-9]+(-[a-z0-9]+)*/) != nil
    }
}

/// What the owner is shown when an agent asks to save a skill: all of it,
/// who asks, and what it would take the place of.
struct SiteSkillCard {
    let skill: SiteSkill
    /// The agent asking, as the owner knows it: Claude, Codex.
    let asker: String
    /// The skill of that name there is now, the owner's or Nerda's.
    let replacing: SiteSkill?
}

/// Every Site skill agents can read: Nerda's own, and the owner's in the
/// data folder (`Skills`, one `<name>.md` each), where a skill wins over
/// Nerda's of the same name. The first answer an Agent session has on a
/// covered site names its skills (`hint`); an agent saves one only once the
/// owner approved it on a card.
@MainActor
final class SiteSkills {
    /// Shows the owner a card; true to save, false not to, nil when they
    /// made no choice (the window closed under it).
    typealias Approve = @MainActor (SiteSkillCard) async -> Bool?

    /// An agent's skill waiting for the owner, or answered and not yet told.
    final class Proposal {
        enum Answer: Equatable {
            case saved
            case declined
            case failed(String)
        }

        let skill: SiteSkill
        let session: AgentSessionName
        fileprivate(set) var answer: Answer?

        fileprivate init(skill: SiteSkill, session: AgentSessionName) {
            self.skill = skill
            self.session = session
        }
    }

    /// The owner's skills.
    let folder: URL
    let builtIn: [SiteSkill]
    private let approve: Approve
    /// The skills each session was pointed to already.
    private var hinted: [AgentSessionName: Set<String>] = [:]
    private var proposals: [Proposal] = []

    init(folder: URL, builtIn: [SiteSkill] = SiteSkill.builtIn, approve: @escaping Approve = SiteSkills.card) {
        self.folder = folder
        self.builtIn = builtIn
        self.approve = approve
    }

    /// Every skill, by name, the owner's in place of Nerda's of the same
    /// name. The folder is read each time: the owner may edit it by hand.
    var all: [SiteSkill] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let owners = files.filter { $0.pathExtension.lowercased() == "md" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { file in
                (try? String(contentsOf: file, encoding: .utf8))
                    .flatMap { SiteSkill(file: $0, named: file.deletingPathExtension().lastPathComponent) }
            }
        let names = Set(owners.map(\.name))
        return (owners + builtIn.filter { !names.contains($0.name) }).sorted { $0.name < $1.name }
    }

    func named(_ name: String) -> SiteSkill? {
        let name = name.trimmingCharacters(in: .whitespaces).lowercased()
        return all.first { $0.name.lowercased() == name }
    }

    /// The header lines pointing the session to the skills covering `url`
    /// it wasn't pointed to yet; none after that.
    func hint(for url: URL?, in session: AgentSessionName) -> [String] {
        guard let host = url?.host(), ["http", "https"].contains(url?.scheme?.lowercased()) else { return [] }
        let new = all.filter { $0.covers(host) && !(hinted[session]?.contains($0.name) ?? false) }
        guard !new.isEmpty else { return [] }
        hinted[session, default: []].formUnion(new.map(\.name))
        return new.map { skill in
            let about = skill.description.isEmpty ? "" : " (\(skill.description))"
            return "skill: \(skill.name)\(about), a Site skill for this site: read it with skill before you go on"
        }
    }

    /// The session's skill for the owner to approve: the same one asked
    /// before, waiting or answered and not yet told, or a new card.
    func propose(_ skill: SiteSkill, by session: AgentSession) -> Proposal {
        if let same = proposals.first(where: { $0.session == session.name && $0.skill == skill }) { return same }
        let proposal = Proposal(skill: skill, session: session.name)
        proposals.append(proposal)
        let card = SiteSkillCard(skill: skill, asker: session.title, replacing: named(skill.name))
        Task {
            let approved = await approve(card) ?? false
            guard approved else {
                proposal.answer = .declined
                return
            }
            do {
                try save(skill)
                proposal.answer = .saved
            } catch {
                proposal.answer = .failed(error.localizedDescription)
            }
        }
        return proposal
    }

    /// The proposal's answer once it comes, or nil if `wait` runs out
    /// first. An answer is told once.
    func answer(to proposal: Proposal, within wait: Duration) async throws -> Proposal.Answer? {
        let until = ContinuousClock.now + wait
        while proposal.answer == nil, ContinuousClock.now < until {
            try await Task.sleep(for: .milliseconds(100))
        }
        guard let answer = proposal.answer else { return nil }
        proposals.removeAll { $0 === proposal }
        return answer
    }

    /// Writes the skill as the owner's, in place of one of the same name.
    private func save(_ skill: SiteSkill) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let mine = SiteSkill(name: skill.name, description: skill.description, sites: skill.sites, text: skill.text)
        try mine.file.write(to: folder.appending(path: "\(skill.name).md"), atomically: true, encoding: .utf8)
    }

    // MARK: The card

    /// The skill whole, on a sheet over the owner's window that doesn't
    /// bring Nerda forward; with no window open, once they open one.
    static func card(_ card: SiteSkillCard) async -> Bool? {
        guard let window = await AgentApprovals.ownersWindow() else { return nil }
        let skill = card.skill
        let alert = NSAlert()
        alert.messageText = "\(card.asker) wants to save a Site skill"
        var about = "“\(skill.name)”, for \(skill.sites.joined(separator: ", ")). Agents on "
            + (skill.sites.count == 1 ? "this site" : "these sites") + " will be pointed to it and follow it."
        if let replacing = card.replacing {
            about += replacing.isBuiltIn
                ? " It takes the place of Nerda's own “\(replacing.name)”."
                : " It replaces your “\(replacing.name)”."
        }
        alert.informativeText = about + " Save it only if what it says is right."

        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 520, height: 320))
        text.string = skill.file
        text.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        text.isEditable = false
        text.textContainerInset = NSSize(width: 6, height: 6)
        text.autoresizingMask = [.width]
        let scroll = NSScrollView(frame: text.frame)
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        alert.accessoryView = scroll

        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        // Return pressed while typing in the window mustn't save it.
        alert.buttons[0].keyEquivalent = ""
        alert.buttons[1].keyEquivalent = "\u{1b}"
        return switch await alert.beginSheetModal(for: window) {
        case .alertFirstButtonReturn: true
        case .alertSecondButtonReturn: false
        default: nil
        }
    }
}

/// Reading Site skills, and saving one with the owner's approval. `skill`,
/// which the hint on a covered site names, is listed from the start;
/// `skill_save` is the skills group (`more_tools`).
nonisolated extension AgentVerb {
    static let skillVerbs: [AgentVerb] = [skill, skillSave]

    static let skill = AgentVerb(
        name: "skill",
        summary: """
            Read a Site skill: what is known to work on a site, written by the user or saved by an agent \
            before. The first answer on a site that has one names it. Without a name, lists them all.
            """,
        arguments: [.string("name", "The skill's name, such as github", required: false)],
        readOnly: true
    ) { call in
        let skills = call.server.skills
        guard let name = call.optionalString("name")?.trimmingCharacters(in: .whitespaces), !name.isEmpty else {
            let all = skills.all
            guard !all.isEmpty else { return "No Site skills yet. Save one with skill_save." }
            return "Site skills; read one with skill and its name:\n" + all.map { skill in
                let about = skill.description.isEmpty ? "" : ": \(skill.description)"
                return "\(skill.name)\(about) (\(skill.sites.joined(separator: ", "))\(skill.isBuiltIn ? "; Nerda's own" : ""))"
            }.joined(separator: "\n")
        }
        guard let skill = skills.named(name) else {
            let names = skills.all.map(\.name)
            throw AgentError(.invalid, "There is no Site skill \(name)."
                + (names.isEmpty ? "" : " The skills: \(names.joined(separator: ", "))."))
        }
        return """
            skill: \(skill.name)\(skill.isBuiltIn ? " (Nerda's own)" : "")
            for: \(skill.description)
            sites: \(skill.sites.joined(separator: ", "))

            \(skill.text)
            """
    }

    static let skillSave = AgentVerb(
        name: "skill_save",
        summary: """
            Save a Site skill for the next agent on a site: what you found works there, short and exact. \
            The user reads it whole on a card in Nerda and saves it or not; it replaces a skill of the same \
            name. Answers needs_user while they haven't: tell the user, then call skill_save again with the \
            same skill to keep waiting.
            """,
        arguments: [
            .string("name", "A short name: lowercase letters, digits and hyphens, such as github"),
            .string("description", "One line on what it is for, such as \"Ordering on example.com\""),
            AgentArgument(name: "sites", schema: [
                "type": "array", "items": ["type": "string"], "minItems": 1,
                "description": "The sites it covers, such as [\"example.com\"]; each covers the hosts under it too",
            ], required: true),
            .string("text", "The know-how, in Markdown, up to \(SiteSkill.mostCharacters) characters with the rest"),
        ],
        group: .skills, waitsForOwner: true
    ) { call in
        let name = try call.string("name").trimmingCharacters(in: .whitespaces)
        guard SiteSkill.isName(name) else {
            throw AgentError(.invalid, "\(name) won't do as a name: use lowercase letters, digits and hyphens, such as shop-orders.")
        }
        let description = (call.optionalString("description") ?? "").replacing(/\s+/, with: " ")
            .trimmingCharacters(in: .whitespaces)
        let named = call.arguments["sites"]?.array?.compactMap(\.string) ?? []
        let sites = named.compactMap(SiteSkill.host)
        guard !sites.isEmpty, sites.count == named.count, sites.count <= SiteSkill.mostSites else {
            throw AgentError(.invalid, "Give sites as one to \(SiteSkill.mostSites) sites, such as [\"example.com\"].")
        }
        let text = try call.string("text").trimmingCharacters(in: .whitespacesAndNewlines)
        let skill = SiteSkill(name: name, description: description, sites: sites, text: text)
        guard skill.file.count <= SiteSkill.mostCharacters else {
            throw AgentError(.invalid, """
                That skill is \(skill.file.count) characters; a Site skill holds \(SiteSkill.mostCharacters) \
                at most. Keep what the next agent needs.
                """)
        }
        let proposal = call.server.skills.propose(skill, by: call.session)
        guard let answer = try await call.server.skills.answer(to: proposal, within: waitOnOwner(call)) else {
            throw AgentError.needsUser("Nerda shows the user the skill \(name) to save, and they haven't answered yet.",
                                       waitingIn: "in Nerda's window", again: "skill_save with the same skill")
        }
        switch answer {
        case .saved:
            return "The user approved; saved the Site skill \(name). Agents on \(sites.joined(separator: ", ")) are pointed to it."
        case .declined:
            return "The user didn't save the Site skill \(name). Go on without it."
        case .failed(let why):
            throw AgentError(.failed, "The user approved the Site skill \(name), but it couldn't be saved: \(why)")
        }
    }
}

extension AgentCall {
    /// The call being done, while its verb runs (`AgentServer`): what an
    /// answer's header needs to point its session to Site skills.
    @TaskLocal static var current: AgentCall?
}
