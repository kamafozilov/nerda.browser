// Adapted from PageEnds.swift in Yab (https://github.com/yetanotherbrowser/yab), Apache License 2.0, Copyright 2026 Serafim Korablev; changed for Nerda.
import Foundation
import WebKit

/// Why WebKit ended a page's process: its private
/// `_WKProcessTerminationReason`, told to
/// `_webView:webContentProcessDidTerminateWithReason:`. The public callback
/// says nothing more than that it ended.
enum PageEnd: Int {
    case memory = 0
    case cpu = 1
    /// Asked for: by Nerda, or by WebKit when it swaps a page's process.
    case requested = 2
    case crash = 3
    /// Too many crashes of a process several sites share.
    case crashLimit = 4

    /// The word logged for it.
    var word: String {
        switch self {
        case .memory: "memory"
        case .cpu: "cpu"
        case .requested: "requested"
        case .crash: "crash"
        case .crashLimit: "crash-limit"
        }
    }

    /// What a page that keeps ending this way says, in place of loading again.
    var again: String {
        switch self {
        case .memory: "The page ran out of memory each time it was opened."
        default: "The page crashed each time it was opened."
        }
    }
}

/// Pages ending, gathered for a tenth of a second. Pages that end together
/// went for something they share (WebKit's GPU or network process, or
/// memory running out for all of them), and none of them is a page that
/// keeps crashing. One page alone, three times in a minute, is.
final class PageEnds {
    struct Ended {
        weak var tab: Tab?
        let id: Tab.ID
        let reason: PageEnd?
        /// It had something typed into it, which went with the process: it
        /// says so at once, and is not loaded again.
        let edited: Bool
    }

    static let together: TimeInterval = 0.1
    static let window: TimeInterval = 60
    static let limit = 3

    /// Hears, once the moment is over, every page that ended in it, each with
    /// whether it now keeps ending.
    var heard: (([(end: Ended, again: Bool)]) -> Void)?
    private var pending: [Ended] = []
    private var ends: [Tab.ID: [TimeInterval]] = [:]
    private let clock: () -> TimeInterval

    init(clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.clock = clock
    }

    /// Ends heard whose tenth of a second is not over yet.
    var gathering: Bool { !pending.isEmpty }

    /// A page's process ended. Heard twice in the moment (both of WebKit's
    /// callbacks), it is one end, with the reason if either gave one.
    func ended(_ end: Ended) {
        if let index = pending.firstIndex(where: { $0.id == end.id }) {
            if pending[index].reason == nil { pending[index] = end }
            return
        }
        pending.append(end)
        guard pending.count == 1 else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.together))
            guard let self else { return }
            let batch = pending
            pending = []
            heard?(settle(batch))
        }
    }

    /// Which of the pages that ended together keep ending. Asked for is never
    /// counted, nor anything that ended in company.
    private func settle(_ batch: [Ended]) -> [(end: Ended, again: Bool)] {
        let now = clock()
        let alone = batch.count == 1
        return batch.map { end in
            guard alone, end.reason != .requested else { return (end: end, again: false) }
            let recent = (ends[end.id] ?? []).filter { now - $0 < Self.window } + [now]
            ends[end.id] = recent
            return (end: end, again: recent.count >= Self.limit)
        }
    }
}

extension Browser {
    /// WebKit's private word that a page's process ended, with why. Where it
    /// is answered, WebKit calls it in place of the public one.
    @objc(_webView:webContentProcessDidTerminateWithReason:)
    func webView(_ webView: WKWebView, processEndedFor reason: Int) {
        pageEnded(webView, reason: PageEnd(rawValue: reason) ?? .crash)
    }
}
