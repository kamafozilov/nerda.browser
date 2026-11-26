import Foundation
import UniformTypeIdentifiers
import WebKit

/// Giving a page files without a panel: `upload` presses the file control,
/// and the panel the page opens is answered with the files staged for it
/// (`AgentUploads`), never shown.
nonisolated extension AgentVerb {
    static let fileVerbs: [AgentVerb] = [upload]

    static let upload = AgentVerb(
        name: "upload",
        summary: """
            Give a file control of an Agent tab's page files from this Mac, by the control's ref (the \
            "Choose file" box, or the button that opens it) and the files' whole paths, up to 100 MB in all. \
            Nerda presses the control and answers the page's file panel with the files, so no panel shows. \
            Answers with what the page did with them, as click does.
            """,
        arguments: [
            .tab,
            .string("ref", "The file control, or the button or label that opens it, as snapshot named it, such as e12"),
            AgentArgument(name: "paths", schema: [
                "type": "array", "items": ["type": "string"],
                "description": "The files' whole paths on this Mac, such as /Users/me/Documents/report.pdf",
            ], required: true),
        ]
    ) { call in
        let tab = try call.tab()
        let ref = try call.string("ref")
        let files = try AgentUploads.files(call.arguments["paths"])
        return try await AgentPage.act(tab, for: call) {
            try await AgentPage.upload(files, to: ref, in: tab)
        }
    }
}

/// Files an agent gave for a tab's next file panel (`upload`), kept for
/// `staysFor`: the page's own panel takes them (`Browser`'s open-panel
/// delegate), and none is ever shown in an Agent tab.
@MainActor
enum AgentUploads {
    /// The most an upload may hold, all its files together.
    static let limit: Int64 = 100 * 1024 * 1024
    /// How long staged files wait for the page to open its panel.
    static let staysFor = Duration.seconds(20)

    private final class Staged {
        let files: [URL]
        let until: ContinuousClock.Instant
        var taken = false

        init(_ files: [URL], until: ContinuousClock.Instant) {
            self.files = files
            self.until = until
        }
    }

    private static let staged = NSMapTable<Tab, Staged>.weakToStrongObjects()

    /// The paths an agent gave, checked: whole paths of files there to read,
    /// no folders, together within `limit`.
    static func files(_ argument: AgentJSON?) throws -> [URL] {
        let paths = argument?.array?.compactMap(\.string) ?? argument?.string.map { [$0] } ?? []
        guard !paths.isEmpty, paths.count == argument?.array?.count ?? 1 else {
            throw AgentError(.invalid, "Give paths as a list of the files' whole paths, such as [\"/Users/me/report.pdf\"].")
        }
        var total: Int64 = 0
        let files = try paths.map { path in
            let expanded = (path as NSString).expandingTildeInPath
            guard expanded.hasPrefix("/") else {
                throw AgentError(.invalid, "\(path) isn't a whole path: give it from the top, such as /Users/me/\(path).")
            }
            let file = URL(fileURLWithPath: expanded).standardizedFileURL
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isFolder) else {
                throw AgentError(.invalid, "There is no file at \(path).")
            }
            guard !isFolder.boolValue else { throw AgentError(.invalid, "\(path) is a folder; upload takes files.") }
            guard FileManager.default.isReadableFile(atPath: file.path) else {
                throw AgentError(.invalid, "Nerda may not read \(path).")
            }
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            return file
        }
        guard total <= limit else {
            let come = size(total) == size(limit) ? "\(total) bytes" : size(total)
            throw AgentError(.invalid, "The files come to \(come), more than the \(size(limit)) an upload may hold, so nothing was uploaded.")
        }
        return files
    }

    /// Readied for the tab's next file panel, for `staysFor`.
    static func stage(_ files: [URL], for tab: Tab) {
        staged.setObject(Staged(files, until: .now + staysFor), forKey: tab)
    }

    /// Whether the files staged for the tab were given to a panel.
    static func wereTaken(on tab: Tab) -> Bool { staged.object(forKey: tab)?.taken ?? false }

    static func unstage(_ tab: Tab) { staged.removeObject(forKey: tab) }

    /// The answer to a file panel an Agent tab's page opened: the files
    /// staged for it, or none (cancelled), told to the agent. Only one when
    /// the control takes one.
    static func panel(on tab: Tab?, multiple: Bool) -> [URL]? {
        guard let tab else { return nil }
        guard let stage = staged.object(forKey: tab), !stage.taken, ContinuousClock.now < stage.until else {
            PageNotices.post("the page asked for files, and Nerda answered none: give them with upload", on: tab)
            return nil
        }
        stage.taken = true
        guard multiple || stage.files.count == 1 else {
            PageNotices.post("the file control takes one file, so it got only \(stage.files[0].lastPathComponent)", on: tab)
            return [stage.files[0]]
        }
        return stage.files
    }

    /// `12 KB`, `100 MB`, `104.9 MB`: binary units, the same on every Mac
    /// whatever its language, for agents to read.
    nonisolated static func size(_ bytes: Int64) -> String {
        guard bytes >= 1024 else { return bytes == 1 ? "1 byte" : "\(bytes) bytes" }
        let (amount, unit) = bytes < 1024 * 1024 ? (Double(bytes) / 1024, "KB") : (Double(bytes) / 1024 / 1024, "MB")
        let rounded = (amount * 10).rounded() / 10
        return (rounded == rounded.rounded() ? String(Int(rounded)) : String(rounded)) + " " + unit
    }
}

extension AgentPage {
    /// How long, after pressing a file control, its page may take to open
    /// its panel.
    static let panelWithin = Duration.seconds(2)

    /// Gives the file control `ref` names the files: pressed as a person
    /// would (`click`), its panel answered with them (`AgentUploads`).
    /// Should no panel come (the control isn't shown, or the page opens
    /// none), the control is given them by script. Answers the action's
    /// line for `act`.
    static func upload(_ files: [URL], to ref: String, in agentTab: AgentTab) async throws -> String {
        let tab = agentTab.tab
        let element = try await element(ref, in: agentTab)
        let what = try await describe(element)
        let names = files.map(\.lastPathComponent).joined(separator: ", ")
        let total = files.reduce(Int64(0)) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        let chose = "chose \(files.count == 1 ? "a file" : "\(files.count) files") (\(AgentUploads.size(total))) for \(what): \(names)"

        AgentUploads.stage(files, for: tab)
        var pressed = true
        do {
            _ = try await click(ref, in: agentTab)
        } catch let error as AgentError where error.code == .failed {
            pressed = false // not shown: nothing a person could press
        } catch {
            AgentUploads.unstage(tab)
            throw error
        }
        if pressed {
            let end = ContinuousClock.now + panelWithin
            while !AgentUploads.wereTaken(on: tab), ContinuousClock.now < end {
                try? await Task.sleep(for: .milliseconds(25))
            }
            if AgentUploads.wereTaken(on: tab) {
                AgentUploads.unstage(tab)
                return chose
            }
        }

        // No panel: the control's files set by script, as a drop would.
        let given = try files.map { file in
            let data = try Data(contentsOf: file)
            let type = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? ""
            return ["name": file.lastPathComponent, "type": type, "data": data.base64EncodedString()]
        }
        let put = await unlessHeld(tab, by: .now + .seconds(10)) {
            try await run(fallbackScript, on: element, arguments: ["files": given])
        } as? [String: Any]
        guard let put, let count = put["count"] as? Int else {
            // Left staged: a panel the page opens a little later gets them.
            throw AgentError(.failed, """
                \(what) opened no file panel, and Nerda found no file control there to give the files to. \
                They stay ready for a panel the page opens in the next \(Int(AgentUploads.staysFor.components.seconds)) seconds.
                """)
        }
        AgentUploads.unstage(tab)
        if count < files.count {
            PageNotices.post("the file control takes one file, so it got only \(files[0].lastPathComponent)", on: tab)
        }
        PageNotices.post("\(what) opened no file panel, so Nerda gave the files to its file control by script", on: tab)
        return chose
    }

    /// `e7 button "Upload"`, as the page model names the element.
    private static func describe(_ element: AgentElement) async throws -> String {
        let described = try await run("return nerdaAgent.describe(element)", on: element) as? [String: Any] ?? [:]
        var words = [element.ref]
        if let role = described["role"] as? String { words.append(role) }
        if let name = described["name"] as? String, !name.isEmpty { words.append(String(reflecting: String(name.prefix(80)))) }
        return words.joined(separator: " ")
    }

    /// Finds the file control for `element` (itself, the control of its
    /// label, one inside it, or the page's only one) and gives it `files`
    /// (`{name, type, data}` in base64), with the events a choice sends.
    /// Answers `{count}` of files it took, or null with no control.
    private static let fallbackScript = """
        const isFile = (node) => node?.localName === 'input' && node.type === 'file';
        const all = element.ownerDocument.querySelectorAll('input[type=file]');
        const input = [element, element.control, element.querySelector?.('input[type=file]'),
            element.closest?.('label')?.control, all.length === 1 ? all[0] : null].find(isFile);
        if (!input) return null;
        const transfer = new DataTransfer();
        for (const file of (input.multiple ? files : files.slice(0, 1))) {
            const bytes = Uint8Array.from(atob(file.data), (c) => c.charCodeAt(0));
            transfer.items.add(new File([bytes], file.name, { type: file.type }));
        }
        input.files = transfer.files;
        input.dispatchEvent(new Event('input', { bubbles: true, composed: true }));
        input.dispatchEvent(new Event('change', { bubbles: true }));
        return { count: input.files.length };
        """
}
