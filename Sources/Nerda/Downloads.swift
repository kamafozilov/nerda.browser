import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// A file on its way to ~/Downloads, and how far along it is.
@Observable
final class Download: Identifiable {
    enum State { case running, finished, failed, cancelled }

    let id = UUID()
    let started = Date.now
    @ObservationIgnored let task: WKDownload
    /// Where it is being saved; nil until WebKit asks.
    var file: URL?
    private(set) var state = State.running
    private(set) var received: Int64 = 0
    /// Negative while the server hasn't said.
    private(set) var total: Int64 = -1
    @ObservationIgnored private var observation: NSKeyValueObservation?

    var name: String {
        file?.lastPathComponent ?? task.originalRequest?.url?.lastPathComponent ?? "Download"
    }

    /// nil when the size isn't known, which shows as a moving bar instead.
    var fraction: Double? {
        total > 0 ? min(Double(received) / Double(total), 1) : nil
    }

    init(_ task: WKDownload) {
        self.task = task
        observation = task.progress.observe(\.completedUnitCount) { [weak self] progress, _ in
            let received = progress.completedUnitCount, total = progress.totalUnitCount
            Task { @MainActor in self?.update(received: received, total: total) }
        }
    }

    /// Every chunk reports in; what is drawn only needs to move every half percent.
    private func update(received: Int64, total: Int64) {
        let step = total > 0 ? total / 200 : 256 * 1024
        guard state == .running,
              total != self.total || received - self.received >= step || received == total else { return }
        self.received = received
        self.total = total
    }

    func finish() {
        state = .finished
        if total < received { total = received }
        received = total
    }

    func fail() {
        if state == .running { state = .failed }
    }

    /// Stops it and takes away the part already saved.
    func cancel() {
        state = .cancelled
        let file = file
        task.cancel { _ in
            if let file { try? FileManager.default.removeItem(at: file) }
        }
    }
}

nonisolated enum Downloads {
    /// `name` in `folder`, as "name (1).ext", "name (2).ext"… when taken.
    /// Only the last path component: a site's name can't reach other folders.
    static func destination(for name: String, in folder: URL) -> URL {
        var name = (name as NSString).lastPathComponent
        if name.isEmpty || name == "." || name == ".." { name = "download" }
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        var candidate = folder.appending(path: name)
        var number = 1
        while FileManager.default.fileExists(atPath: candidate.path(percentEncoded: false)) {
            candidate = folder.appending(path: ext.isEmpty ? "\(base) (\(number))" : "\(base) (\(number)).\(ext)")
            number += 1
        }
        return candidate
    }
}

/// The sidebar's corner button for this session's downloads. A download
/// starting flies into it from the pointer, as in Safari; while any are
/// running a ring round it fills with their progress; it bounces as one lands.
struct DownloadsButton: View {
    let browser: Browser
    @Binding var shown: Bool
    /// Where its list opens: above it, in the sidebar's bottom corner, or
    /// below it, at the window's top.
    var arrowEdge = Edge.top

    @State private var hovering = false
    /// Where the button is in the window, for a download to fly into.
    @State private var frame = CGRect.zero
    @State private var flight: Flight?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let running = browser.downloads.filter { $0.state == .running }
        let finished = browser.downloads.count { $0.state == .finished }

        Button { shown.toggle() } label: {
            Image(systemName: running.isEmpty ? "arrow.down.circle" : "arrow.down")
                .font(.system(size: running.isEmpty ? 16 : 10, weight: running.isEmpty ? .medium : .semibold))
                .foregroundStyle(hovering || shown ? Palette.ink : Palette.muted)
                .symbolEffect(.bounce, value: finished)
                .frame(width: 28, height: 28)
                .overlay {
                    if !running.isEmpty { ProgressRing(fraction: Self.progress(of: running)) }
                }
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(hovering || shown ? Palette.hover : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Downloads")
        .accessibilityLabel("Downloads")
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.14), value: hovering)
        .popover(isPresented: $shown, arrowEdge: arrowEdge) {
            DownloadsList(browser: browser)
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
        .overlay {
            if let flight { FlyingFile(flight: flight) { self.flight = nil }.id(flight.id) }
        }
        // Downloads are only ever added at the top.
        .onChange(of: browser.downloads.count) { old, new in
            guard new > old, !reduceMotion, let download = browser.downloads.first else { return }
            flight = Flight(name: download.name, from: Self.pointer(from: frame))
        }
    }

    /// The pointer, which has just clicked the link, from the button's middle;
    /// the window's middle when it is elsewhere (a download from the keyboard).
    private static func pointer(from frame: CGRect) -> CGSize {
        guard let window = NSApp.keyWindow, let content = window.contentView else { return .zero }
        let bounds = content.bounds
        var point = window.mouseLocationOutsideOfEventStream
        if !bounds.contains(point) { point = CGPoint(x: bounds.midX, y: bounds.midY) }
        // AppKit counts up from the bottom, SwiftUI down from the top.
        return CGSize(width: point.x - frame.midX, height: bounds.height - point.y - frame.midY)
    }

    /// All running downloads as one: bytes in over bytes expected, where known.
    private static func progress(of running: [Download]) -> Double? {
        let sized = running.filter { $0.total > 0 }
        let total = sized.reduce(0) { $0 + $1.total }
        guard total > 0 else { return nil }
        return Double(sized.reduce(0) { $0 + $1.received }) / Double(total)
    }
}

private struct Flight {
    let id = UUID()
    let name: String
    /// Where it sets off, from the button's middle.
    let from: CGSize
}

/// The file's icon, falling in an arc from where the download started into
/// the button, shrinking as it goes.
private struct FlyingFile: View {
    let flight: Flight
    let landed: () -> Void

    @State private var across = false
    @State private var down = false

    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(for: UTType(filenameExtension: (flight.name as NSString).pathExtension) ?? .data))
            .resizable()
            .frame(width: 48, height: 48)
            .scaleEffect(down ? 0.3 : 1)
            .opacity(down ? 0.4 : 1)
            // Steady across, gathering speed downward: an arc, as if thrown.
            .offset(x: across ? 0 : flight.from.width)
            .offset(y: down ? 0 : flight.from.height)
            .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
            .allowsHitTesting(false)
            .onAppear {
                withAnimation(.easeOut(duration: 0.6)) { across = true }
                withAnimation(.easeIn(duration: 0.6)) { down = true } completion: { landed() }
            }
    }
}

/// Filled as far as `fraction`; a short arc going round while it isn't known.
private struct ProgressRing: View {
    let fraction: Double?

    var body: some View {
        ZStack {
            Circle().stroke(Palette.muted.opacity(0.3), lineWidth: 2)
            if let fraction {
                Circle()
                    .trim(from: 0, to: max(fraction, 0.02))
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.2), value: fraction)
            } else {
                TurningArc()
            }
        }
        .frame(width: 20, height: 20)
    }
}

/// A quarter of the ring going round once a second. Core Animation turns it,
/// outside the app: SwiftUI turning it (a TimelineView) redrew it on the main
/// thread every frame for as long as the download ran.
private struct TurningArc: NSViewRepresentable {
    func makeNSView(context: Context) -> ArcView { ArcView() }
    func updateNSView(_ view: ArcView, context: Context) {}

    final class ArcView: NSView {
        private let arc = CAShapeLayer()

        init() {
            super.init(frame: .zero)
            wantsLayer = true
            arc.fillColor = nil
            arc.lineWidth = 2
            arc.lineCap = .round
            arc.strokeEnd = 0.25
            layer?.addSublayer(arc)
            setAccessibilityElement(false)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func layout() {
            super.layout()
            arc.frame = bounds
            arc.path = CGPath(ellipseIn: bounds, transform: nil)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            viewDidChangeEffectiveAppearance()
            guard window != nil, arc.animation(forKey: "turn") == nil else { return }
            let turn = CABasicAnimation(keyPath: "transform.rotation.z")
            // Clockwise: AppKit's layers count angles up from the bottom.
            turn.toValue = -2 * Double.pi
            turn.duration = 1
            turn.repeatCount = .infinity
            turn.isRemovedOnCompletion = false
            arc.add(turn, forKey: "turn")
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            effectiveAppearance.performAsCurrentDrawingAppearance { arc.strokeColor = NSColor.controlAccentColor.cgColor }
        }

        // Clicks go to the button under it.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// This session's downloads: under the corner button, and beside the sidebar menu's Downloads.
struct DownloadsList: View {
    let browser: Browser

    /// Rows beyond this many scroll, so the popover stays within reach.
    private static let visibleRows = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if browser.downloads.isEmpty {
                Text("No downloads for this session.")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 18)
            } else if browser.downloads.count > Self.visibleRows {
                ScrollView { rows }.frame(height: CGFloat(Self.visibleRows) * DownloadRow.height + 12)
            } else {
                rows
            }

            Divider().padding(.horizontal, 12)

            HStack {
                FooterButton(title: "Show All Downloads") {
                    NSWorkspace.shared.open(.downloadsDirectory)
                }
                Spacer()
                if browser.downloads.contains(where: { $0.state != .running }) {
                    FooterButton(title: "Clear") {
                        withAnimation(.easeOut(duration: 0.2)) { browser.clearDownloads() }
                    }
                }
            }
            .padding(6)
        }
        .frame(width: 340)
    }

    private var rows: some View {
        VStack(spacing: 2) {
            ForEach(browser.downloads) { DownloadRow(download: $0) }
        }
        .padding(6)
    }
}

private struct DownloadRow: View {
    let download: Download

    static let height: CGFloat = 52

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(for: fileType))
                .resizable()
                .frame(width: 32, height: 32)
                .opacity(download.state == .finished || download.state == .running ? 1 : 0.5)

            VStack(alignment: .leading, spacing: 3) {
                Text(download.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if download.state == .running {
                    ProgressView(value: download.fraction)
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Spacer(minLength: 0)

            switch download.state {
            case .running:
                RowButton(symbol: "xmark.circle.fill", label: "Cancel", action: download.cancel)
            case .finished:
                RowButton(symbol: "magnifyingglass.circle.fill", label: "Show in Finder") {
                    if let file = download.file { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                }
            case .failed, .cancelled:
                EmptyView()
            }
        }
        .padding(.horizontal, 10)
        .frame(height: Self.height)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(hovering ? Palette.hover : .clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        // Opens the file, as a double-click on it anywhere else does.
        .onTapGesture(count: 2) {
            if download.state == .finished, let file = download.file { NSWorkspace.shared.open(file) }
        }
    }

    private var fileType: UTType {
        UTType(filenameExtension: (download.name as NSString).pathExtension) ?? .data
    }

    private var detail: String {
        let received = download.received.formatted(.byteCount(style: .file))
        switch download.state {
        case .running:
            guard download.total > 0 else { return received }
            return "\(received) of \(download.total.formatted(.byteCount(style: .file)))"
        case .finished: return received
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        }
    }
}

private struct RowButton: View {
    let symbol: String
    let label: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16))
                .foregroundStyle(hovering ? Palette.ink : Palette.muted)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .onHover { hovering = $0 }
    }
}

private struct FooterButton: View {
    let title: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(hovering ? Palette.hover : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
