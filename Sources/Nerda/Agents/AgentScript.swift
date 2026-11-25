import Foundation
import JavaScriptCore

/// `run`: a short script of many steps in one call, in JavaScriptCore
/// inside the shim or the command line, never in a page. Each verb is a
/// function of the script's (`open(url)`, `click(tab, ref)`, or with an
/// object, `text({ tab: "t1" })`; every one also as `nerda.<verb>`, and
/// `eval` only so), and each call of one is a step: one normal request to
/// Nerda through `step`, with the same checks as any other, answering the
/// verb's text or throwing its failure (`error.code`). A script takes at
/// most `mostSteps` steps and `seconds` of time, and what it prints
/// (`print`, `console.log`) and returns is answered, up to `mostOutput`
/// characters. `state` is an object kept from one run to the next, as JSON.
nonisolated final class AgentScript: @unchecked Sendable {
    /// The most steps one run takes.
    static let mostSteps = 200
    /// The most characters a run answers with.
    static let mostOutput = 40_000
    /// How long a run may take unless it says (`seconds`), and the longest
    /// it may ask for.
    static let defaultTime: Duration = .seconds(120)
    static let longestTime: Duration = .seconds(300)
    /// The most characters of `state` kept for the next run.
    static let mostState = 1 << 20

    /// One step: a verb and its arguments, sent to Nerda.
    typealias Step = @Sendable (_ verb: String, _ arguments: [String: AgentJSON]) async -> AgentReply
    /// Told after each step: how many so far, and which verb.
    typealias Progress = @Sendable (_ steps: Int, _ verb: String) -> Void

    /// How a run went, and the state to keep for the next.
    struct Outcome: Sendable {
        var reply: AgentReply
        var state: String
    }

    /// The time a run asks for (`seconds`), if it does.
    static func time(_ arguments: [String: AgentJSON]) -> Duration? {
        guard let seconds = arguments["seconds"]?.number, seconds > 0 else { return nil }
        return .milliseconds(Int(min(seconds, 3600) * 1000))
    }

    /// The verbs a script can call: all but `run` itself and `more_tools`,
    /// which only changes what an MCP client lists.
    static var verbs: [AgentVerb] {
        AgentVerb.all.filter { $0.name != AgentVerb.run.name && $0.name != AgentVerb.moreTools.name }
    }

    /// Runs `script` with the state an earlier run kept, on a thread of its
    /// own: its steps wait there for their answers, so the script reads as
    /// a list of steps, no `await` needed (though allowed).
    static func run(_ script: String, state: String, time: Duration? = nil,
                    step: @escaping Step, progress: Progress? = nil) async -> Outcome {
        let time = min(time ?? defaultTime, longestTime)
        return await withCheckedContinuation { continuation in
            let thread = Thread {
                let run = AgentScript(time: time, step: step, progress: progress)
                continuation.resume(returning: run.evaluate(script, state: state))
            }
            // JavaScriptCore wants more stack than a thread's default.
            thread.stackSize = 16 << 20
            thread.name = "nerda-browser run"
            thread.start()
        }
    }

    private let time: Duration
    private let end: ContinuousClock.Instant
    private let step: Step
    private let progress: Progress?
    private var steps = 0
    /// Why the run was stopped, past its steps or time: told even when the
    /// script catches the error the step threw.
    private var stopped: AgentError?
    private var output = ""
    private var leftOut = 0
    private var lastText: String?
    private var lastPicture: Data?
    private var finished: (ok: Bool, text: String, code: String?)?

    private init(time: Duration, step: @escaping Step, progress: Progress?) {
        self.time = time
        end = .now + time
        self.step = step
        self.progress = progress
    }

    private func evaluate(_ script: String, state: String) -> Outcome {
        guard let context = JSContext() else {
            return Outcome(reply: .failed(AgentError(.failed, "The script couldn't be started.")), state: state)
        }
        Self.limit(context, to: time)
        let doStep: @convention(block) (String, String) -> String = { [unowned self] verb, arguments in
            self.take(verb, arguments)
        }
        let show: @convention(block) (String) -> Void = { [unowned self] line in self.print(line) }
        let finish: @convention(block) (Bool, String, JSValue) -> Void = { [unowned self] ok, text, code in
            finished = (ok, text, code.isString ? code.toString() : nil)
        }
        context.setObject(doStep, forKeyedSubscript: "__nerdaStep" as NSString)
        context.setObject(show, forKeyedSubscript: "__nerdaPrint" as NSString)
        context.setObject(finish, forKeyedSubscript: "__nerdaFinish" as NSString)
        context.setObject(script, forKeyedSubscript: "__nerdaScript" as NSString)
        context.setObject(state, forKeyedSubscript: "__nerdaState" as NSString)
        context.setObject(Self.verbTable, forKeyedSubscript: "__nerdaVerbs" as NSString)
        context.evaluateScript(Self.prelude)

        var kept = state
        if let value = context.evaluateScript("__nerdaKeep()"), value.isString, let text = value.toString() {
            if text.count <= Self.mostState { kept = text } else { print("(state was over \(Self.mostState) characters, so it wasn't kept)") }
        }
        return Outcome(reply: reply(context), state: kept)
    }

    /// The answer, once the script has ended one way or another.
    private func reply(_ context: JSContext) -> AgentReply {
        var lines = ["ran \(steps) step\(steps == 1 ? "" : "s")"]
        if leftOut > 0 { output += "\n(\(leftOut) more characters of output left out)" }
        let failure: AgentError?
        if let stopped {
            failure = stopped
        } else if let finished, !finished.ok {
            failure = AgentError(finished.code.flatMap(AgentError.Code.init(rawValue:)) ?? .failed, finished.text)
        } else if finished == nil {
            // Never finished: JavaScriptCore stopped it, past its time.
            let thrown = context.exception?.toString() ?? ""
            failure = thrown.contains("terminated")
                ? AgentError(.timedOut, "The script ran past its time (\(Int(time.seconds)) s) and was stopped.")
                : AgentError(.failed, "The script couldn't run: \(thrown)")
        } else {
            failure = nil
        }
        if !output.isEmpty { lines.append(output) }
        // A script stopped at its steps or time may have caught that and
        // gone on: what it returned then isn't its answer.
        if stopped == nil, let finished, finished.ok, !finished.text.isEmpty {
            lines.append("returned: " + finished.text)
        } else if failure == nil, output.isEmpty, let lastText {
            lines += ["The script printed and returned nothing; its last step answered:", lastText]
        }
        guard let failure else { return .done(lines.joined(separator: "\n"), jpeg: lastPicture) }
        var reply = AgentReply.failed(AgentError(failure.code, ([failure.message] + lines).joined(separator: "\n")))
        reply.jpeg = lastPicture
        return reply
    }

    /// One step, on the script's thread: refused past the steps or the time,
    /// else sent and waited for. Answers JSON `{ok, text, error}`.
    private func take(_ verb: String, _ arguments: String) -> String {
        if stopped == nil, steps >= Self.mostSteps {
            stopped = AgentError(.failed, """
                The script was stopped at its \(Self.mostSteps + 1)st step: a run takes at most \(Self.mostSteps) steps. \
                Split the work into shorter runs; state carries values from one run to the next.
                """)
        }
        if stopped == nil, ContinuousClock.now >= end {
            stopped = AgentError(.timedOut, "The script ran past its time (\(Int(time.seconds)) s) and was stopped before step \(steps + 1).")
        }
        if let stopped { return Self.json(.failed(stopped)) }
        guard let object = (try? AgentJSON(line: arguments))?.object else {
            return Self.json(.failed(AgentError(.invalid, "The arguments to \(verb) couldn't be read.")))
        }
        steps += 1
        let answer = Answer()
        let done = DispatchSemaphore(value: 0)
        Task.detached { [step] in
            answer.reply = await step(verb, object)
            done.signal()
        }
        done.wait()
        let reply = answer.reply ?? .failed(AgentError(.failed, "\(verb) wasn't answered."))
        if reply.ok { lastText = reply.text }
        if let jpeg = reply.jpeg { lastPicture = jpeg }
        progress?(steps, verb)
        var told = reply
        told.jpeg = nil
        if !told.ok { told.text = "step \(steps) (\(verb)) failed: \(told.text)" }
        return Self.json(told)
    }

    private final class Answer: @unchecked Sendable {
        var reply: AgentReply?
    }

    private func print(_ line: String) {
        let room = Self.mostOutput - output.count
        guard room > 0, leftOut == 0 else {
            leftOut += line.count + 1
            return
        }
        let line = output.isEmpty ? line : "\n" + line
        output += line.prefix(room)
        leftOut += max(0, line.count - room)
    }

    private static func json(_ reply: AgentReply) -> String {
        AgentJSON.object([
            "ok": .bool(reply.ok), "text": .string(reply.text), "error": reply.error.map(AgentJSON.string) ?? .null,
        ]).line
    }

    /// Each verb a script can call, with its arguments' names in order.
    private static var verbTable: String {
        AgentJSON.object(Dictionary(uniqueKeysWithValues: verbs.map { verb in
            (verb.name, AgentJSON.array(verb.arguments.map { .string($0.name) }))
        })).line
    }

    /// A limit on the time the script itself runs, so `while (true) {}`
    /// ends: JavaScriptCore's own, through a function of its C interface
    /// that isn't in its public headers. Should it go, a script that never
    /// takes a step runs on (the shim's client gives up on it).
    private static func limit(_ context: JSContext, to time: Duration) {
        typealias SetLimit = @convention(c) (JSContextGroupRef, Double, OpaquePointer?, UnsafeMutableRawPointer?) -> Void
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "JSContextGroupSetExecutionTimeLimit"),
              let group = JSContextGetGroup(context.jsGlobalContextRef) else { return }
        unsafeBitCast(symbol, to: SetLimit.self)(group, time.seconds, nil, nil)
    }

    /// What every run starts with: the verbs as functions, `print`,
    /// `state`, then the script as the body of an async function, and its
    /// end told to `__nerdaFinish`.
    private static let prelude = """
        (() => {
            const step = __nerdaStep, show = __nerdaPrint, finish = __nerdaFinish;
            const verbs = JSON.parse(__nerdaVerbs);
            const text = (value) => {
                if (typeof value === 'string') return value;
                if (value === undefined) return 'undefined';
                if (value instanceof Error) return String(value);
                try { return JSON.stringify(value) ?? String(value); } catch { return String(value); }
            };
            const call = (name, names) => function (...given) {
                const args = {};
                for (let i = 0; i < given.length; i++) {
                    const value = given[i];
                    if (i === given.length - 1 && value !== null && typeof value === 'object' && !Array.isArray(value)) {
                        Object.assign(args, value);
                        break;
                    }
                    if (i >= names.length) throw new TypeError(name + ' takes ' + (names.join(', ') || 'no arguments'));
                    if (value !== undefined) args[names[i]] = value;
                }
                const reply = JSON.parse(step(name, JSON.stringify(args)));
                if (reply.ok) return reply.text;
                const error = new Error(reply.text);
                error.code = reply.error;
                error.step = name;
                throw error;
            };
            const nerda = {};
            for (const [name, names] of Object.entries(verbs)) {
                nerda[name] = call(name, names);
                if (!(name in globalThis)) globalThis[name] = nerda[name];
            }
            globalThis.nerda = Object.freeze(nerda);
            globalThis.print = (...values) => show(values.map(text).join(' '));
            globalThis.console = { log: print, info: print, warn: print, error: print };
            try { globalThis.state = JSON.parse(__nerdaState); } catch { globalThis.state = {}; }
            if (state === null || typeof state !== 'object') globalThis.state = {};
            globalThis.__nerdaKeep = () => {
                try { return JSON.stringify(globalThis.state) ?? '{}'; } catch (error) { print('(state couldn\\'t be kept: ' + error + ')'); }
            };
            let body;
            try {
                body = new (async function () {}).constructor(__nerdaScript);
            } catch (error) {
                finish(false, 'The script has a mistake: ' + error, 'invalid');
                return;
            }
            body().then(
                (value) => finish(true, value === undefined ? '' : text(value), null),
                (error) => finish(false, error && error.step ? error.message : 'The script threw: ' + text(error),
                                  error && error.code ? String(error.code) : null)
            );
        })();
        """
}
