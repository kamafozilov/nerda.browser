import Foundation
import Testing
@testable import Nerda

/// Setting up (spec #119, ticket #131): one command registers
/// nerda-browser with Claude Code and Codex, writes the skill for both and
/// puts the command on PATH. Every test works in a home folder of its own,
/// with a stand-in `claude` program: never the owner's real configs.
struct AgentSetupTests {
    static let app = URL(fileURLWithPath: "/Applications/Nerda.app/Contents/MacOS/Nerda")

    /// Setup registers the MCP server with both agents and writes the skill
    /// for each; their other settings and the owner's own instruction files
    /// stay as they were.
    @Test func setupRegistersBothAgentsAndWritesTheSkill() throws {
        let home = try TestHome()
        defer { home.remove() }
        let codexBefore = """
            model = "gpt-6"

            [mcp_servers.pencil]
            command = "/Applications/Pencil.app/Contents/MacOS/pencil"
            args = ["mcp"]

            [profiles.fast]
            model = "gpt-6-mini"

            """
        try home.write(".codex/config.toml", codexBefore)
        try home.write(".claude/CLAUDE.md", "# My rules\n")
        try home.write(".agents/AGENTS.md", "# Shared rules\n")

        let report = try home.setup().run()

        #expect(!report.failed, "\(report.lines)")
        #expect(report.changed)
        // Claude Code: its own command, at user scope, with Nerda's binary in mcp mode.
        #expect(home.claudeCalls.contains("mcp add --scope user nerda-browser -- \(Self.app.path) mcp"))
        // Codex: a table of its own, with a long tool timeout, the rest untouched.
        let codex = try home.read(".codex/config.toml")
        #expect(codex.hasPrefix(codexBefore))
        #expect(codex.contains("""
            [mcp_servers.nerda-browser]
            command = "\(Self.app.path)"
            args = ["mcp"]
            tool_timeout_sec = 660
            """))
        // The skill, for both, naming every verb and the command.
        for skill in [".claude/skills/nerda-browser/SKILL.md", ".codex/skills/nerda-browser/SKILL.md"] {
            let text = try home.read(skill)
            #expect(text.hasPrefix("---\nname: nerda-browser\ndescription: "))
            for verb in AgentVerb.all { #expect(text.contains("`\(verb.name)`")) }
            #expect(text.contains("nerda-browser open https://"))
        }
        // The owner's global instruction files: not Nerda's to change.
        #expect(try home.read(".claude/CLAUDE.md") == "# My rules\n")
        #expect(try home.read(".agents/AGENTS.md") == "# Shared rules\n")
    }

    /// The command on PATH runs Nerda's own binary as the command line, so
    /// Nerda knows it as its own; a file of that name not Nerda's is left alone.
    @Test func setupInstallsTheCommandOnPath() throws {
        let home = try TestHome()
        defer { home.remove() }
        _ = try home.setup().run()

        let command = home.folder.appending(path: ".local/bin/nerda-browser")
        let script = try String(contentsOf: command, encoding: .utf8)
        #expect(script.hasPrefix("#!/bin/sh\n"))
        #expect(script.contains("exec '\(Self.app.path)' cli \"$@\""))
        #expect(FileManager.default.isExecutableFile(atPath: command.path))

        let other = try TestHome()
        defer { other.remove() }
        try other.write(".local/bin/nerda-browser", "#!/bin/sh\necho someone else's\n")
        let report = try other.setup().run()
        #expect(report.failed)
        #expect(report.lines.contains { $0.contains("isn't Nerda's") })
        #expect(try other.read(".local/bin/nerda-browser") == "#!/bin/sh\necho someone else's\n")
    }

    /// The command on PATH, run with the help flag, really is Nerda's
    /// command line: the script runs the program it names with `cli`.
    @Test func theInstalledCommandRunsTheBinaryAsTheCommandLine() throws {
        let home = try TestHome()
        defer { home.remove() }
        // A stand-in binary that says what it was asked.
        let binary = home.folder.appending(path: "Nerda Dev.app/Contents/MacOS/Nerda Dev")
        try home.write("Nerda Dev.app/Contents/MacOS/Nerda Dev", "#!/bin/sh\necho \"$@\"\n", executable: true)
        _ = try home.setup(executable: binary, dev: true, edition: "Nerda Dev").run()

        let output = try home.runProgram(home.folder.appending(path: ".local/bin/nerda-browser-dev"), ["open", "it's here"])
        #expect(output == "cli open it's here\n")
    }

    /// Running setup a second time changes nothing: no file is written
    /// again and Claude Code isn't asked again.
    @Test func runningSetupTwiceChangesNothing() throws {
        let home = try TestHome()
        defer { home.remove() }
        try home.write(".codex/config.toml", "model = \"gpt-6\"\n")
        let first = try home.setup().run()
        #expect(first.changed)
        let files = [".codex/config.toml", ".claude.json", ".claude/skills/nerda-browser/SKILL.md",
                     ".codex/skills/nerda-browser/SKILL.md", ".local/bin/nerda-browser"]
        let before = try files.map { try home.snapshot($0) }
        let calls = home.claudeCalls

        let second = try home.setup().run()

        #expect(!second.changed, "\(second.lines)")
        #expect(!second.failed, "\(second.lines)")
        #expect(try files.map { try home.snapshot($0) } == before)
        #expect(home.claudeCalls == calls)
    }

    /// An older registration (Nerda moved, a hand-made table) is replaced
    /// where it stood, with nothing of it left.
    @Test func anOldCodexRegistrationIsReplacedInPlace() throws {
        let home = try TestHome()
        defer { home.remove() }
        try home.write(".codex/config.toml", """
            [mcp_servers.nerda-browser]
            command = "/old/Nerda"
            args = ["mcp"]

            [mcp_servers.nerda-browser.env]
            OLD = "1"

            [mcp_servers.pencil]
            command = "pencil"

            """)

        _ = try home.setup().run()

        #expect(try home.read(".codex/config.toml") == """
            [mcp_servers.nerda-browser]
            command = "\(Self.app.path)"
            args = ["mcp"]
            tool_timeout_sec = 660

            [mcp_servers.pencil]
            command = "pencil"

            """)
    }

    /// An agent that isn't installed is skipped, said so, and the other is
    /// still set up.
    @Test func anAgentNotInstalledIsSkipped() throws {
        let home = try TestHome(claude: false)
        defer { home.remove() }
        try FileManager.default.createDirectory(at: home.folder.appending(path: ".codex"), withIntermediateDirectories: true)

        let report = try home.setup().run()

        #expect(!report.failed, "\(report.lines)")
        #expect(report.lines.contains { $0.contains("Claude Code") && $0.contains("not found") })
        #expect(!FileManager.default.fileExists(atPath: home.folder.appending(path: ".claude").path))
        #expect(try home.read(".codex/config.toml").contains("[mcp_servers.nerda-browser]"))
    }

    /// Nerda rewrites the skill at launch when its text changed (Nerda
    /// updated), and only then; where setup never wrote it, it writes none.
    @Test func theSkillIsRewrittenAtLaunchOnlyWhenItChanged() throws {
        let home = try TestHome()
        defer { home.remove() }
        try FileManager.default.createDirectory(at: home.folder.appending(path: ".codex"), withIntermediateDirectories: true)
        #expect(try home.setup().refreshSkills().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: home.folder.appending(path: ".claude/skills/nerda-browser").path))

        _ = try home.setup().run()
        let claudeSkill = ".claude/skills/nerda-browser/SKILL.md"
        let before = try home.snapshot(claudeSkill)
        #expect(try home.setup().refreshSkills().isEmpty)
        #expect(try home.snapshot(claudeSkill) == before)

        // An older Nerda's skill: written again.
        try home.write(claudeSkill, "---\nname: nerda-browser\n---\nOld verbs\n")
        let rewritten = try home.setup().refreshSkills()
        #expect(rewritten.map(\.lastPathComponent) == ["SKILL.md"])
        #expect(try home.read(claudeSkill) == home.read(".codex/skills/nerda-browser/SKILL.md"))
    }

    /// Nerda Dev registers as nerda-browser-dev, and only when asked: plain
    /// setup in Nerda Dev does nothing, and a release Nerda's registration
    /// is left as it is.
    @Test func nerdaDevRegistersAsNerdaBrowserDevOnlyWhenAsked() throws {
        let home = try TestHome()
        defer { home.remove() }
        try home.write(".codex/config.toml", "")
        let dev = URL(fileURLWithPath: "/Users/me/nerda/build/Nerda Dev.app/Contents/MacOS/Nerda Dev")

        #expect(throws: AgentSetup.Refusal.self) { try home.setup(executable: dev, edition: "Nerda Dev") }
        #expect(throws: AgentSetup.Refusal.self) { try home.setup(edition: "Nerda Test") }
        #expect(throws: AgentSetup.Refusal.self) { try home.setup(dev: true) }
        #expect(home.claudeCalls.isEmpty)
        #expect(try home.read(".codex/config.toml") == "")

        _ = try home.setup().run()
        let report = try home.setup(executable: dev, dev: true, edition: "Nerda Dev").run()

        #expect(!report.failed, "\(report.lines)")
        #expect(home.claudeCalls.contains("mcp add --scope user nerda-browser-dev -- \(dev.path) mcp"))
        let codex = try home.read(".codex/config.toml")
        #expect(codex.contains("[mcp_servers.nerda-browser]\ncommand = \"\(Self.app.path)\""))
        #expect(codex.contains("[mcp_servers.nerda-browser-dev]\ncommand = \"\(dev.path)\""))
        let skill = try home.read(".claude/skills/nerda-browser-dev/SKILL.md")
        #expect(skill.hasPrefix("---\nname: nerda-browser-dev\n"))
        #expect(skill.contains("nerda-browser-dev open https://"))
        #expect(FileManager.default.fileExists(atPath: home.folder.appending(path: ".local/bin/nerda-browser-dev").path))
        #expect(try home.read(".claude/skills/nerda-browser/SKILL.md").hasPrefix("---\nname: nerda-browser\n"))
    }
}

/// A home folder of a test's own, with a stand-in `claude` that keeps what
/// it was asked and, asked to add a server, writes `.claude.json` as Claude
/// Code would.
struct TestHome {
    let folder: URL
    let claude: URL?

    init(claude: Bool = true) throws {
        folder = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "nerda-home-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard claude else {
            self.claude = nil
            return
        }
        let program = folder.appending(path: "programs/claude")
        self.claude = program
        try write("programs/claude", #"""
            #!/bin/sh
            # Called as: mcp add --scope user <name> -- <command> <argument>
            echo "$*" >> "$HOME/claude-calls.log"
            [ "$2" = "add" ] || exit 0
            [ -f "$HOME/.claude.json" ] || echo '{"mcpServers":{}}' > "$HOME/.claude.json"
            /usr/bin/plutil -remove "mcpServers.$5" "$HOME/.claude.json" 2>/dev/null
            /usr/bin/plutil -insert "mcpServers.$5" -json \
              "$(/usr/bin/printf '{"type":"stdio","command":"%s","args":["%s"],"env":{}}' "$7" "$8")" "$HOME/.claude.json"
            """#, executable: true)
    }

    func setup(executable: URL = AgentSetupTests.app, dev: Bool = false, edition: String = "Nerda") throws -> AgentSetup {
        let places = AgentSetup.Places(home: folder, environment: ["PATH": "/usr/bin:/bin"], claude: claude)
        return try AgentSetup(edition: edition, dev: dev, executable: executable, places: places,
                              environment: ["PATH": "/usr/bin:/bin", "HOME": folder.path])
    }

    var claudeCalls: [String] {
        let log = (try? String(contentsOf: folder.appending(path: "claude-calls.log"), encoding: .utf8)) ?? ""
        return log.split(separator: "\n").map(String.init)
    }

    func write(_ path: String, _ text: String, executable: Bool = false) throws {
        let file = folder.appending(path: path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: file, atomically: true, encoding: .utf8)
        if executable { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path) }
    }

    func read(_ path: String) throws -> String {
        try String(contentsOf: folder.appending(path: path), encoding: .utf8)
    }

    /// A file's text and when it was last written, to tell whether it was
    /// written again.
    func snapshot(_ path: String) throws -> String {
        let file = folder.appending(path: path)
        let date = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
        let inode = try FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as? Int
        return "\(date?.timeIntervalSince1970 ?? 0) \(inode ?? 0)\n" + (try read(path))
    }

    func runProgram(_ program: URL, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = program
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    func remove() { try? FileManager.default.removeItem(at: folder) }
}
