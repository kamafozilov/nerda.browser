import Foundation

/// Scripts: many steps in one call (`run`, done by the shim and the command
/// line themselves, `AgentScript`), and JavaScript in a page (`eval`,
/// `AgentEval`).
nonisolated extension AgentVerb {
    static let scriptVerbs: [AgentVerb] = [run, eval]

    static let run = AgentVerb(
        name: "run",
        summary: """
            Run a short JavaScript script of many steps in one call, not in a page: each tool is a function \
            of it taking its arguments in order or as one object (open(url), click("t1", "e7"), \
            text({ tab: "t1" })), answering the tool's text or throwing its failure (error.code); eval is \
            nerda.eval. Each call is a step checked like any other, at most \(AgentScript.mostSteps) a run. \
            print() what you want back, or return it. state is an object kept from one run to the next.
            """,
        arguments: [
            .string("script", "The script, as the body of an async function"),
            AgentArgument(name: "seconds", schema: [
                "type": "number",
                "description": .string("The longest it may take, in seconds (default \(Int(AgentScript.defaultTime.components.seconds)), at most \(Int(AgentScript.longestTime.components.seconds)))"),
            ], required: false),
        ],
        destructive: true
    ) { _ in
        // The shim and the command line run scripts themselves; one that
        // reaches the app came some other way.
        throw AgentError(.invalid, "run is done by nerda-browser itself, the MCP server or the command line, not by Nerda.")
    }

    static let eval = AgentVerb(
        name: "eval",
        summary: """
            Run JavaScript in an Agent tab's page when no other tool fits, as the body of an async function: \
            return a value to get it back as JSON. It runs in a world of its own: the page's document, not \
            its scripts' variables. Password and card fields read as ••••, and putting script into the page \
            itself is refused. Answers what it returned, then what changed, as click does.
            """,
        arguments: [.tab, .string("script", "The JavaScript, as the body of an async function, such as return document.title")]
    ) { call in
        let tab = try call.tab()
        let script = try call.string("script")
        return try await AgentPage.act(tab, for: call) {
            guard let value = try await AgentEval.run(script, in: tab, by: call.deadline - .seconds(1)) else {
                return "eval ran in \(tab.ref); it returned nothing."
            }
            return "eval ran in \(tab.ref) and returned:\n" + AgentPage.untrusted(value, as: "page-value")
        }
    }
}
