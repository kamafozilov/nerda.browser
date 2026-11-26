import Foundation

/// What an Agent session is doing with one request, in the owner's words,
/// for the Agent row: "Reading github.com", "Clicking on github.com".
struct AgentStep: Equatable {
    /// The verb asked for (`AgentVerb.name`).
    let verb: String
    /// The site it is done on, when there is one: the tab's, the address
    /// asked for, or a Site skill's name.
    let site: String?

    /// What the row says, without a full stop or an ellipsis.
    var words: String {
        let (doing, withSite) = Self.phrases[verb] ?? ("Working on", true)
        guard withSite else { return doing }
        if let site { return "\(doing) \(site)" }
        // No site: "Clicking", not "Clicking on".
        var words = doing.split(separator: " ")
        if words.count > 1, ["on", "to", "at", "for", "from"].contains(words.last!) { words.removeLast() }
        return words.joined(separator: " ")
    }

    /// Between requests: the agent's model is working out its next step.
    static let thinking = "Thinking"

    /// Each verb's words, and whether its site follows them.
    private static let phrases: [String: (String, Bool)] = [
        "open": ("Opening", true),
        "navigate": ("Opening", true),
        "snapshot": ("Reading", true),
        "text": ("Reading", true),
        "screenshot": ("Looking at", true),
        "click": ("Clicking on", true),
        "click_at": ("Clicking on", true),
        "choose": ("Choosing an option on", true),
        "hover": ("Hovering on", true),
        "drag": ("Dragging on", true),
        "scroll": ("Scrolling", true),
        "type": ("Typing on", true),
        "press": ("Typing on", true),
        "upload": ("Uploading to", true),
        "dialog": ("Answering a dialog on", true),
        "wait": ("Waiting for", true),
        "fetch": ("Fetching from", true),
        "eval": ("Working on", true),
        "run": ("Working on", true),
        "sign_in": ("Signing in to", true),
        "close": ("Closing a tab", false),
        "tabs": ("Checking its tabs", false),
        "history": ("Looking through history", false),
        "bookmarks": ("Looking through bookmarks", false),
        "profiles": ("Checking profiles", false),
        "skill": ("Reading notes on", true),
        "skills": ("Reading site notes", false),
        "sites": ("Reading site notes", false),
        "skill_save": ("Saving notes on", true),
        "status": ("Getting ready", false),
        "more_tools": ("Getting ready", false),
        "handoff": ("Waiting for you", false),
        "ask": ("Waiting for you", false),
    ]

    /// The step `verb` with `arguments` is: on the tab it names, or the
    /// address it is given, among the session's `tabs`.
    static func of(_ verb: String, _ arguments: [String: AgentJSON], tabs: [AgentTab]) -> AgentStep {
        let url = arguments["url"]?.string.flatMap { URL(string: $0) }
        let tab = arguments["tab"]?.string.flatMap { ref in tabs.first { $0.ref == ref } }
        let site = (url ?? tab?.tab.url).flatMap(History.site(of:))
            ?? (verb.hasPrefix("skill") ? arguments["name"]?.string : nil)
        return AgentStep(verb: verb, site: site)
    }
}
