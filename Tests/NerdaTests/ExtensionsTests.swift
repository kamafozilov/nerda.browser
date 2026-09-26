import Foundation
import JavaScriptCore
import Testing
@testable import Nerda

/// An extension folder of the files given, in a folder of its own.
private func extensionFolder(_ files: [String: String]) throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("nerda-ext-\(UUID().uuidString)", isDirectory: true)
    for (name, text) in files {
        let url = folder.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
    return folder
}

/// What a script throws when it is run, or nil.
private func runs(_ script: String, after setup: String = "") -> String? {
    let context = JSContext()!
    context.evaluateScript(setup)
    context.evaluateScript(script)
    return context.exception?.toString()
}

/// A content script's world: a web page's address, and the extension APIs
/// WebKit gives a content script.
private let contentWorld = """
    globalThis.location = { protocol: "https:", pathname: "/", href: "https://example.com/" };
    globalThis.chrome = { runtime: { id: "abc", getURL: (p) => "chrome-extension://abc/" + p, getManifest: () => ({}),
      sendMessage: () => Promise.resolve(), onMessage: { addListener() {} } }, storage: { local: {} } };
    """

/// Both shims, as an extension gets them, are whole scripts, and all ASCII,
/// so WebKit keeps them at a byte a character.
@Test func preparedShimsParse() throws {
    let folder = try extensionFolder(["manifest.json": #"{"manifest_version": 3, "background": {"service_worker": "bg.js"}}"#, "bg.js": ""])
    defer { try? FileManager.default.removeItem(at: folder) }
    for script in [ExtensionShims.contentScript, ExtensionShims.shim(for: folder)] {
        let context = JSGlobalContextCreate(nil)
        defer { JSGlobalContextRelease(context) }
        let source = JSStringCreateWithCFString(script as CFString)
        defer { JSStringRelease(source) }
        #expect(JSCheckScriptSyntax(context, source, nil, 1, nil))
        #expect(script.unicodeScalars.allSatisfy { $0.isASCII })
        #expect(!script.contains("__NERDA_"))
    }
}

/// The content shim mends a content script's world, and leaves a page's own
/// world (a MAIN-world script's) as it found it.
@Test func contentShimRunsInAContentScriptsWorld() {
    #expect(runs(ExtensionShims.contentScript, after: contentWorld) == nil)
    let context = JSContext()!
    context.evaluateScript(contentWorld)
    context.evaluateScript(ExtensionShims.contentScript)
    #expect(context.evaluateScript("globalThis.__nerdaShim === true && typeof requestIdleCallback === 'function'").toBool())
    let page = JSContext()!
    page.evaluateScript(ExtensionShims.contentScript)
    #expect(page.exception == nil)
    #expect(page.evaluateScript("globalThis.__nerdaShim === undefined").toBool())
}

/// Content scripts get the content shim, a MAIN-world one nothing; one
/// prepared by an older Nerda loses the whole shim it was given.
@Test func contentScriptsGetTheirPartOfTheShim() throws {
    let manifest = """
        {"manifest_version": 3, "name": "t", "version": "1",
         "background": {"service_worker": "bg.js"},
         "content_scripts": [
           {"matches": ["<all_urls>"], "js": ["a.js"]},
           {"matches": ["<all_urls>"], "js": ["nerda-shim.js", "b.js"], "world": "ISOLATED"},
           {"matches": ["<all_urls>"], "js": ["nerda-shim.js", "c.js"], "world": "MAIN"},
           {"matches": ["<all_urls>"], "css": ["d.css"]}
         ]}
        """
    let folder = try extensionFolder(["manifest.json": manifest, "bg.js": "chrome.runtime.onInstalled.addListener(() => {});"])
    defer { try? FileManager.default.removeItem(at: folder) }
    try ExtensionShims.prepare(folder, fresh: true)
    let prepared = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("manifest.json"))) as! [String: Any]
    let entries = prepared["content_scripts"] as! [[String: Any]]
    #expect(entries.map { $0["js"] as? [String] } == [["nerda-content.js", "a.js"], ["nerda-content.js", "b.js"], ["c.js"], nil])
    let content = try String(contentsOf: folder.appendingPathComponent(ExtensionShims.contentFile), encoding: .utf8)
    #expect(content == ExtensionShims.contentScript)
    let worker = try String(contentsOf: folder.appendingPathComponent("bg.js"), encoding: .utf8)
    #expect(worker.hasPrefix(ExtensionShims.marker))
    #expect(worker.hasSuffix("chrome.runtime.onInstalled.addListener(() => {});"))
}

/// The worker listens from the start for the events its own code mentions,
/// imports included, and not for those only its popup does; an import it
/// works out as it runs has every script count.
@Test func workerListensForItsOwnEvents() throws {
    let events = { (folder: URL) -> Set<String> in
        let shim = ExtensionShims.shim(for: folder)
        let start = shim.range(of: "const mentioned = new Set(")!.upperBound
        let list = shim[start...].prefix { $0 != ")" }
        return Set(try! JSONSerialization.jsonObject(with: Data(list.utf8)) as! [String])
    }
    let classic = try extensionFolder([
        "manifest.json": #"{"manifest_version": 3, "background": {"service_worker": "js/bg.js"}}"#,
        "js/bg.js": #"importScripts("lib.js", '/shared/x.js'); chrome.runtime.onInstalled.addListener(() => {});"#,
        "js/lib.js": "chrome.alarms.onAlarm.addListener(() => {});",
        "shared/x.js": "chrome.storage.onChanged.addListener(() => {});",
        "popup.js": "chrome.tabs.onUpdated.addListener(() => {});",
    ])
    defer { try? FileManager.default.removeItem(at: classic) }
    #expect(events(classic) == ["runtime.onInstalled", "alarms.onAlarm", "storage.onChanged"])
    // Prepared again, as each launch after an update does: the same.
    try ExtensionShims.prepare(classic, fresh: true)
    #expect(events(classic) == ["runtime.onInstalled", "alarms.onAlarm", "storage.onChanged"])

    let module = try extensionFolder([
        "manifest.json": #"{"manifest_version": 3, "background": {"service_worker": "bg.js", "type": "module"}}"#,
        "bg.js": #"import { a } from "./lib/a.js"; import"./lib/b.js"; chrome.commands.onCommand.addListener(a);"#,
        "lib/a.js": #"export * from "../c.js"; export const a = () => {};"#,
        "lib/b.js": "chrome.action.onClicked.addListener(() => {});",
        "c.js": "chrome.tabs.onActivated.addListener(() => {});",
        "popup.js": "chrome.tabs.onUpdated.addListener(() => {});",
    ])
    defer { try? FileManager.default.removeItem(at: module) }
    try ExtensionShims.prepare(module, fresh: true)
    #expect(events(module) == ["commands.onCommand", "action.onClicked", "tabs.onActivated"])

    let computed = try extensionFolder([
        "manifest.json": #"{"manifest_version": 3, "background": {"service_worker": "bg.js"}}"#,
        "bg.js": #"for (const f of ["a.js"]) importScripts(f);"#,
        "a.js": "chrome.alarms.onAlarm.addListener(() => {});",
        "popup.js": "chrome.tabs.onUpdated.addListener(() => {});",
    ])
    defer { try? FileManager.default.removeItem(at: computed) }
    #expect(events(computed) == ["alarms.onAlarm", "tabs.onUpdated"])
}
