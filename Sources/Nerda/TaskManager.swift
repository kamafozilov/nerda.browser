import AppKit
import SwiftUI
import WebKit

/// Window › Task Manager, as Chrome's: what each tab, extension and helper
/// of Nerda's takes of memory and CPU, kept up every second. Double-click a
/// tab to go to it; End Process closes the tabs chosen.
enum TaskManager {
    private static var window: NSWindow?

    static func show() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 460),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.title = "Task Manager"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: TaskList())
            if !window.setFrameUsingName("TaskManager") { window.center() }
            window.setFrameAutosaveName("TaskManager")
            // Let go of when closed, so nothing is measured while it isn't open.
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
                MainActor.assumeIsolated { Self.window = nil }
            }
            Self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
    }
}

private nonisolated struct TaskRow: Identifiable, Sendable {
    let id: String
    let name: String
    var site: URL?
    var symbol = "globe"
    /// Footprint in bytes, as Activity Monitor's Memory column; 0 with no process (asleep).
    var memory: UInt64 = 0
    /// Share of one core over the last second, as Activity Monitor's % CPU.
    var cpu = 0.0
    var status = ""
    var tab: Tab.ID?
}

private struct TaskList: View {
    @State private var rows: [TaskRow] = []
    @State private var selection = Set<TaskRow.ID>()
    @State private var order = [KeyPathComparator(\TaskRow.memory, order: .reverse)]
    @State private var last: (at: Date, usage: [pid_t: rusage_info_v4])?

    var body: some View {
        VStack(spacing: 0) {
            Table(rows.sorted(using: order), selection: $selection, sortOrder: $order) {
                TableColumn("Task", value: \.name) { row in
                    HStack(spacing: 6) {
                        if row.site != nil {
                            TabIcon(site: row.site, loading: false)
                        } else {
                            Image(systemName: row.symbol).frame(width: 16)
                        }
                        Text(row.name).lineLimit(1)
                    }
                }
                .width(min: 200, ideal: 340)
                TableColumn("Memory", value: \.memory) { row in
                    Text(row.memory == 0 ? "–" : "\(row.memory >> 20) MB").monospacedDigit()
                }
                .width(min: 70, ideal: 90)
                TableColumn("CPU", value: \.cpu) { row in
                    Text(row.memory == 0 ? "–" : String(format: "%.1f", row.cpu)).monospacedDigit()
                }
                .width(min: 50, ideal: 60)
                TableColumn("Status", value: \.status)
                    .width(min: 70, ideal: 110)
            }
            .contextMenu(forSelectionType: TaskRow.ID.self) { _ in } primaryAction: { ids in
                guard let tab = rows.first(where: { ids.contains($0.id) })?.tab, let browser = browser(of: tab) else { return }
                browser.select(tab)
                browser.window?.makeKeyAndOrderFront(nil)
            }
            HStack {
                Text("Total: \(rows.reduce(0) { $0 + $1.memory } >> 20) MB")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Spacer()
                Button("End Process") {
                    for row in rows where selection.contains(row.id) {
                        if let tab = row.tab { browser(of: tab)?.close(tab) }
                    }
                    selection = []
                    refresh()
                }
                .disabled(!rows.contains { selection.contains($0.id) && $0.tab != nil })
            }
            .padding(10)
        }
        .task {
            while !Task.isCancelled {
                refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func refresh() {
        let now = Date.now
        let usage = Dictionary(Processes.all().map { ($0.pid, $0.usage) }) { a, _ in a }
        func measured(_ row: inout TaskRow, _ pid: pid_t?) {
            guard let pid, let after = usage[pid] else { return }
            row.memory = after.ri_phys_footprint
            if let last, let before = last.usage[pid] {
                let ticks = (after.ri_user_time + after.ri_system_time) &- (before.ri_user_time + before.ri_system_time)
                row.cpu = Processes.seconds(ticks) / now.timeIntervalSince(last.at) * 100
            }
        }
        var claimed: Set<pid_t> = [getpid()]
        var list: [TaskRow] = []

        var nerda = TaskRow(id: "nerda", name: "Nerda", symbol: "macwindow")
        measured(&nerda, getpid())
        list.append(nerda)

        for browser in browsers {
            for tab in browser.inTurn where tab.hasPage {
                let pid = tab.pid
                if let pid { claimed.insert(pid) }
                // A locked incognito window's tabs stay unseen here too.
                var row = TaskRow(id: tab.id.uuidString,
                                  name: browser.locked ? "Incognito Tab" : (browser.isPrivate ? "Incognito: " : "Tab: ") + tab.title,
                                  site: browser.locked ? nil : tab.site, symbol: "eye.slash",
                                  status: status(of: tab, in: browser), tab: tab.id)
                measured(&row, pid)
                list.append(row)
            }
        }

        for item in Extensions.shared.installed {
            // WebKit SPI: the page running an extension's background script.
            guard let context = Extensions.shared.contexts[item.id],
                  context.responds(to: NSSelectorFromString("_backgroundWebView")),
                  let page = context.value(forKey: "_backgroundWebView") as? WKWebView,
                  let pid = Processes.pid(of: page) else { continue }
            claimed.insert(pid)
            var row = TaskRow(id: item.id, name: "Extension: \(item.name)", symbol: "puzzlepiece.extension")
            measured(&row, pid)
            list.append(row)
        }

        for pid in usage.keys where !claimed.contains(pid) {
            let (name, symbol) = switch Processes.kind(of: pid) {
            case "pages": ("Service Worker or Spare Page", "gearshape")
            case "network": ("Network", "network")
            case "graphics": ("GPU", "cpu")
            case let other: (other, "gearshape")
            }
            var row = TaskRow(id: "pid\(pid)", name: name, symbol: symbol)
            measured(&row, pid)
            list.append(row)
        }

        rows = list
        last = (now, usage)
    }

    private var browsers: [Browser] { NSApp.windows.compactMap { ($0 as? BrowserWindow)?.browser } }

    private func browser(of tab: Tab.ID) -> Browser? {
        browsers.first { $0.tabs.contains { $0.id == tab } }
    }

    private func status(of tab: Tab, in browser: Browser) -> String {
        guard let page = tab.page else { return "Asleep" }
        if page.cameraCaptureState == .active { return "Camera" }
        if page.microphoneCaptureState == .active { return "Microphone" }
        // WebKit SPI, read as the sidebar can't: whether it makes sound now.
        if page.responds(to: NSSelectorFromString("_isPlayingAudio")), page.value(forKey: "_isPlayingAudio") as? Bool == true {
            return "Playing"
        }
        if tab.isLoading { return "Loading" }
        return browser.selectedID == tab.id ? "On Screen" : "Awake"
    }
}

/// Nerda and the WebKit processes working for it (its pages, their network
/// and graphics), found as Activity Monitor finds them: by whom they work
/// for. Nerda must be opened by LaunchServices (`open`), or they work for the
/// terminal it was started from.
enum Processes {
    static func all() -> [(pid: pid_t, usage: rusage_info_v4)] {
        var pids = [pid_t](repeating: 0, count: 8192)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        let me = getpid()
        return pids.prefix(max(count, 0)).compactMap { pid in
            guard pid == me || responsiblePID(pid) == me, let usage = usage(of: pid) else { return nil }
            return (pid, usage)
        }
    }

    static func usage(of pid: pid_t) -> rusage_info_v4? {
        var usage = rusage_info_v4()
        let read = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        return read == 0 ? usage : nil
    }

    /// The process a page runs in; WebKit SPI, nil should it go.
    static func pid(of page: WKWebView) -> pid_t? {
        guard page.responds(to: NSSelectorFromString("_webProcessIdentifier")),
              let pid = (page.value(forKey: "_webProcessIdentifier") as? NSNumber)?.int32Value, pid > 0 else { return nil }
        return pid
    }

    static func kind(of pid: pid_t) -> String {
        var name = [CChar](repeating: 0, count: 256)
        proc_name(pid, &name, UInt32(name.count))
        let process = String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        if process.contains("WebContent") { return "pages" }
        if process.contains("Networking") { return "network" }
        if process.contains("GPU") { return "graphics" }
        return process
    }

    /// CPU time in seconds: rusage counts it in ticks of the Mac's clock, not nanoseconds, on Apple silicon.
    static func seconds(_ ticks: UInt64) -> Double {
        var info = mach_timebase_info()
        mach_timebase_info(&info)
        return Double(ticks) * Double(info.numer) / Double(info.denom) / 1e9
    }
}

/// Who a process works for, as the system counts it for privacy prompts and
/// Activity Monitor: a WebKit process works for the app whose page it runs.
@_silgen_name("responsibility_get_pid_responsible_for_pid")
private func responsiblePID(_ pid: pid_t) -> pid_t
