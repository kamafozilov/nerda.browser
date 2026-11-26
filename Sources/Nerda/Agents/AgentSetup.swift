import Foundation
import os

/// Setup (Settings › Agents, `Nerda setup`, `nerda-browser setup`):
/// connects Nerda to the owner's agents, in one go from the command line or
/// one agent at a time from Settings (`AgentConnections`), which can also
/// disconnect one. It registers the MCP server (`Nerda mcp`) with
/// Claude Code at user scope and with Codex, with a long tool timeout,
/// writes the skill for both (`AgentSkill`), and puts the `nerda-browser`
/// command on PATH. Run again, it changes nothing that is already so. The
/// owner's own instruction files (CLAUDE.md, AGENTS.md) are never touched.
///
/// Nerda registers as `nerda-browser`; Nerda Dev as `nerda-browser-dev`,
/// and only when asked (`setup --dev`), so agents never drive a development
/// build by mistake. Every place it writes comes in `Places`, so tests set
/// up a home folder of their own.
nonisolated struct AgentSetup {
    /// Where the agents keep their settings, and where commands go.
    struct Places {
        let home: URL
        /// Claude Code's folder: `CLAUDE_CONFIG_DIR`, or `~/.claude`.
        let claudeFolder: URL
        /// Where Claude Code keeps user-scope MCP servers.
        let claudeSettings: URL
        /// The `claude` program, if Claude Code is installed.
        let claude: URL?
        /// Codex's folder: `CODEX_HOME`, or `~/.codex`.
        let codexFolder: URL
        /// Where the command goes: `~/.local/bin`, on PATH as Claude
        /// Code's and Codex's own installers put it.
        let commands: URL

        init(home: URL, environment: [String: String], claude: URL?) {
            self.home = home
            let claudeConfig = environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            claudeFolder = claudeConfig ?? home.appending(path: ".claude")
            claudeSettings = claudeConfig?.appending(path: ".claude.json") ?? home.appending(path: ".claude.json")
            self.claude = claude
            codexFolder = environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
                ?? home.appending(path: ".codex")
            commands = home.appending(path: ".local/bin")
        }

        /// The owner's own, for the process run as `setup`.
        static func owners(environment: [String: String]) -> Places {
            let home = FileManager.default.homeDirectoryForCurrentUser
            return Places(home: home, environment: environment, claude: findClaude(home: home, environment: environment))
        }

        /// The `claude` program on PATH, or where Claude Code's installers
        /// put it (an alias in the owner's shell isn't seen from here).
        static func findClaude(home: URL, environment: [String: String]) -> URL? {
            let path = (environment["PATH"] ?? "").split(separator: ":").map { URL(fileURLWithPath: String($0)) }
            let usual = [".local/bin", ".claude/local", ".npm-global/bin", ".bun/bin"].map { home.appending(path: $0) }
                + ["/opt/homebrew/bin", "/usr/local/bin"].map { URL(fileURLWithPath: $0) }
            return (path + usual).map { $0.appending(path: "claude") }
                .first { FileManager.default.isExecutableFile(atPath: $0.path) }
        }

        /// A path as the owner reads it: `~/.codex/config.toml`.
        func show(_ url: URL) -> String {
            url.path.hasPrefix(home.path + "/") ? "~" + url.path.dropFirst(home.path.count) : url.path
        }
    }

    /// Setup won't run for this build as asked.
    struct Refusal: Error, CustomStringConvertible {
        let description: String
    }

    /// What setup did, one line a step.
    struct Report {
        var lines: [String] = []
        /// Something was written or registered.
        var changed = false
        /// A step couldn't be done.
        var failed = false

        mutating func did(_ line: String) { lines.append(line); changed = true }
        mutating func kept(_ line: String) { lines.append(line) }
        mutating func failed(_ line: String) { lines.append(line); failed = true }
    }

    /// `nerda-browser`, or `nerda-browser-dev` for Nerda Dev.
    let name: String
    /// The app's binary, which agents run as `mcp` and the command as `cli`.
    let executable: URL
    let places: Places
    /// What the programs setup runs (`claude`) are given.
    let environment: [String: String]
    let skill: String

    /// Setup for the edition (`Edition.name`) whose binary is `executable`.
    /// `dev` is the owner asking for Nerda Dev; without it Nerda Dev, and
    /// Nerda Test always, refuse.
    init(edition: String, dev: Bool, executable: URL, places: Places,
         environment: [String: String], version: String = AgentMCP.version) throws(Refusal) {
        switch (edition, dev) {
        case ("Nerda", false): name = "nerda-browser"
        case ("Nerda Dev", true): name = "nerda-browser-dev"
        case ("Nerda Dev", false):
            throw Refusal(description: """
                This is Nerda Dev. Agents use Nerda; Nerda Dev registers as nerda-browser-dev only when \
                asked: run setup --dev.
                """)
        case ("Nerda", true): throw Refusal(description: "--dev is for Nerda Dev; this is Nerda. Run setup without it.")
        default: throw Refusal(description: "\(edition) doesn't set up agents.")
        }
        self.executable = executable
        self.places = places
        self.environment = environment
        skill = AgentSkill.text(name: name, dev: dev, version: version)
    }

    /// The edition running, as it would set itself up for the owner: what
    /// the launch looks at to keep the skill current. Nil for Nerda Test.
    static func installed() -> AgentSetup? {
        guard let executable = Bundle.main.executableURL else { return nil }
        let environment = ProcessInfo.processInfo.environment
        return try? AgentSetup(edition: Edition.name, dev: Edition.name == "Nerda Dev", executable: executable,
                               places: .owners(environment: environment), environment: environment)
    }

    // MARK: Running

    /// Every step, each said in the report, the rest done when one fails.
    func run() -> Report {
        var report = Report()
        setUpClaude(&report)
        setUpCodex(&report)
        installCommand(&report)
        if !report.changed && !report.failed { report.kept("Everything was already set up.") }
        return report
    }

    // MARK: One part at a time (Settings › Agents)

    /// What Settings › Agents lists: the two agents, and the command.
    enum Part: String, CaseIterable, Identifiable, Sendable {
        case claude, codex, command
        var id: Self { self }
    }

    /// How a part stands, read without changing anything.
    enum Link: Equatable, Sendable {
        /// The agent isn't on this Mac.
        case missing
        /// Not connected, or only partly (the skill is gone).
        case off
        /// Connected to this copy of Nerda.
        case on
        /// Connected to another copy of Nerda (one that moved, or an older
        /// setup's): connecting again points it here.
        case other
        /// The command's file is there and isn't Nerda's: left alone.
        case taken
    }

    func link(_ part: Part) -> Link {
        switch part {
        case .claude:
            guard places.claude != nil else { return .missing }
            guard let server = claudeServer() else { return .off }
            guard isOurs(server) else { return .other }
            return hasSkill(in: places.claudeFolder) ? .on : .off
        case .codex:
            guard FileManager.default.fileExists(atPath: places.codexFolder.path) else { return .missing }
            let read = (try? String(contentsOf: codexFile, encoding: .utf8)) ?? ""
            // As setup writes it: ending in a new line.
            let text = read.isEmpty || read.hasSuffix("\n") ? read : read + "\n"
            if Self.codexConfig(text, server: name, command: executable.path) == text {
                return hasSkill(in: places.codexFolder) ? .on : .off
            }
            return Self.codexConfig(text, server: name, command: nil) == text ? .off : .other
        case .command:
            guard let script = try? String(contentsOf: commandFile, encoding: .utf8) else {
                return FileManager.default.fileExists(atPath: commandFile.path) ? .taken : .off
            }
            guard script.contains(Self.commandMark) else { return .taken }
            return script == commandScript && FileManager.default.isExecutableFile(atPath: commandFile.path) ? .on : .other
        }
    }

    /// Sets up one part, as `run` sets up all three.
    func connect(_ part: Part) -> Report {
        var report = Report()
        switch part {
        case .claude: setUpClaude(&report)
        case .codex: setUpCodex(&report)
        case .command: installCommand(&report)
        }
        return report
    }

    /// Undoes what connecting did: the server's registration, the skill
    /// setup wrote, or the command. Nothing else of the agent's is touched,
    /// and a command file that isn't Nerda's stays.
    func disconnect(_ part: Part) -> Report {
        var report = Report()
        switch part {
        case .claude:
            if let claude = places.claude, claudeServer() != nil {
                let removed = runProgram(claude, ["mcp", "remove", "--scope", "user", name])
                if claudeServer() == nil {
                    report.did("Claude Code: removed \(name).")
                } else {
                    report.failed("Claude Code: couldn't remove \(name): \(removed.output.trimmingCharacters(in: .whitespacesAndNewlines))")
                }
            }
            removeSkill(in: places.claudeFolder, for: "Claude Code", &report)
        case .codex:
            let before = (try? String(contentsOf: codexFile, encoding: .utf8)) ?? ""
            let after = Self.codexConfig(before, server: name, command: nil)
            do {
                if after != before, try write(after, to: codexFile) { report.did("Codex: removed \(name) from \(places.show(codexFile)).") }
            } catch {
                report.failed("Codex: couldn't write \(places.show(codexFile)): \(error.localizedDescription)")
            }
            removeSkill(in: places.codexFolder, for: "Codex", &report)
        case .command:
            guard link(.command) != .taken, FileManager.default.fileExists(atPath: commandFile.path) else { break }
            do {
                try FileManager.default.removeItem(at: commandFile)
                report.did("Command: removed \(places.show(commandFile)).")
            } catch {
                report.failed("Command: couldn't remove \(places.show(commandFile)): \(error.localizedDescription)")
            }
        }
        return report
    }

    /// At launch: the skill, where setup wrote it, written again when its
    /// text changed (Nerda updated). Nowhere setup didn't write it. Answers
    /// the files written.
    @discardableResult
    func refreshSkills() -> [URL] {
        skillFiles.filter { file in
            guard FileManager.default.fileExists(atPath: file.path) else { return false }
            return (try? write(skill, to: file)) == true
        }
    }

    /// The process run as `setup`: prints the report and exits.
    static func main(_ arguments: [String]) -> Never {
        let environment = ProcessInfo.processInfo.environment
        guard let executable = Bundle.main.executableURL else {
            FileHandle.standardError.write(Data("Setup can't tell where Nerda is.\n".utf8))
            exit(1)
        }
        do {
            let setup = try AgentSetup(edition: Edition.name, dev: arguments.contains("--dev"), executable: executable,
                                       places: .owners(environment: environment), environment: environment)
            let report = setup.run()
            print(report.lines.joined(separator: "\n"))
            exit(report.failed ? 1 : 0)
        } catch {
            FileHandle.standardError.write(Data((error.description + "\n").utf8))
            exit(1)
        }
    }

    private var codexFile: URL { places.codexFolder.appending(path: "config.toml") }
    private var commandFile: URL { places.commands.appending(path: name) }

    private var skillFiles: [URL] {
        [places.claudeFolder, places.codexFolder].map { $0.appending(path: "skills/\(name)/SKILL.md") }
    }

    // MARK: Claude Code

    private func setUpClaude(_ report: inout Report) {
        guard let claude = places.claude else {
            report.kept("Claude Code: not found (no claude program), skipped.")
            return
        }
        switch claudeServer() {
        case .some(let server) where isOurs(server):
            report.kept("Claude Code: \(name) is already registered.")
        case let existing:
            // Its own command writes its settings: Claude Code keeps that
            // file open, and would write over a change made beside it.
            if existing != nil { _ = runProgram(claude, ["mcp", "remove", "--scope", "user", name]) }
            let added = runProgram(claude, ["mcp", "add", "--scope", "user", name, "--", executable.path, "mcp"])
            if added.status == 0, let server = claudeServer(), isOurs(server) {
                report.did("Claude Code: registered \(name) at user scope.")
            } else {
                report.failed("Claude Code: couldn't register \(name): \(added.output.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        }
        writeSkill(in: places.claudeFolder, for: "Claude Code", &report)
    }

    /// The user-scope server of this name in Claude Code's settings.
    private func claudeServer() -> AgentJSON? {
        guard let data = try? Data(contentsOf: places.claudeSettings) else { return nil }
        return (try? AgentJSON(data: data))?["mcpServers"]?[name]
    }

    private func isOurs(_ server: AgentJSON) -> Bool {
        server["command"]?.string == executable.path && server["args"] == ["mcp"]
            && (server["type"] == nil || server["type"] == "stdio")
    }

    // MARK: Codex

    /// How long Codex waits on a tool call: past the ten minutes a call
    /// may wait on the owner (a Handoff), where Codex's own default is 60 s.
    static let codexToolTimeout = 660

    private func setUpCodex(_ report: inout Report) {
        guard FileManager.default.fileExists(atPath: places.codexFolder.path) else {
            report.kept("Codex: not found (no \(places.show(places.codexFolder))), skipped.")
            return
        }
        let file = codexFile
        let before = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        let after = Self.codexConfig(before, server: name, command: executable.path)
        do {
            if try write(after, to: file) {
                report.did("Codex: registered \(name) in \(places.show(file)).")
            } else {
                report.kept("Codex: \(name) is already registered.")
            }
        } catch {
            report.failed("Codex: couldn't write \(places.show(file)): \(error.localizedDescription)")
        }
        writeSkill(in: places.codexFolder, for: "Codex", &report)
    }

    /// Codex's config with the server's table, `[mcp_servers.<name>]`, set:
    /// where it stood (with any tables under it, `….env`, gone), or at the
    /// end; with no `command`, taken out. Every other line is kept as it was.
    static func codexConfig(_ text: String, server name: String, command: String?) -> String {
        let table = command.map { command in [
            "[mcp_servers.\(name)]",
            "command = \(tomlString(command))",
            #"args = ["mcp"]"#,
            "tool_timeout_sec = \(codexToolTimeout)",
        ] } ?? []
        var kept: [String] = []
        var at: Int?
        var inOurs = false
        for line in text.isEmpty ? [] : text.components(separatedBy: "\n") {
            if let keys = tableKeys(line) {
                inOurs = keys.count >= 2 && keys[0] == "mcp_servers" && keys[1] == name
                if inOurs, at == nil { at = kept.count }
            }
            if !inOurs { kept.append(line) }
        }
        let isBlank = { (line: String) in line.trimmingCharacters(in: .whitespaces).isEmpty }
        if table.isEmpty {
            // Out: one blank line where the table stood, not two.
            if let at, at > 0, at < kept.count, isBlank(kept[at - 1]), isBlank(kept[at]) { kept.remove(at: at) }
            if at == nil { return text }
            let result = kept.joined(separator: "\n")
            return result.isEmpty || result.hasSuffix("\n") ? result : result + "\n"
        }
        if let at {
            let after = at < kept.count && !isBlank(kept[at]) ? [""] : []
            let before = at > 0 && !isBlank(kept[at - 1]) ? [""] : []
            kept.insert(contentsOf: before + table + after, at: at)
        } else {
            while let last = kept.last, isBlank(last) { kept.removeLast() }
            kept += (kept.isEmpty ? [] : [""]) + table
        }
        let result = kept.joined(separator: "\n")
        return result.hasSuffix("\n") ? result : result + "\n"
    }

    /// The keys of a table's header line (`[mcp_servers."nerda-browser"]`
    /// is `mcp_servers`, `nerda-browser`), or nil for any other line.
    private static func tableKeys(_ line: String) -> [String]? {
        var header = line.trimmingCharacters(in: .whitespaces)
        if let comment = header.firstIndex(of: "#"), !header[..<comment].contains("\"") {
            header = header[..<comment].trimmingCharacters(in: .whitespaces)
        }
        guard header.hasPrefix("["), !header.hasPrefix("[["), header.hasSuffix("]") else { return nil }
        let inside = header.dropFirst().dropLast()
        guard !inside.contains("["), !inside.contains("]"), !inside.contains(",") else { return nil }
        return inside.split(separator: ".").map {
            $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
    }

    private static func tomlString(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    // MARK: The skill and the command

    private func writeSkill(in folder: URL, for agent: String, _ report: inout Report) {
        let file = folder.appending(path: "skills/\(name)/SKILL.md")
        do {
            if try write(skill, to: file) {
                report.did("\(agent): wrote the \(name) skill to \(places.show(file.deletingLastPathComponent())).")
            }
        } catch {
            report.failed("\(agent): couldn't write the skill: \(error.localizedDescription)")
        }
    }

    private func hasSkill(in folder: URL) -> Bool {
        FileManager.default.fileExists(atPath: folder.appending(path: "skills/\(name)/SKILL.md").path)
    }

    /// The skill setup wrote, and its folder once nothing else is in it.
    private func removeSkill(in folder: URL, for agent: String, _ report: inout Report) {
        let skills = folder.appending(path: "skills/\(name)")
        let file = skills.appending(path: "SKILL.md")
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            try FileManager.default.removeItem(at: file)
            if (try? FileManager.default.contentsOfDirectory(atPath: skills.path))?.isEmpty == true {
                try? FileManager.default.removeItem(at: skills)
            }
            report.did("\(agent): removed the \(name) skill.")
        } catch {
            report.failed("\(agent): couldn't remove the skill: \(error.localizedDescription)")
        }
    }

    /// The first lines of the command, by which setup knows it as Nerda's.
    private static let commandMark = "# Nerda's command line for agents and scripts, put here by Nerda's setup."

    /// The command's two lines: the app's binary, run as the command line.
    private var commandScript: String {
        let quoted = "'" + executable.path.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
        return "#!/bin/sh\n\(Self.commandMark)\nexec \(quoted) cli \"$@\"\n"
    }

    private func installCommand(_ report: inout Report) {
        let file = commandFile
        let script = commandScript
        if FileManager.default.fileExists(atPath: file.path),
           (try? String(contentsOf: file, encoding: .utf8))?.contains(Self.commandMark) != true {
            report.failed("Command: \(places.show(file)) is there and isn't Nerda's; left alone.")
            return
        }
        do {
            let wrote = try write(script, to: file)
            if wrote || !FileManager.default.isExecutableFile(atPath: file.path) {
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
            }
            if wrote { report.did("Command: installed \(places.show(file)).") }
            else { report.kept("Command: \(places.show(file)) is already installed.") }
        } catch {
            report.failed("Command: couldn't install \(places.show(file)): \(error.localizedDescription)")
            return
        }
        let path = (environment["PATH"] ?? "").split(separator: ":").map { URL(fileURLWithPath: String($0)).standardizedFileURL.path }
        if !path.contains(places.commands.standardizedFileURL.path) {
            report.kept("Command: \(places.show(places.commands)) isn't on PATH; add it to run \(name) by name.")
        }
    }

    // MARK: Files and programs

    /// Writes `text` to `file` unless it already says that, making its
    /// folder; answers whether it wrote.
    private func write(_ text: String, to file: URL) throws -> Bool {
        if let existing = try? String(contentsOf: file, encoding: .utf8), existing == text { return false }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: file, atomically: true, encoding: .utf8)
        return true
    }

    /// Runs `program` in the temporary folder (so nothing lands in a
    /// project's settings), with the owner's home, for at most a minute.
    private func runProgram(_ program: URL, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = program
        process.arguments = arguments
        var environment = environment
        environment["HOME"] = places.home.path
        // Run from Settings, Nerda has the bare PATH apps get from launchd,
        // where a `claude` installed with npm wouldn't find node.
        let path = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let wanted = [program.deletingLastPathComponent().path, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        environment["PATH"] = (path + wanted.filter { !path.contains($0) }).joined(separator: ":")
        process.environment = environment
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return (-1, error.localizedDescription) }
        let timer = DispatchWorkItem { [process] in if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 60, execute: timer)
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timer.cancel()
        Logger.agents.info("setup ran \(program.lastPathComponent, privacy: .public): \(process.terminationStatus)")
        return (process.terminationStatus, String(decoding: output, as: UTF8.self))
    }
}
