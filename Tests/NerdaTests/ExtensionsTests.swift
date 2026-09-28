import Foundation
import JavaScriptCore
import WebKit
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

/// A click on its button that woke the worker reaches the listener the
/// extension adds once it has started, as NordPass's does, rather than none,
/// even when a listener it added while starting is gone again.
@Test func clickThatWokeTheWorkerWaitsForItsListener() throws {
    let folder = try extensionFolder([
        "manifest.json": #"{"manifest_version": 3, "background": {"service_worker": "bg.js"}}"#,
        "bg.js": "chrome.action.onClicked.addListener(() => {});",
    ])
    defer { try? FileManager.default.removeItem(at: folder) }
    // A worker's world as WebKit makes it: listeners taken while it
    // starts, refused after.
    let worker = """
        globalThis.ServiceWorkerGlobalScope = { [Symbol.hasInstance]: (o) => o === globalThis };
        const timers = [];
        globalThis.setTimeout = (f) => timers.push(f);
        globalThis.clearTimeout = globalThis.setInterval = globalThis.clearInterval = () => {};
        let started = false;
        const event = () => ({ fire(...a) { this.all.forEach((f) => f(...a)); }, all: [],
          addListener(f) { if (started) throw new Error("addListener must be called during startup"); this.all.push(f); },
          removeListener() {}, hasListener() { return false; } });
        globalThis.chrome = { runtime: { id: "abc", getURL: (p) => "chrome-extension://abc/" + p,
          getManifest: () => ({ background: { service_worker: "bg.js" } }), sendMessage: () => Promise.resolve(),
          sendNativeMessage: () => Promise.resolve(), connect: () => ({}),
          onMessage: event(), onConnect: event(), onInstalled: event() }, action: { onClicked: event() } };
        """
    let context = JSContext()!
    context.evaluateScript(worker)
    #expect(context.exception == nil)
    context.evaluateScript(ExtensionShims.shim(for: folder))
    #expect(context.exception == nil)
    context.evaluateScript("""
        const gone = () => {};
        chrome.action.onClicked.addListener(gone);
        chrome.action.onClicked.removeListener(gone);
        started = true;
        chrome.action.onClicked.fire({ id: 7 });
        let heard;
        chrome.action.onClicked.addListener((tab) => { heard = tab.id; });
        while (timers.length) timers.shift()();
        """)
    #expect(context.exception == nil)
    #expect(context.evaluateScript("heard").toInt32() == 7)
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

/// A site opens only the extension pages its manifest lets that site open,
/// as Chrome allows: NordPass lets Nord Account open app.html, and no other
/// site, and no other page. Anything that reads two ways stays closed.
@MainActor @Test func sitesOpenOnlyPagesTheExtensionLetsThem() throws {
    let manifest = try JSONSerialization.jsonObject(with: Data(#"""
        {"manifest_version": 3, "web_accessible_resources": [
          {"resources": ["assets/*.svg"], "matches": ["https://*/*"]},
          {"resources": ["app.html"], "matches": ["https://*.nordaccount.com/*"]},
          {"resources": ["secret.html"], "matches": ["<all_urls>"], "use_dynamic_url": true},
          {"resources": ["a?c.html"], "matches": ["<all_urls>"]}]}
        """#.utf8)) as! [String: Any]
    let page = { (path: String) in URL(string: "chrome-extension://abc" + path)! }
    let nord = URL(string: "https://nordaccount.com/")!
    let other = URL(string: "https://example.com/")!
    #expect(Extensions.webAccessible(page("/app.html"), from: nord, in: manifest))
    #expect(Extensions.webAccessible(page("/app.html?next=1"), from: URL(string: "https://my.nordaccount.com:8443/")!, in: manifest))
    #expect(Extensions.webAccessible(page("/assets/icons/a.svg"), from: other, in: manifest))
    #expect(!Extensions.webAccessible(page("/app.html"), from: other, in: manifest))
    #expect(!Extensions.webAccessible(page("/index.html"), from: nord, in: manifest))
    #expect(!Extensions.webAccessible(page("/app.html"), from: nil, in: manifest))
    #expect(!Extensions.webAccessible(page("/app.html"), from: URL(string: "http://nordaccount.com/")!, in: manifest))
    #expect(!Extensions.webAccessible(page("/assets/../secret.svg"), from: other, in: manifest))
    #expect(!Extensions.webAccessible(page("/assets%2Fx.svg"), from: other, in: manifest))
    #expect(!Extensions.webAccessible(page("/assets/x%5C.svg"), from: other, in: manifest))
    #expect(!Extensions.webAccessible(page("/secret.html"), from: other, in: manifest))
    #expect(Extensions.webAccessible(page("/a?c.html".replacingOccurrences(of: "?", with: "%3F")), from: other, in: manifest))
    #expect(!Extensions.webAccessible(page("/abc.html"), from: other, in: manifest))
    let two = ["manifest_version": 2, "web_accessible_resources": ["page.html"]] as [String: Any]
    #expect(Extensions.webAccessible(page("/page.html"), from: other, in: two))
    #expect(!Extensions.webAccessible(page("/page.html"), from: nil, in: two))
}

/// Bitwarden names its clean-up methods with Symbol.dispose, which WebKit
/// doesn't have: the shim gives it, before any extension code runs.
@Test func disposalSymbolsAreThere() {
    let context = JSContext()!
    context.evaluateScript(contentWorld)
    context.evaluateScript(ExtensionShims.contentScript)
    #expect(context.exception == nil)
    #expect(context.evaluateScript("Symbol.dispose === Symbol.for('Symbol.dispose') && typeof Symbol.asyncDispose === 'symbol'").toBool())
}

/// A message the worker sends reaches one of the extension's pages once,
/// whether WebKit brings it, the channel does, or both in either order; two
/// alike are two, and a content script's alike one pairs with none.
@Test func relayedMessagesReachAPageOnce() throws {
    let folder = try extensionFolder(["manifest.json": #"{"manifest_version": 3, "background": {"service_worker": "bg.js"}}"#, "bg.js": ""])
    defer { try? FileManager.default.removeItem(at: folder) }
    // One of the extension's pages: a channel the test posts on, timers it
    // runs, and WebKit's onMessage it fires.
    let page = """
        globalThis.location = { protocol: "chrome-extension:", origin: "chrome-extension://abc", pathname: "/page.html", href: "chrome-extension://abc/page.html" };
        const channels = {}, posted = [];
        globalThis.BroadcastChannel = class { constructor(name) { channels[name] = this; } postMessage(m) { posted.push(m); } };
        let timers = [];
        globalThis.setTimeout = (f) => { timers.push(f); return timers.length; };
        globalThis.clearTimeout = globalThis.setInterval = globalThis.clearInterval = () => {};
        const run = () => { for (let i = 0; i < 5 && timers.length; i++) { const now = timers; timers = []; now.forEach((f) => f()); } };
        const listeners = [];
        globalThis.chrome = { runtime: { id: "abc", getURL: (p) => "chrome-extension://abc/" + p,
          getManifest: () => ({ background: { service_worker: "bg.js" } }), sendMessage: () => Promise.resolve(),
          sendNativeMessage: () => Promise.resolve(), connect: () => ({}),
          onMessage: { addListener(f) { listeners.push(f); }, removeListener() {}, hasListener() { return false; } } } };
        """
    let context = JSContext()!
    context.evaluateScript(page)
    context.evaluateScript(ExtensionShims.shim(for: folder))
    #expect(context.exception == nil)
    context.evaluateScript("""
        const heard = [];
        chrome.runtime.onMessage.addListener((m) => { heard.push(JSON.stringify(m)); });
        const worker = { id: "abc", url: "chrome-extension://abc/bg.js" };
        const native = (m, sender = worker) => listeners.forEach((f) => f(m, sender, () => {}));
        const relayed = (m) => channels["nerda-messages"].onmessage({ data: { relay: m, from: "w", url: worker.url } });
        native({ a: 1 }); relayed({ a: 1 }); run();
        relayed({ b: 2 }); run(); native({ b: 2 });
        relayed({ c: 3 }); relayed({ c: 3 }); run();
        native({ d: 4 }, { id: "abc", url: "https://example.com/" }); relayed({ d: 4 }); run();
        """)
    #expect(context.exception == nil)
    #expect(context.evaluateScript("heard.join(' ')").toString() == #"{"a":1} {"b":2} {"c":3} {"c":3} {"d":4} {"d":4}"#)
    // What the page sends goes on the channel too; the shim's own envelopes don't.
    context.evaluateScript("""
        posted.length = 0;
        chrome.runtime.sendMessage({ e: 5 }); chrome.runtime.sendMessage({ __nerdaCall: {} });
        """)
    #expect(context.evaluateScript("JSON.stringify(posted.filter((m) => m.relay !== undefined).map((m) => m.relay))").toString() == #"[{"e":5}]"#)
}

/// A new copy takes an extension's place in one step: the old one ends up
/// where the new one was, and a copy that can't be moved in leaves the
/// working one where it is.
@Test func replacingAnExtensionKeepsTheWorkingCopy() throws {
    let target = try extensionFolder(["bg.js": "old"])
    let staged = try extensionFolder(["bg.js": "new"])
    defer { for folder in [target, staged] { try? FileManager.default.removeItem(at: folder) } }
    let read = { (folder: URL) in try String(contentsOf: folder.appendingPathComponent("bg.js"), encoding: .utf8) }

    try Extensions.replace(staged, at: target)
    #expect(try read(target) == "new")
    #expect(try read(staged) == "old")

    try FileManager.default.removeItem(at: staged)
    #expect(throws: (any Error).self) { try Extensions.replace(staged, at: target) }
    #expect(try read(target) == "new")

    let empty = staged.deletingLastPathComponent().appendingPathComponent("nerda-ext-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: empty) }
    try Extensions.replace(target, at: empty)
    #expect(try read(empty) == "new")
    #expect(!FileManager.default.fileExists(atPath: target.path))
}

/// The worker hears its popup's messages and ports with no tab, as Chrome
/// gives them (Passbolt turned a port with one away); a tab's, and one of
/// its pages framed in a website's, keep theirs.
@Test func popupMessagesComeWithNoTab() throws {
    let folder = try extensionFolder(["manifest.json": #"{"manifest_version": 3, "background": {"service_worker": "bg.js"}}"#, "bg.js": ""])
    defer { try? FileManager.default.removeItem(at: folder) }
    let worker = """
        globalThis.ServiceWorkerGlobalScope = { [Symbol.hasInstance]: (o) => o === globalThis };
        globalThis.setTimeout = globalThis.clearTimeout = globalThis.setInterval = globalThis.clearInterval = () => {};
        const event = () => ({ fire(...a) { this.all.forEach((f) => f(...a)); }, all: [],
          addListener(f) { this.all.push(f); }, removeListener() {}, hasListener() { return false; } });
        globalThis.chrome = { runtime: { id: "abc", getURL: (p) => "chrome-extension://abc/" + p,
          getManifest: () => ({ background: { service_worker: "bg.js" } }), sendMessage: () => Promise.resolve(),
          sendNativeMessage: () => Promise.resolve(), connect: () => ({}),
          onMessage: event(), onConnect: event(), onInstalled: event() } };
        """
    let context = JSContext()!
    context.evaluateScript(worker)
    context.evaluateScript(ExtensionShims.shim(for: folder))
    #expect(context.exception == nil)
    context.evaluateScript("""
        const popup = "chrome-extension://abc/popup.html";
        const senders = {
          popup: { id: "abc", url: popup, frameId: 0, tab: { id: 9, index: NaN, url: popup } },
          tab: { id: "abc", url: "https://example.com/", frameId: 0, tab: { id: 2, index: 0, url: "https://example.com/" } },
          framed: { id: "abc", url: popup, frameId: 3, tab: { id: 2, index: 0, url: "https://example.com/" } },
        };
        const heard = [];
        chrome.runtime.onMessage.addListener((m, sender) => { heard.push(m + ":" + !!sender.tab); });
        chrome.runtime.onConnect.addListener((port) => { heard.push(port.name + ":" + !!port.sender.tab); });
        for (const [name, sender] of Object.entries(senders)) {
          chrome.runtime.onMessage.fire(name, sender, () => {});
          chrome.runtime.onConnect.fire({ name: "port-" + name, sender, onMessage: event(), onDisconnect: event(), postMessage() {} });
        }
        """)
    #expect(context.exception == nil)
    #expect(context.evaluateScript("heard.join(' ')").toString()
        == "popup:false port-popup:false tab:true port-tab:true framed:true port-framed:true")
    #expect(context.evaluateScript("chrome.tabGroups.Color.BLUE").toString() == "blue")
}

/// What an extension is held to, as in Chrome: no tab sent to script or a
/// file, no reach into other extensions' pages, and from a store page only
/// the extension that page is about.
@MainActor @Test func extensionsGetNoMoreThanChromeGives() throws {
    #expect(throws: (any Error).self) { try Extensions.mayOpen(URL(string: "javascript:alert(1)")!) }
    #expect(throws: (any Error).self) { try Extensions.mayOpen(URL(string: "JavaScript:alert(1)")!) }
    #expect(throws: (any Error).self) { try Extensions.mayOpen(URL(fileURLWithPath: "/etc/hosts")) }
    try Extensions.mayOpen(URL(string: "https://example.com/")!)
    try Extensions.mayOpen(URL(string: "chrome-extension://abc/page.html")!)

    let pattern = { (text: String) in try WKWebExtension.MatchPattern(string: text) }
    #expect(Extensions.reachesExtensions(try pattern("chrome-extension://*/*")))
    #expect(!Extensions.reachesExtensions(try pattern("<all_urls>")))
    #expect(!Extensions.reachesExtensions(try pattern("https://*/*")))
    #expect(Extensions.othersPage(URL(string: "chrome-extension://other/popup.html"), of: "mine"))
    #expect(!Extensions.othersPage(URL(string: "chrome-extension://mine/popup.html"), of: "mine"))
    #expect(!Extensions.othersPage(URL(string: "https://example.com/"), of: "mine"))

    let id = String(repeating: "a", count: 32), other = String(repeating: "b", count: 32)
    let store = { (text: String) in WebStore.extensionID(on: URL(string: text)) }
    #expect(store("https://chromewebstore.google.com/detail/name/\(id)") == id)
    #expect(store("https://chromewebstore.google.com/detail/\(id)/reviews") == id)
    #expect(store("https://chrome.google.com/webstore/detail/name/\(id)") == id)
    #expect(store("http://chromewebstore.google.com/detail/name/\(id)") == nil)
    #expect(store("https://someone@chromewebstore.google.com/detail/name/\(id)") == nil)
    #expect(store("https://chromewebstore.google.com/search/\(other)") == nil)
    #expect(store("https://chromewebstore.google.com/detail/name/\(id)?x=\(other)") == id)
    #expect(store("https://example.com/detail/name/\(id)") == nil)
}
