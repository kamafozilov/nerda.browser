// Adapted from Deaf.swift, Stuck.swift and WebKitProcesses.swift in Yab (https://github.com/yetanotherbrowser/yab), Apache License 2.0, Copyright 2026 Serafim Korablev; changed for Nerda.

import SwiftUI
import WebKit
import os

// A page that stops answering.
//
// A page's script can go round a loop it never leaves. Its process then takes
// nothing in: not a click, not a key, not ⌘R, which WebKit hands to that very
// process, nor the polite request to end that closing its view sends. One site
// would hold the tab, and look like Nerda frozen.
//
// WebKit notices first: an input or a load the page's process hasn't taken in
// three seconds makes it call `_webViewWebProcessDidBecomeUnresponsive`, and
// `…DidBecomeResponsive` once it takes them again. That alone can be a page
// busy for a moment, so the page is then asked something that takes it no
// time (`ping`); two asks in a row unanswered, it has hung.
//
// Fifteen seconds after the owner reached for it, twelve after WebKit's word,
// a hung page on screen asks "This page isn't answering": Wait, or Reload.
// Wait leaves it; reaching for it again after thirty seconds asks again. If
// it answers by itself, the card goes, saying nothing.
//
// The card is never the only way out. Reload, closing the tab, an address
// typed, Back or Forward, and putting it to sleep each end its process first
// (`Tab.letGoHung`), by force, and the tab goes on in a fresh page at once:
// WebKit's own `_killWebContentProcess` was seen to leave such a process
// running on macOS 27, so a second later it is killed by its pid.
//
// Out of sight nothing reaches for a page, and WebKit says nothing of a
// hidden one stuck in a loop while it holds a core for hours. So once a
// minute Nerda reads how much CPU each page out of sight has taken, a
// syscall that wakes no page (`lookForSpinningPages`). One that kept a
// quarter of a core busy is pinged; a page working on purpose (an export, a
// build) answers. Two pings unanswered, it is ended and put to sleep, and
// loads again when next shown, unless it holds something typed or plays
// sound: that one is asked about when the owner comes back to it.
//
// NERDA_HANG_HANDLING=0 turns all of it off for a run (Speedups).

/// What Nerda knows of a tab's page having stopped answering.
struct Hang {
    /// When WebKit said the page stopped taking input, until it says it takes it again.
    var reported: Date?
    /// Two pings in a row went unanswered.
    var hung = false
    /// Pings unanswered so far in this round, and whether one is out.
    var missed = 0
    var pinging = false
    /// The page's process and its CPU time at the last look, for a page out of sight.
    var cpu: (pid: pid_t, at: Date, seconds: Double)?
    /// Wait was chosen: not asked again before this.
    var quietUntil: Date?
}

enum HungPages {
    static var isOn: Bool { Speedups.isOn("HANG_HANDLING") }
    /// How long a page has to answer a ping.
    static var patience: TimeInterval = 2
    /// From WebKit's word (itself three seconds after the reach) to the card.
    static var askAfter: TimeInterval = 12
    /// How long Wait keeps the card away.
    static let quiet: TimeInterval = 30
    /// How often pages out of sight are looked at, and the share of a core
    /// over that time that has a page pinged.
    static let lookEvery: TimeInterval = 60
    static let spinning = 0.25

    private static var watch: Timer?

    /// Once, at launch: every window's pages out of sight, looked at each minute.
    static func start() {
        guard watch == nil else { return }
        let timer = Timer(timeInterval: lookEvery, repeats: true) { _ in
            MainActor.assumeIsolated {
                for case let window as BrowserWindow in NSApp.windows { window.browser.lookForSpinningPages() }
            }
        }
        timer.tolerance = lookEvery / 4
        RunLoop.main.add(timer, forMode: .common)
        watch = timer
    }
}

extension Browser {
    @objc(_webViewWebProcessDidBecomeUnresponsive:)
    func webProcessDidBecomeUnresponsive(_ webView: WKWebView) {
        guard HungPages.isOn, let tab = tab(for: webView) else { return }
        if tab.hang.reported == nil {
            tab.hang.reported = .now
            Logger.pages.notice("A page stopped taking input")
        }
        ping(tab)
        let due = HungPages.askAfter
        Task { [weak self, weak tab] in
            try? await Task.sleep(for: .seconds(due))
            guard let self, let tab else { return }
            decide(tab)
        }
    }

    @objc(_webViewWebProcessDidBecomeResponsive:)
    func webProcessDidBecomeResponsive(_ webView: WKWebView) {
        guard let tab = tab(for: webView) else { return }
        tab.answered()
    }

    /// Asks the page something that takes it no time, unless its main thread
    /// is held. Unanswered in `patience`, asked again; twice, it has hung.
    func ping(_ tab: Tab) {
        guard !tab.hang.pinging, let page = tab.page else { return }
        tab.hang.pinging = true
        var answered = false
        page.evaluateJavaScript("1", in: nil, in: .defaultClient) { [weak tab] result in
            // An answer that comes as the process ends is no answer.
            guard case .success = result else { return }
            answered = true
            tab?.answered()
        }
        let patience = HungPages.patience
        Task { [weak self, weak tab, weak page] in
            try? await Task.sleep(for: .seconds(patience))
            guard let self, let tab, !answered, let page, tab.page === page else { return }
            tab.hang.pinging = false
            tab.hang.missed += 1
            if tab.hang.missed < 2 { return ping(tab) }
            if !tab.hang.hung { Logger.pages.notice("A page stopped answering") }
            tab.hang.hung = true
            decide(tab)
        }
    }

    /// A page known hung: asked about on screen, once the owner has had time
    /// to see it isn't answering; out of sight, ended and put to sleep, or,
    /// holding something typed or playing sound, asked about when shown.
    func decide(_ tab: Tab) {
        guard tab.hang.hung, tabs.contains(where: { $0 === tab }) else { return }
        guard tab.id == selectedID else {
            if tab.hasUnsavedWork || tab.playsAudio { tab.asksAboutHang = true } else { tab.letGoHung() }
            return
        }
        let due = (tab.hang.reported ?? .distantPast).addingTimeInterval(HungPages.askAfter)
        guard Date.now >= due, Date.now >= tab.hang.quietUntil ?? .distantPast else { return }
        tab.asksAboutHang = true
    }

    /// One look at the pages out of sight: one that kept a quarter of a core
    /// busy since the last look is pinged.
    func lookForSpinningPages() {
        guard HungPages.isOn else { return }
        let now = Date.now
        for tab in tabs where tab.id != selectedID {
            guard let pid = tab.pid, let usage = Processes.usage(of: pid) else {
                tab.hang.cpu = nil
                continue
            }
            let seconds = Processes.seconds(usage.ri_user_time + usage.ri_system_time)
            defer { tab.hang.cpu = (pid, now, seconds) }
            guard let last = tab.hang.cpu, last.pid == pid, now > last.at,
                  (seconds - last.seconds) / now.timeIntervalSince(last.at) >= HungPages.spinning else { continue }
            ping(tab)
        }
    }

    /// A click or a key in a page known hung: asked about again, unless Wait
    /// was chosen a moment ago.
    func reached(_ webView: WKWebView) {
        guard let tab = tab(for: webView), tab.hang.hung else { return }
        decide(tab)
    }
}

extension Tab {
    /// Two pings in a row went unanswered since WebKit said the page stopped
    /// taking input, or since it was seen spinning out of sight.
    var isHung: Bool { hang.hung }

    /// It answers again: nothing is said, and the card goes.
    func answered() {
        hang = Hang(cpu: hang.cpu)
        asksAboutHang = false
    }

    /// Wait: the card goes, and comes back only if the owner reaches for the
    /// page again after a while.
    func waitForHang() {
        asksAboutHang = false
        hang.quietUntil = .now.addingTimeInterval(HungPages.quiet)
    }

    /// A page that stopped answering ends here, its process with it, by force:
    /// it would never read the request to end that closing its view sends. The
    /// tab is left asleep, its history kept, so whatever comes next (a reload,
    /// an address, Back) wakes a fresh page at once. Other tabs whose pages
    /// shared the process were held by the same loop, and come back as after
    /// any end that isn't a crash (`endingOnPurpose`). False, and nothing
    /// done, for a page WebKit hasn't said has stopped answering.
    @discardableResult
    func letGoHung() -> Bool {
        guard hang.reported != nil || hang.hung, let page else { return false }
        let pid = self.pid
        Logger.pages.notice("A page that stopped answering was ended")
        hang = Hang()
        asksAboutHang = false
        if let pid, let browser = delegate as? Browser {
            for other in browser.tabs where other !== self && other.pid == pid { other.endingOnPurpose = true }
        }
        sleep(discarding: true)
        page.endProcess()
        return true
    }
}

extension WKWebView {
    /// The page's process ended, as Activity Monitor's Force Quit would.
    /// WebKit is asked first, so it knows the process went; a process stuck in
    /// a loop may never hear that, so a second later it is killed by its pid,
    /// if that is still the same process and not another that took its number.
    // WebKit SPI: should `_killWebContentProcess` go, the kill alone ends it.
    func endProcess() {
        guard let pid = Processes.pid(of: self) else { return }
        let born = Processes.started(pid)
        let kill = NSSelectorFromString("_killWebContentProcess")
        if responds(to: kill) { perform(kill) }
        guard let born else { return }
        Task {
            try? await Task.sleep(for: .seconds(1))
            if Processes.started(pid) == born { Darwin.kill(pid, SIGKILL) }
        }
    }
}

/// Over a page that stopped answering, once the owner reached for it: Wait,
/// or Reload, as Chrome's "Page Unresponsive" asks.
struct HungPageCard: View {
    let tab: Tab

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                SiteIcon(host: tab.url?.host() ?? "", size: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text("This page isn't answering")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                    Text("Wait for it, or reload it to start it again.")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.muted)
                }
                .lineLimit(1)
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                Spacer(minLength: 12)
                PromptButton(title: "Wait", action: tab.waitForHang)
                PromptButton(title: "Reload", prominent: true) { tab.reload() }
                    .help("Reload  ⌘R")
            }
        }
        .padding(16)
        .frame(width: 380)
        .glassPanel(cornerRadius: 18)
    }
}
