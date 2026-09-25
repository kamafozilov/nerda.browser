import AppKit
import CryptoKit
import Security
import SwiftUI

// Keeping the released Nerda up to date, from the repository's GitHub
// Releases: release.sh publishes each version there with Nerda.dmg for
// people and Nerda.zip for this. A little after launch and every few hours
// the latest release is read; if it is newer, Nerda says so with what's new,
// and on "Install and Relaunch" fetches the ZIP, checks it, puts it where
// this bundle is, and opens again as the new one, tabs and all.
//
// Only the bundle changes hands. The data folder (Edition.folder), the
// defaults and the keychain are left alone; the new build keeps the bundle id
// and the signing team, so the keychain opens for it as for the old one.
// Development builds never update (Edition.updates).
//
// The disk part (Swap), and the Developer ID requirement, follow Updater.swift in Search
// (https://github.com/driceroland/Search):
//
//   Copyright (c) 2026 Office Commun
//
//   Permission is hereby granted, free of charge, to any person obtaining a
//   copy of this software and associated documentation files (the
//   "Software"), to deal in the Software without restriction, including
//   without limitation the rights to use, copy, modify, merge, publish,
//   distribute, sublicense, and/or sell copies of the Software, and to permit
//   persons to whom the Software is furnished to do so, subject to the
//   following conditions:
//
//   The above copyright notice and this permission notice shall be included
//   in all copies or substantial portions of the Software.
//
//   THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
//   OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
//   MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN
//   NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM,
//   DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
//   OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE
//   USE OR OTHER DEALINGS IN THE SOFTWARE.

@Observable
final class Updater {
    static let shared = Updater()

    /// The latest release, as release.sh describes it in release.json, one of
    /// its files, in the shape GitHub's API gives it. Not the API itself: it
    /// takes 60 requests an hour from an address without an account, and a
    /// provider's shared address runs out of them. NERDA_UPDATES points a test
    /// run at a file of the same shape elsewhere (docs/releasing.md).
    nonisolated static let feed = override
        ?? URL(string: "https://github.com/kamafozilov/nerda.browser/releases/latest/download/release.json")!
    /// Over https, or on this Mac, the only place plain http is taken from.
    nonisolated static let override: URL? = {
        guard let text = ProcessInfo.processInfo.environment["NERDA_UPDATES"], let url = URL(string: text),
              isSafe(url) else { return nil }
        return url
    }()

    nonisolated static func isSafe(_ url: URL) -> Bool {
        url.scheme == "https" || url.scheme == "http" && Browser.isThisMac(url.host() ?? "")
    }

    nonisolated struct Release: Sendable {
        let version: String
        /// The release's text on GitHub: its part of CHANGELOG.md.
        let notes: String
        /// The release on GitHub, where the disk image is.
        let page: URL
        let archive: URL
        /// Hex SHA-256 of the ZIP, as GitHub computed it.
        let sha256: String?
    }

    enum State: Equatable {
        case idle, checking, upToDate, available(String), installing, failed(String)

        var isBusy: Bool { self == .checking || self == .installing }

        var detail: String {
            switch self {
            case .idle: "Check for the latest version."
            case .checking: "Checking for updates…"
            case .upToDate: "Nerda is up to date."
            case .available(let version): "Version \(version) is available."
            case .installing: "Installing update. Nerda will relaunch…"
            case .failed(let message): message
            }
        }
    }
    private(set) var state = State.idle
    var canCheck: Bool { Edition.updates && !state.isBusy }
    /// Quitting to come back as the new one: no asking first.
    private(set) var relaunching = false
    /// The version last put in front of the user: not offered again unasked
    /// until the next launch, whatever the answer was.
    private var offered: String?
    private var clock: Timer?

    nonisolated static var current: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    /// At launch: a look a little later, once the tabs are up, and every six
    /// hours after, for a browser that is left open for days.
    func start() {
        Swap.sweep()
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            Swap.sweep()
        }
        clock = Timer.scheduledTimer(withTimeInterval: 6 * 60 * 60, repeats: true) { _ in
            MainActor.assumeIsolated { Updater.shared.check(asked: false) }
        }
        clock?.tolerance = 10 * 60
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { self.check(asked: false) }
    }

    /// `asked`: from Check for Updates…, which always answers, even "none".
    func check(asked: Bool) {
        guard canCheck else { return }
        state = .checking
        Task {
            let found = try? await Self.latest()
            guard let found else {
                state = .failed("Couldn't check for updates. Check your connection and try again.")
                if asked { tell("Couldn't check for updates", "Check your connection and try again.") }
                return
            }
            if Version.isNewer(found.version, than: Self.current) {
                state = .available(found.version)
                if asked || offered != found.version { offer(found) }
            } else {
                state = .upToDate
                if asked { tell("You're up to date", "Nerda \(Self.current) is the newest version.") }
            }
        }
    }

    private func offer(_ release: Release) {
        let alert = NSAlert()
        alert.messageText = "Nerda \(release.version) is available"
        alert.informativeText = "You have \(Self.current). Nerda opens again as the new one, with your tabs."
        if !release.notes.isEmpty {
            let notes = NSHostingView(rootView: Notes(text: release.notes))
            notes.frame = NSRect(x: 0, y: 0, width: 400, height: 220)
            alert.accessoryView = notes
        }
        alert.addButton(withTitle: "Install and Relaunch")
        alert.addButton(withTitle: "Later")
        offered = release.version
        NSApp.requestUserAttention(.informationalRequest)
        present(alert) { [self] answer in
            if answer == .alertFirstButtonReturn { install(release) }
        }
    }

    private func install(_ release: Release) {
        state = .installing
        Task {
            do {
                try await Task.detached(priority: .userInitiated) { try await Swap.install(release) }.value
                relaunch()
            } catch {
                state = .failed("Couldn't install the update. Try again.")
                let alert = NSAlert()
                alert.messageText = "Couldn't install Nerda \(release.version)"
                alert.informativeText = ((error as? Swap.Refused)?.reason ?? "The download didn't finish.")
                    + " The disk image is on GitHub."
                alert.addButton(withTitle: "Open GitHub")
                alert.addButton(withTitle: "Cancel")
                present(alert) { answer in
                    if answer == .alertFirstButtonReturn { NSWorkspace.shared.open(release.page) }
                }
            }
        }
    }

    /// Quits, and a shell opens the bundle again once this process is gone
    /// (`open` on a running app only brings it forward). Quitting goes
    /// through NSApp, so the tabs and history are saved as for ⌘Q.
    private func relaunch() {
        relaunching = true
        var open = ["/usr/bin/open"]
        if let override = Self.override { open += ["--env", "NERDA_UPDATES=\(override.absoluteString)"] }
        let waiter = Process()
        waiter.executableURL = URL(fileURLWithPath: "/bin/sh")
        waiter.arguments = [
            "-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; shift; exec \"$@\"",
            "sh", String(ProcessInfo.processInfo.processIdentifier),
        ] + open + [Bundle.main.bundlePath]
        try? waiter.run()
        NSApp.terminate(nil)
    }

    private func tell(_ message: String, _ detail: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        present(alert) { _ in }
    }

    /// On the browser window when there is one, so only it waits for the answer.
    private func present(_ alert: NSAlert, then answer: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window = NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) {
            alert.beginSheetModal(for: window, completionHandler: answer)
        } else {
            answer(alert.runModal())
        }
    }

    nonisolated private static func latest() async throws -> Release {
        let request = URLRequest(url: feed, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Swap.Refused.feed }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let found = try decoder.decode(GitHubRelease.self, from: data)
        guard let zip = found.assets.first(where: { $0.name == "Nerda.zip" }), isSafe(zip.browserDownloadUrl)
        else { throw Swap.Refused.feed }
        return Release(
            version: found.tagName.hasPrefix("v") ? String(found.tagName.dropFirst()) : found.tagName,
            notes: found.body?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            page: found.htmlUrl,
            archive: zip.browserDownloadUrl,
            sha256: zip.digest.flatMap { $0.hasPrefix("sha256:") ? String($0.dropFirst(7)) : nil }
        )
    }

    /// What a shipped Nerda meets, as `codesign -d -r-` prints it: Apple's
    /// anchor, the Developer ID intermediate (…6.2.6) and a Developer ID
    /// Application certificate (…6.1.13) of this team, for this bundle id. A
    /// certificate made up with the team's name in it meets none of that.
    nonisolated static func developerID(team: String, identifier: String) -> SecRequirement? {
        let text = "anchor apple generic and identifier \"\(identifier)\""
            + " and certificate 1[field.1.2.840.113635.100.6.2.6]"
            + " and certificate leaf[field.1.2.840.113635.100.6.1.13]"
            + " and certificate leaf[subject.OU] = \"\(team)\""
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess else { return nil }
        return requirement
    }

    nonisolated private struct GitHubRelease: Decodable {
        struct Asset: Decodable {
            let name: String
            let browserDownloadUrl: URL
            let digest: String?
        }

        let tagName: String
        let body: String?
        let htmlUrl: URL
        let assets: [Asset]
    }
}

/// Versions as release.sh tags them: major.minor.patch, compared as numbers.
nonisolated enum Version {
    static func isNewer(_ version: String, than other: String) -> Bool {
        parts(other).lexicographicallyPrecedes(parts(version))
    }

    private static func parts(_ version: String) -> [Int] {
        let numbers = version.split(separator: ".").map { Int($0) ?? 0 }
        return (0..<3).map { $0 < numbers.count ? numbers[$0] : 0 }
    }
}

/// What's new, from the release's Markdown: its ### headings in bold, its
/// items as bullets.
private struct Notes: View {
    let text: String

    var body: some View {
        ScrollView {
            Text(styled)
                .font(.system(size: 12))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
    }

    private var styled: AttributedString {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            if line.hasPrefix("#") { return "**\(line.drop(while: { $0 == "#" || $0 == " " }))**" }
            if line.hasPrefix("- ") { return "•  " + line.dropFirst(2) }
            return String(line)
        }
        let markdown = lines.joined(separator: "\n")
        return (try? AttributedString(markdown: markdown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(markdown)
    }
}

/// The part that touches the disk, off the main thread. Every step checks
/// before anything changes, and the only things ever removed are the scratch
/// folder it made and the `.old` bundle it set aside.
nonisolated private enum Swap {
    enum Refused: Error {
        case feed, unsigned, readOnly, download, hash, archive, wrongApp, notNewer, wrongTeam, move

        var reason: String {
            switch self {
            case .feed, .download, .archive: "The download didn't finish."
            case .unsigned: "This copy of Nerda isn't signed, so it can't tell a real update from another app."
            case .readOnly: "Nerda can't replace itself where it is. Move it to the Applications folder first."
            case .hash: "The download didn't match the release."
            case .wrongApp, .notNewer, .wrongTeam: "The download isn't a newer Nerda signed by the same developer."
            case .move: "The new version couldn't be put in place."
            }
        }
    }

    static var target: URL { Bundle.main.bundleURL }

    /// The bundle set aside during a swap: a sibling, so both moves are
    /// renames on one volume.
    static var aside: URL {
        target.deletingLastPathComponent().appendingPathComponent(target.lastPathComponent + ".old")
    }

    static func install(_ release: Updater.Release) async throws {
        let files = FileManager.default
        // No team: an ad-hoc build, which can't tell who made a download.
        guard let team = teamID(of: target) else { throw Refused.unsigned }
        guard files.isWritableFile(atPath: target.deletingLastPathComponent().path) else { throw Refused.readOnly }

        // On the app's volume, so the last move is a rename. Gone whatever happens.
        let scratch = try files.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: target, create: true)
        defer { try? files.removeItem(at: scratch) }

        let zip = scratch.appending(path: "Nerda.zip")
        var request = URLRequest(url: release.archive, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        let (got, response) = try await URLSession.shared.download(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Refused.download }
        try files.moveItem(at: got, to: zip)
        // GitHub gives every asset's; one without is not taken.
        guard let expected = release.sha256, try digest(of: zip) == expected.lowercased() else { throw Refused.hash }

        let unpacked = scratch.appending(path: "unpacked")
        try run("/usr/bin/ditto", "-x", "-k", zip.path, unpacked.path)
        guard let fresh = try files.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "app" })
        else { throw Refused.archive }
        try verify(fresh, team: team)
        try swap(fresh)
    }

    private static func digest(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var sha = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { sha.update(data: chunk) }
        return sha.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// ditto keeps the bundle as Archive Utility would. The app declares no
    /// LSFileQuarantineEnabled, so what it downloads carries no quarantine
    /// flag and Gatekeeper doesn't look again: the checking is done in verify.
    private static func run(_ tool: String, _ arguments: String...) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Refused.archive }
    }

    /// Trusted not for having arrived but for being this app, newer, with a
    /// signature that holds up under the strict check, everything inside it
    /// included, from a Developer ID certificate Apple gave the same team.
    private static func verify(_ bundle: URL, team: String) throws {
        guard let info = NSDictionary(contentsOf: bundle.appending(path: "Contents/Info.plist")),
              let identifier = Bundle.main.bundleIdentifier, info["CFBundleIdentifier"] as? String == identifier
        else { throw Refused.wrongApp }
        guard Version.isNewer(info["CFBundleShortVersionString"] as? String ?? "", than: Updater.current) else {
            throw Refused.notNewer
        }
        var code: SecStaticCode?
        let strict = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode)
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess, let code,
              let requirement = Updater.developerID(team: team, identifier: identifier),
              SecStaticCodeCheckValidity(code, strict, requirement) == errSecSuccess
        else { throw Refused.wrongTeam }
        guard teamID(of: bundle) == team else { throw Refused.wrongTeam }
    }

    /// The team that signed a bundle; nil for an ad-hoc signature, or none.
    private static func teamID(of bundle: URL) -> String? {
        var code: SecStaticCode?
        var info: CFDictionary?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess, let code,
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess
        else { return nil }
        return (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// Two renames, the first undone if the second fails. The running app
    /// keeps its files: the kernel follows the rename, and it runs on from
    /// `.old` until it quits.
    private static func swap(_ fresh: URL) throws {
        let files = FileManager.default
        sweep()
        guard !files.fileExists(atPath: aside.path) else { throw Refused.move }
        try files.moveItem(at: target, to: aside)
        do {
            try files.moveItem(at: fresh, to: target)
        } catch {
            try? files.moveItem(at: aside, to: target)
            throw Refused.move
        }
    }

    /// Removes the bundle a swap set aside, once nothing runs from it: at
    /// quit, and at the next launch after a quit that wasn't clean. Only ever
    /// a `.old` that is this app.
    static func sweep() {
        guard let info = NSDictionary(contentsOf: aside.appending(path: "Contents/Info.plist")),
              info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier
        else { return }
        try? FileManager.default.removeItem(at: aside)
    }
}
