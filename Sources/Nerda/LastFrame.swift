// Adapted from PageStills.swift and Stage.swift in Yab (https://github.com/yetanotherbrowser/yab), Apache License 2.0, Copyright 2026 Serafim Korablev; changed for Nerda.
import AppKit
import CoreVideo
import IOSurface
import WebKit

/// A page's last frame, kept when its tab goes out of sight, so that
/// switching back shows that page at once, in the frame the switch is drawn
/// in, until WebKit has drawn the live page over it. Until then a page coming
/// back can show nothing: WebKit lets a hidden page's drawing go, and a busy
/// page takes a while to draw again.
///
/// Pictured by the page's own process (`takeSnapshot`) as it leaves the
/// screen, drawn off the main thread into an IOSurface the window server
/// shows without a copy, and kept in memory only, never on disk. Used only
/// while everything it was drawn for still holds (`Key`): the same address,
/// size, scale, zoom, appearance and scroll. Otherwise the page comes in as
/// before. Separate from the hover card's picture (`Tab.snapshot`), which is
/// the page's top at the card's size, kept while the tab sleeps; a last
/// frame goes with its page. `NERDA_LAST_FRAME=0` turns it off for a run.
/// Each `PageSlot` has one.
final class LastFrame {
    static var isOn: Bool { Speedups.isOn(.lastFrame) }

    /// What a frame was drawn for. It stands in only for exactly this.
    struct Key: Equatable {
        var url: URL?
        /// Points: the page's own size.
        var size: CGSize
        var scale: CGFloat
        var zoom: CGFloat
        var magnification: CGFloat
        var dark: Bool

        /// Why a frame drawn for `self` can't stand in for the page now at
        /// `now`, or nil when it can. Scroll is asked of the page (`arrive`).
        func refusal(for now: Key) -> String? {
            if url != now.url { return "address" }
            if abs(size.width - now.size.width) > 0.5 || abs(size.height - now.size.height) > 0.5 { return "size" }
            if scale != now.scale { return "scale" }
            if abs(zoom - now.zoom) > 0.001 || abs(magnification - now.magnification) > 0.001 { return "zoom" }
            if dark != now.dark { return "appearance" }
            return nil
        }
    }

    /// What the page showed the last time it came on screen: its last frame,
    /// or the live page, and why. Nil while it is out of sight.
    enum Arrival: Equatable {
        case lastFrame
        case live(because: String)
    }

    private(set) var arrival: Arrival?
    /// The frame, and where the page was scrolled to when it was drawn.
    private var kept: (key: Key, scroll: [Double], surface: IOSurface, drawn: CFTimeInterval)?
    /// Showing the frame, over the page.
    private var view: FrameView?
    private var onScreen = false
    /// Bumped on every arrival and departure: answers that come back after
    /// are for a moment gone.
    private var turn = 0
    private var asking = false

    var keeps: Bool { kept != nil }
    var shows: Bool { view?.isHidden == false }
    fileprivate var bytes: Int { kept?.surface.allocationSize ?? 0 }

    /// The page goes out of sight: its frame is taken, unless one taken a
    /// moment ago still holds, so going back and forth between two tabs
    /// pictures each once.
    func leave(_ page: WKWebView, on stage: PageStage) {
        guard onScreen else { return }
        onScreen = false
        arrival = nil
        lift()
        guard Self.isOn, stage.device == nil, let key = Self.key(page) else {
            drop()
            return
        }
        if let kept, kept.key.refusal(for: key) == nil, CACurrentMediaTime() - kept.drawn < 2 { return }
        take(page, key: key)
    }

    /// The page comes on screen in `slot`, its last frame over it if it would
    /// look the same, until WebKit has drawn it.
    func arrive(_ page: WKWebView, on stage: PageStage, in slot: NSView) {
        onScreen = true
        turn += 1
        guard Self.isOn else {
            arrival = .live(because: "off")
            drop()
            return
        }
        guard let kept else {
            arrival = .live(because: "none")
            return
        }
        guard stage.device == nil, let key = Self.key(page) else {
            arrival = .live(because: "size")
            drop()
            return
        }
        if let why = kept.key.refusal(for: key) {
            arrival = .live(because: why)
            drop()
            return
        }
        let view = view ?? FrameView()
        self.view = view
        if view.superview !== slot { slot.addSubview(view, positioned: .above, relativeTo: stage) }
        view.frame = slot.convert(page.bounds, from: page)
        view.surface = kept.surface
        view.isHidden = false
        arrival = .lastFrame
        Self.used(self)
        let turn = turn
        // The page drew: it takes its place. A page that never does is
        // shown as WebKit has it after two seconds.
        Self.afterNextDrawing(page) { [weak self] in
            if self?.turn == turn { self?.lift() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            if self?.turn == turn { self?.lift() }
        }
        // A page can scroll itself while out of sight, which nothing tells
        // until it is asked: the frame goes once it says, if WebKit hasn't
        // drawn the page already, and isn't used again.
        Task { [weak self, weak page] in
            guard let page else { return }
            let scroll = await Self.scroll(of: page)
            guard let self, self.turn == turn, scroll != kept.scroll else { return }
            self.arrival = .live(because: "scroll")
            self.lift()
            self.drop()
        }
    }

    /// The frame down, the live page shown.
    private func lift() {
        guard let view, !view.isHidden else { return }
        view.isHidden = true
        view.surface = nil
    }

    fileprivate func drop() {
        kept = nil
        lift()
    }

    private func take(_ page: WKWebView, key: Key) {
        guard !asking else { return }
        asking = true
        let turn = turn
        let configuration = WKSnapshotConfiguration()
        // What it shows now: a page out of sight draws no more.
        configuration.afterScreenUpdates = false
        Task { [weak self, weak page] in
            defer { self?.asking = false }
            guard let page else { return }
            let scroll = await Self.scroll(of: page)
            let image = try? await page.takeSnapshot(configuration: configuration)
            // WebKit's own bitmap, never drawn again here.
            guard let scroll, let picture = image?.representations.first?.cgImage(forProposedRect: nil, context: nil, hints: nil)
            else { return }
            let pixels = CGSize(width: (key.size.width * key.scale).rounded(), height: (key.size.height * key.scale).rounded())
            guard let surface = await Self.surface(from: picture, pixels: pixels), let self, self.turn == turn,
                  !self.onScreen else { return }
            self.kept = (key, scroll, surface, CACurrentMediaTime())
            Self.used(self)
        }
    }

    // MARK: - What the page is now

    /// Nil for a page out of a window.
    private static func key(_ page: WKWebView) -> Key? {
        guard let window = page.window, page.bounds.width >= 32, page.bounds.height >= 32 else { return nil }
        return Key(url: page.url, size: page.bounds.size, scale: window.backingScaleFactor,
                   zoom: page.pageZoom, magnification: page.magnification,
                   dark: page.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
    }

    /// Where the page is scrolled to, or nil if it can't say.
    private static func scroll(of page: WKWebView) async -> [Double]? {
        let answer = try? await page.callAsyncJavaScript("return [scrollX, scrollY]", contentWorld: .defaultClient)
        return (answer as? [NSNumber])?.map { $0.doubleValue.rounded() }
    }

    /// `done` once WebKit has put on screen what it draws next. WebKit SPI,
    /// as Safari's tests use it: should it go, a one-point picture drawn
    /// after the screen's next update tells the same.
    private static func afterNextDrawing(_ page: WKWebView, _ done: @escaping @MainActor () -> Void) {
        let name = NSSelectorFromString("_doAfterNextPresentationUpdate:")
        guard page.responds(to: name) else {
            let configuration = WKSnapshotConfiguration()
            configuration.afterScreenUpdates = true
            configuration.snapshotWidth = 1
            page.takeSnapshot(with: configuration) { _, _ in done() }
            return
        }
        let block: @convention(block) () -> Void = { MainActor.assumeIsolated { done() } }
        page.perform(name, with: block)
    }

    // MARK: - How many are kept

    private final class Entry {
        weak var frame: LastFrame?
        init(_ frame: LastFrame) { self.frame = frame }
    }

    /// Least recently used first.
    private static var entries: [Entry] = []
    private static var pressure: DispatchSourceMemoryPressure?

    /// How many bytes of frames are kept at most: a share of the Mac's
    /// memory, between 48 and 256 MB. A whole frame of a page on a Retina
    /// screen is 16 to 30 MB.
    static let budget = budget(memory: ProcessInfo.processInfo.physicalMemory)

    nonisolated static func budget(memory: UInt64) -> Int {
        Int(min(256 << 20, max(48 << 20, memory / 96)))
    }

    /// `frame` kept or shown just now: the ones used longest ago go first,
    /// past the budget, never one on screen.
    private static func used(_ frame: LastFrame) {
        entries.removeAll { $0.frame == nil || $0.frame === frame }
        entries.append(Entry(frame))
        var bytes = entries.reduce(0) { $0 + ($1.frame?.bytes ?? 0) }
        for entry in entries where bytes > budget {
            guard let old = entry.frame, old !== frame, !old.shows else { continue }
            bytes -= old.bytes
            old.drop()
        }
        entries.removeAll { $0.frame?.keeps != true }
        // Memory short: every frame out of sight goes.
        if pressure == nil {
            let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
            source.setEventHandler {
                MainActor.assumeIsolated {
                    for entry in entries where entry.frame?.shows == false { entry.frame?.drop() }
                    entries.removeAll { $0.frame?.keeps != true }
                }
            }
            source.resume()
            pressure = source
        }
    }

    // MARK: - Drawing one

    /// WebKit's picture, at the size asked for, drawn into a surface the
    /// window server shows as it is.
    @concurrent
    private static func surface(from picture: CGImage, pixels: CGSize) async -> IOSurface? {
        let width = Int(pixels.width), height = Int(pixels.height)
        guard width > 0, height > 0 else { return nil }
        let row = IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, width * 4)
        guard let surface = IOSurface(properties: [
            .width: width, .height: height, .bytesPerElement: 4, .bytesPerRow: row,
            .allocSize: row * height, .pixelFormat: kCVPixelFormatType_32BGRA,
        ]) else { return nil }
        // WebKit hands back its pictures in extended range, half floats;
        // drawn into 8 bits here, in the screen's colors.
        let space: CGColorSpace = if let space = picture.colorSpace, space.model == .rgb, !CGColorSpaceUsesExtendedRange(space),
                                     space.name != CGColorSpace.linearSRGB, space.name != CGColorSpace.extendedLinearSRGB {
            space
        } else {
            CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
        }
        _ = surface.lock(options: [], seed: nil)
        defer { _ = surface.unlock(options: [], seed: nil) }
        guard let context = CGContext(
            data: surface.baseAddress, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: surface.bytesPerRow, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        // Opaque: a page with no ground of its own is white.
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(rect)
        context.interpolationQuality = .medium
        context.draw(picture, in: rect)
        // Tagged, so the window server shows it in the colors it was drawn in.
        if let list = space.copyPropertyList() { IOSurfaceSetValue(surface, "IOSurfaceColorSpace" as CFString, list) }
        return surface
    }
}

/// The frame over the page: takes no clicks, and is read by nothing.
private final class FrameView: NSView {
    var surface: IOSurface? {
        didSet { layer?.contents = surface }
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        layer?.contentsGravity = .resize
        layer?.isOpaque = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.contents = surface }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

extension WKWebView {
    /// The page's last frame is kept, to show when its tab comes back.
    var keepsLastFrame: Bool { (superview?.superview as? PageSlot)?.lastFrame.keeps ?? false }
    /// Its last frame stands in for it now.
    var showsLastFrame: Bool { (superview?.superview as? PageSlot)?.lastFrame.shows ?? false }
    /// What it showed the last time it came on screen; nil out of sight.
    var lastArrival: LastFrame.Arrival? { (superview?.superview as? PageSlot)?.lastFrame.arrival }
}
