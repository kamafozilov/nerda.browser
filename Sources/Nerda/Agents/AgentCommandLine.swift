import Darwin
import Foundation
import os

/// The `nerda-browser` command on PATH (installed by `AgentSetup`): the
/// verbs of the MCP tools (`AgentVerb.all`), for scripts and agents with only
/// a shell, sent over the same socket as the shim's. Its exit code says how
/// it went, so a script can tell "needs the owner" from a failure.
///
///     nerda-browser open https://example.com
///     nerda-browser navigate t1 https://example.com/next
///     nerda-browser close --tab t1
///
/// `run` is the in-process entry point tests speak to; `main` is the
/// process, the app's binary run as `Nerda cli …`.
nonisolated enum AgentCommandLine {
    /// What one run printed and how it ended.
    struct Outcome: Sendable {
        var status: Int32
        var output = ""
        var errors = ""
    }

    static let done: Int32 = 0
    static let failed: Int32 = 1
    static let unreachable: Int32 = 2
    static let needsUser: Int32 = 3
    static let timedOut: Int32 = 124
    static let interrupted: Int32 = 130

    /// Where each harness puts its session id, with the name its MCP client
    /// gives: in a Claude Code or Codex shell, the command is in the same
    /// Agent session as that agent's MCP calls.
    static let sessions: [(variable: String, client: String)] = [
        ("NERDA_BROWSER_SESSION", "nerda-browser"),
        ("CLAUDE_CODE_SESSION_ID", "claude-code"),
        ("CODEX_THREAD_ID", "codex-mcp-client"),
    ]

    /// Runs as the process: prints, and exits with the outcome's code.
    static func main(_ arguments: [String]) -> Never {
        // ⌃C while waiting on Nerda: the shell is told it was interrupted.
        signal(SIGINT) { _ in _exit(AgentCommandLine.interrupted) }
        if arguments.first == "setup" { AgentSetup.main(Array(arguments.dropFirst())) }
        let finished = DispatchSemaphore(value: 0)
        let result = OSAllocatedUnfairLock(initialState: Outcome(status: failed))
        Task.detached {
            let outcome = await run(arguments, environment: ProcessInfo.processInfo.environment, socket: AgentWire.socket)
            result.withLock { $0 = outcome }
            finished.signal()
        }
        finished.wait()
        let outcome = result.withLock { $0 }
        if !outcome.output.isEmpty { FileHandle.standardOutput.write(Data(outcome.output.utf8)) }
        if !outcome.errors.isEmpty { FileHandle.standardError.write(Data(outcome.errors.utf8)) }
        exit(outcome.status)
    }

    /// One run with `arguments` (the verb first), in a shell with
    /// `environment`, against the app at `socket`.
    static func run(_ arguments: [String], environment: [String: String], socket: URL) async -> Outcome {
        guard let first = arguments.first else { return Outcome(status: failed, errors: usage) }
        if ["--help", "-h", "help"].contains(first) { return Outcome(status: done, output: usage) }
        guard let verb = AgentVerb.named[first] else {
            return Outcome(status: failed, errors: "nerda-browser has no verb \(first). See nerda-browser --help.\n")
        }
        if arguments.contains("--help") { return Outcome(status: done, output: "usage: nerda-browser \(synopsis(of: verb))\n\(verb.summary)\n") }
        let parsed: [String: AgentJSON]
        do { parsed = try self.arguments(Array(arguments.dropFirst()), for: verb) }
        catch { return Outcome(status: failed, errors: "\(error.message)\nusage: nerda-browser \(synopsis(of: verb))\n") }

        let request = AgentRequest(verb: verb.name, session: session(in: environment), args: parsed)
        let reply = await AgentWire.send(request, to: socket)
        let text = reply.text.hasSuffix("\n") || reply.text.isEmpty ? reply.text : reply.text + "\n"
        return reply.ok ? Outcome(status: done, output: text) : Outcome(status: status(of: reply), errors: text)
    }

    /// The exit code for an answer.
    static func status(of reply: AgentReply) -> Int32 {
        guard !reply.ok else { return done }
        return switch reply.error.flatMap(AgentError.Code.init(rawValue:)) {
        case .unreachable: unreachable
        case .needsUser: needsUser
        case .timedOut: timedOut
        default: failed
        }
    }

    /// The harness's session, as its MCP client names it; with none, the
    /// shell that ran the command, so a script's commands share one session.
    static func session(in environment: [String: String]) -> AgentSessionName {
        for (variable, client) in sessions {
            if let id = environment[variable], !id.isEmpty { return AgentSessionName(client: client, id: id) }
        }
        return AgentSessionName(client: "nerda-browser", id: "shell-\(getppid())")
    }

    // MARK: Arguments

    private struct Problem: Error {
        let message: String
    }

    /// Words after the verb, as its arguments: `--name value` (or
    /// `--name=value`, or `--flag` for a yes-or-no one) by name, the rest
    /// in the order the verb lists them, and `--json '{…}'` as they are.
    private static func arguments(_ words: [String], for verb: AgentVerb) throws(Problem) -> [String: AgentJSON] {
        var named: [String: AgentJSON] = [:]
        var positional: [String] = []
        var index = 0
        while index < words.count {
            let word = words[index]
            index += 1
            guard word.hasPrefix("--"), word.count > 2 else {
                positional.append(word)
                continue
            }
            var name = String(word.dropFirst(2))
            var value: String?
            if let equals = name.firstIndex(of: "=") {
                value = String(name[name.index(after: equals)...])
                name = String(name[..<equals])
            }
            if name == "json" {
                guard let text = value ?? (index < words.count ? words[index] : nil) else { throw Problem(message: "--json needs an object.") }
                if value == nil { index += 1 }
                guard let object = (try? AgentJSON(line: text))?.object else { throw Problem(message: "--json needs a JSON object.") }
                named.merge(object) { $1 }
                continue
            }
            guard let argument = verb.arguments.first(where: { $0.name == name }) else {
                throw Problem(message: "\(verb.name) takes no --\(name).")
            }
            if value == nil {
                if type(of: argument) == "boolean" {
                    // `--flag`, or `--flag false`.
                    if index < words.count, ["true", "false"].contains(words[index]) { value = words[index]; index += 1 }
                    else { value = "true" }
                } else {
                    guard index < words.count else { throw Problem(message: "--\(name) needs a value.") }
                    value = words[index]
                    index += 1
                }
            }
            named[name] = try json(value ?? "", for: argument)
        }
        var open = verb.arguments.filter { named[$0.name] == nil }
        for word in positional {
            guard !open.isEmpty else { throw Problem(message: "\(verb.name) takes no more arguments than these; \(word) is one too many.") }
            let argument = open.removeFirst()
            named[argument.name] = try json(word, for: argument)
        }
        if let missing = verb.arguments.first(where: { $0.required && named[$0.name] == nil }) {
            throw Problem(message: "\(verb.name) needs \(missing.name).")
        }
        return named
    }

    private static func type(of argument: AgentArgument) -> String { argument.schema["type"]?.string ?? "string" }

    /// A word as the kind of value the argument takes.
    private static func json(_ word: String, for argument: AgentArgument) throws(Problem) -> AgentJSON {
        switch type(of: argument) {
        case "integer":
            guard let number = Int(word) else { throw Problem(message: "\(argument.name) is a whole number, not \(word).") }
            return .number(Double(number))
        case "number":
            guard let number = Double(word) else { throw Problem(message: "\(argument.name) is a number, not \(word).") }
            return .number(number)
        case "boolean":
            guard let flag = Bool(word) else { throw Problem(message: "\(argument.name) is true or false, not \(word).") }
            return .bool(flag)
        case "array", "object":
            guard let value = try? AgentJSON(line: word) else { throw Problem(message: "\(argument.name) is JSON, and \(word) isn't.") }
            return value
        default:
            return .string(word)
        }
    }

    // MARK: Help

    /// `open <url>`, `snapshot <tab> [--full]`: how a verb is typed.
    static func synopsis(of verb: AgentVerb) -> String {
        ([verb.name] + verb.arguments.map { argument in
            if argument.required { return "<\(argument.name)>" }
            return type(of: argument) == "boolean" ? "[--\(argument.name)]" : "[--\(argument.name) <value>]"
        }).joined(separator: " ")
    }

    static var usage: String {
        let row = { (left: String, right: String) in
            "  " + (left.count < 34 ? left.padding(toLength: 34, withPad: " ", startingAt: 0) : left + "  ") + right
        }
        let verbs = AgentVerb.all.map { verb in
            let sentence = verb.summary.components(separatedBy: ". ").first ?? verb.summary
            return row(synopsis(of: verb), sentence.hasSuffix(".") ? String(sentence.dropLast()) : sentence)
        }
        return """
            usage: nerda-browser <verb> [arguments] [--name value] [--json '{…}']

            Drives Nerda, the user's browser, in Agent tabs: their profile, out of their sight.
            Arguments go in the order shown, or by name. Each verb's answer is printed; a
            failure goes to standard error.

            \(verbs.joined(separator: "\n"))

            \(row("setup [--dev]", "Connect Nerda to Claude Code and Codex; once is enough"))

            Exit codes: 0 done, 1 failed, 2 Nerda unreachable, 3 needs the user,
            124 timed out, 130 interrupted.

            """
    }
}
