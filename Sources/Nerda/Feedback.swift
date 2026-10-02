import AppKit
import MetricKit
import SwiftUI

/// Telling Nerda's makers what went wrong, or what would make it better, as
/// an issue on its GitHub repository: Help › Report a Problem… and Suggest an
/// Idea…, and the card at the foot of the sidebar once Nerda has crashed
/// (CrashCard). Each shows the report first and, once you continue, opens
/// GitHub's new issue page in a tab, already filled in. The report travels
/// in that page's address, so nothing leaves the Mac before you continue,
/// and nothing is posted until you submit it there.
///
/// The crash comes from MetricKit, which hands its report over the next time
/// Nerda opens: why it stopped, and the calls it was in, as places in each
/// binary. `./symbolicate.sh` turns Nerda's into function names with the
/// release's Nerda.dSYM.zip (release.sh).
@Observable
final class Feedback: NSObject, MXMetricManagerSubscriber {
    static let shared = Feedback()

    nonisolated static let issues = "https://github.com/kamafozilov/nerda.browser/issues/new"

    /// The last crash's report, kept until it is sent or dismissed.
    private(set) var crash = UserDefaults.standard.string(forKey: crashKey)
    private static let crashKey = "feedback.crash"

    /// At launch, before MetricKit hands over what it has kept.
    func start() { MXMetricManager.shared.add(self) }

    nonisolated func didReceive(_ payloads: [MXDiagnosticPayload]) {
        let crashes = payloads.flatMap { payload in
            (payload.crashDiagnostics ?? []).map { (payload.timeStampEnd, $0) }
        }
        guard let (_, last) = crashes.max(by: { $0.0 < $1.0 }) else { return }
        let report = Self.describe(last)
        Task { @MainActor in
            UserDefaults.standard.set(report, forKey: Self.crashKey)
            withAnimation(.spring(duration: 0.5, bounce: 0.3)) { Feedback.shared.crash = report }
        }
    }

    /// Help › Report a Problem…, with the crash not yet sent if there is one:
    /// the card that offers it is in the sidebar, not with the tabs across the top.
    func reportProblem() {
        let report = crash
        open(template: "problem.md", title: "", body: """
            **What happened?**


            **What did you expect to happen?**


            **How can it be seen again?** (the steps, or the site)


            ---
            \(Self.system)
            \(report.map { "\n" + $0 } ?? "")
            """) { if report != nil { self.dismissCrash() } }
    }

    /// Help › Suggest an Idea….
    func suggestIdea() {
        open(template: "idea.md", title: "", body: """
            **What would you like Nerda to do?**


            **How would it help you?**


            ---
            \(Self.system)
            """)
    }

    /// The card's Send Report.
    func sendCrash() {
        guard let crash else { return }
        open(template: "problem.md", title: "Nerda quit unexpectedly", body: """
            **What were you doing when Nerda quit?** (if you remember)


            ---
            \(crash)
            """) { self.dismissCrash() }
    }

    func dismissCrash() {
        UserDefaults.standard.removeObject(forKey: Self.crashKey)
        withAnimation(.spring(duration: 0.4)) { crash = nil }
    }

    /// In the regular window, where you may be signed in to GitHub, once
    /// you have read what goes and continued: the address carries it to
    /// GitHub as the page opens. Cancel sends nothing and keeps the crash.
    private func open(template: String, title: String, body: String, then sent: @escaping () -> Void = {}) {
        guard let url = Self.issue(template: template, title: title, body: body) else { return }
        let browser = Windows.showRegular()
        let alert = NSAlert()
        alert.messageText = "Send this report to GitHub?"
        alert.informativeText = "Continuing opens it as a new issue on GitHub, to finish there. It's only posted when you submit it."
        alert.addButton(withTitle: "Continue to GitHub")
        alert.addButton(withTitle: "Cancel")
        alert.accessoryView = Self.preview(body)
        let answer = { (answer: NSApplication.ModalResponse) in
            guard answer == .alertFirstButtonReturn else { return }
            withAnimation(.slide) { browser.open(url) }
            sent()
        }
        if let window = browser.window { alert.beginSheetModal(for: window, completionHandler: answer) }
        else { answer(alert.runModal()) }
    }

    /// The report as it will go, to read and scroll through.
    private static func preview(_ body: String) -> NSView {
        let scroll = NSTextView.scrollableTextView()
        scroll.frame = NSRect(x: 0, y: 0, width: 420, height: 220)
        scroll.borderType = .bezelBorder
        let text = scroll.documentView as! NSTextView
        text.string = body
        text.isEditable = false
        text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        text.textContainerInset = NSSize(width: 4, height: 4)
        return scroll
    }

    nonisolated static func issue(template: String, title: String, body: String) -> URL? {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let query = [("template", template), ("title", title), ("body", body)]
            .map { "\($0)=\($1.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&")
        return URL(string: "\(issues)?\(query)")
    }

    /// This Nerda and Mac: "Nerda 0.0.21 · macOS 26.0 (Build 25A354) · Apple silicon".
    nonisolated static var system: String {
        let os = ProcessInfo.processInfo.operatingSystemVersionString.replacingOccurrences(of: "Version ", with: "")
        #if arch(arm64)
        let chip = "Apple silicon"
        #else
        let chip = "Intel"
        #endif
        return "Nerda \(Updater.current) · macOS \(os) · \(chip)"
    }

    /// What `./symbolicate.sh` reads: the version, the binary and the calls
    /// of the thread that crashed, each as "3   Nerda   0x1a2b3c", its place
    /// in the binary's code.
    nonisolated static func describe(_ crash: MXCrashDiagnostic) -> String {
        let meta = crash.metaData
        var why = [crash.exceptionType.map { exceptions[$0.intValue] ?? "exception \($0)" },
                   crash.signal.map { signal in signals[signal.intValue].map { "SIG\($0.uppercased())" } ?? "signal \(signal)" },
                   crash.terminationReason, crash.virtualMemoryRegionInfo].compactMap(\.self).joined(separator: " · ")
        if let reason = crash.exceptionReason { why += "\n\(reason.className): \(reason.composedMessage)" }
        let calls = calls(in: crash.callStackTree.jsonRepresentation())
        let name = Bundle.main.executableURL?.lastPathComponent
        let binary = calls.first { $0.binary == name }?.uuid ?? "unknown"
        return """
            Nerda \(Updater.current) (build \(meta.applicationBuildVersion)) · \(meta.osVersion) · \(meta.platformArchitecture)
            \(why)

            ```
            \(lines(calls).joined(separator: "\n"))
            ```
            Nerda binary \(binary)
            """
    }

    nonisolated struct Call: Equatable {
        let binary: String
        let uuid: String
        let offset: Int
    }

    /// The thread that crashed, innermost call first; at most 40, so the
    /// report fits in the address GitHub opens.
    nonisolated static func calls(in tree: Data) -> [Call] {
        struct Tree: Decodable {
            struct Stack: Decodable {
                let threadAttributed: Bool?
                let callStackRootFrames: [Frame]
            }
            struct Frame: Decodable {
                let binaryName: String?
                let binaryUUID: String?
                let offsetIntoBinaryTextSegment: Int?
                let subFrames: [Frame]?
            }
            let callStacks: [Stack]
        }
        guard let tree = try? JSONDecoder().decode(Tree.self, from: tree),
              let stack = tree.callStacks.first(where: { $0.threadAttributed == true }) ?? tree.callStacks.first
        else { return [] }
        var calls: [Call] = []
        var frame = stack.callStackRootFrames.first
        while let next = frame, calls.count < 40 {
            calls.append(Call(binary: next.binaryName ?? "?", uuid: next.binaryUUID ?? "", offset: next.offsetIntoBinaryTextSegment ?? 0))
            frame = next.subFrames?.first
        }
        return calls
    }

    nonisolated static func lines(_ calls: [Call]) -> [String] {
        let width = calls.map(\.binary.count).max() ?? 0
        return calls.enumerated().map { index, call in
            "\(index)".padding(toLength: 4, withPad: " ", startingAt: 0)
                + call.binary.padding(toLength: width + 2, withPad: " ", startingAt: 0)
                + "0x" + String(call.offset, radix: 16)
        }
    }

    private nonisolated static let exceptions = [
        1: "EXC_BAD_ACCESS", 2: "EXC_BAD_INSTRUCTION", 3: "EXC_ARITHMETIC", 5: "EXC_SOFTWARE",
        6: "EXC_BREAKPOINT", 10: "EXC_CRASH", 11: "EXC_RESOURCE", 12: "EXC_GUARD",
    ]
    private nonisolated static let signals = [
        4: "ill", 5: "trap", 6: "abrt", 7: "emt", 8: "fpe", 9: "kill", 10: "bus", 11: "segv", 12: "sys",
    ]
}

/// At the foot of the sidebar after Nerda has crashed: a report of it, for
/// you to send as an issue on GitHub, or put away.
struct CrashCard: View {
    var incognito = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(Color.orange.gradient, in: Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text("Nerda quit unexpectedly")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                    Text("A report helps fix it.")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.muted)
                }
            }
            HStack(spacing: 6) {
                Button("Send Report") { Feedback.shared.sendCrash() }
                    .buttonStyle(.borderedProminent)
                    .tint(incognito ? Palette.incognitoAccent : .accentColor)
                    .help("Shows the report, then opens it as a new issue on GitHub for you to submit")
                Button("Dismiss") { Feedback.shared.dismissCrash() }
                    .buttonStyle(.bordered)
            }
            .controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(Palette.hover))
        .overlay(shape.strokeBorder(Palette.rim))
    }
}
