import AppKit
import CoreImage
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Which picture a new tab shows (see Backdrop).
nonisolated enum Wallpaper: Hashable, Sendable {
    /// Nerda's own in turn, a new one each day and the same all day.
    case daily
    /// One of Nerda's own, by its file's name.
    case own(String)
    /// One of yours, by the name of its copy in `Backdrop.folder`.
    case chosen(String)

    /// As kept in the defaults: "daily", or "own:" or "chosen:" and the name.
    /// "chosen" alone is from when there was only one of yours.
    init?(saved: String) {
        switch saved {
        case "daily": self = .daily
        case "chosen": self = .chosen(Backdrop.legacy.lastPathComponent)
        case _ where saved.hasPrefix("own:"): self = .own(String(saved.dropFirst(4)))
        case _ where saved.hasPrefix("chosen:"): self = .chosen(String(saved.dropFirst(7)))
        default: return nil
        }
    }

    var saved: String {
        switch self {
        case .daily: "daily"
        case .chosen(let name): "chosen:" + name
        case .own(let name): "own:" + name
        }
    }
}

/// The picture behind a new tab's field: Nerda's own (photos of Japan's
/// nature, assets/backgrounds) in turn, one of them, or one of yours,
/// picked under the page (WallpaperPicker) or from View. Decoded once, off
/// the main thread, and shared by every new tab; let go a few minutes after
/// the last new tab is left, as it takes 20 to 100 MB.
@Observable
final class Backdrop {
    static let shared = Backdrop()

    /// The picture, decoded for this Mac's screens, once it is ready.
    private(set) var image: CGImage?
    /// The file `image` is, or is being made from.
    @ObservationIgnored private var shown: URL?
    /// How many new tabs show `image` now (`BackdropView`).
    @ObservationIgnored var showing = 0 {
        didSet { if showing == 0 { releaseLater() } }
    }
    @ObservationIgnored private var releasing: Task<Void, Never>?
    @ObservationIgnored private var memoryPressure: (any DispatchSourceMemoryPressure)?

    /// Your pictures, oldest first.
    private(set) var chosen: [URL]

    /// Kept across launches. Before there was a choice, a chosen picture
    /// stood in for Nerda's own: it still does.
    var wallpaper: Wallpaper {
        didSet {
            UserDefaults.standard.set(wallpaper.saved, forKey: "newTabWallpaper")
            // Picked in Settings or from View, it waits for the next new tab.
            if showing > 0 { load() }
        }
    }

    /// Small copies for the picker, by file, made as it opens.
    private(set) var thumbnails: [URL: CGImage] = [:]
    @ObservationIgnored private var thumbnailsAsked: Set<URL> = []

    /// Your pictures, each a copy, so the original can be moved or deleted.
    nonisolated static let folder = Edition.folder.appending(path: "Wallpapers")
    /// Where the one picture of yours was kept, before there could be more.
    nonisolated static let legacy = Edition.folder.appending(path: "new-tab-picture.heic")
    /// A copy is kept no bigger than the largest Mac screen, 6K: sharp on
    /// any of them, without keeping a camera's whole picture.
    nonisolated static let side = 6144

    static let own = (Bundle.main.urls(forResourcesWithExtension: "heic", subdirectory: "Backgrounds") ?? [])
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

    private init() {
        let kept = Self.kept()
        chosen = kept
        wallpaper = UserDefaults.standard.string(forKey: "newTabWallpaper").flatMap(Wallpaper.init(saved:))
            ?? kept.first.map { .chosen($0.lastPathComponent) } ?? .daily
        // Short of memory, the picture is let go while no new tab shows it:
        // decoded, it takes 20 MB, up to 100 MB for one of yours on a 6K
        // screen. The next new tab decodes it again.
        memoryPressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        memoryPressure?.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.release() }
        }
        memoryPressure?.activate()
    }

    private func release() {
        guard showing == 0, image != nil else { return }
        image = nil
        shown = nil
        composites = []
    }

    /// A page's size in pixels, and its points' scale.
    nonisolated struct Canvas: Hashable, Sendable {
        let width: Int
        let height: Int
        let scale: CGFloat

        init(size: CGSize, scale: CGFloat) {
            width = Int((size.width * scale).rounded())
            height = Int((size.height * scale).rounded())
            self.scale = scale
        }
    }

    /// The picture as a new tab draws it (`BackdropView`), for the last
    /// pages' sizes: two windows of different sizes don't make it over and over.
    @ObservationIgnored private var composites: [(source: CGImage, canvas: Canvas, image: CGImage)] = []

    func composite(of image: CGImage, for canvas: Canvas) -> CGImage? {
        composites.first { $0.source === image && $0.canvas == canvas }?.image
    }

    /// Makes it off the main thread, unless it is made already.
    func makeComposite(of image: CGImage, for canvas: Canvas) async {
        guard composite(of: image, for: canvas) == nil else { return }
        let made = await Task.detached(priority: .userInitiated) { Self.composite(of: image, for: canvas) }.value
        // Let go, or another picture shown, meanwhile.
        guard let made, self.image === image else { return }
        composites.removeAll { $0.source !== image || $0.canvas == canvas }
        composites.append((image, canvas, made))
        if composites.count > 2 { composites.removeFirst() }
    }

    /// Core Image, as the page draws: in the pictures' own colours, not
    /// in linear light, so its blends come out as SwiftUI's would.
    private nonisolated static let drawing = CIContext(options: [.workingColorSpace: NSNull(), .cacheIntermediates: false])

    /// What `BackdropView` would draw of `image` live, as one picture: the
    /// picture filling the page, blurred from just under the field down,
    /// fading out toward the bottom, half see-through. Its blur alone would
    /// take a pass of the whole page each time the field's glass is drawn.
    nonisolated static func composite(of image: CGImage, for canvas: Canvas) -> CGImage? {
        guard canvas.width > 0, canvas.height > 0, image.width > 0, image.height > 0 else { return nil }
        let width = CGFloat(canvas.width), height = CGFloat(canvas.height)
        let page = CGRect(x: 0, y: 0, width: width, height: height)
        // Filled to the page's edges, its middle kept (`scaledToFill`).
        let scale = max(width / CGFloat(image.width), height / CGFloat(image.height))
        let scaled = CIImage(cgImage: image).applyingFilter("CILanczosScaleTransform", parameters: [
            kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1,
        ])
        let picture = scaled
            .transformed(by: CGAffineTransform(translationX: ((width - scaled.extent.width) / 2).rounded() - scaled.extent.minX,
                                               y: ((height - scaled.extent.height) / 2).rounded() - scaled.extent.minY))
            .cropped(to: page)
        // `blur(radius: 14, opaque: true)` of the page's part of the picture:
        // its edges carried on, not faded into nothing.
        let blurred = picture.clampedToExtent()
            .applyingGaussianBlur(sigma: 14 * canvas.scale)
            .cropped(to: page)
        // Down from the top, as SwiftUI's gradients go; Core Image's y goes up.
        func gradient(from top: CGFloat, _ start: CGFloat, to bottom: CGFloat, _ end: CGFloat) -> CIImage {
            CIFilter(name: "CILinearGradient", parameters: [
                "inputPoint0": CIVector(x: 0, y: height * (1 - top)),
                "inputPoint1": CIVector(x: 0, y: height * (1 - bottom)),
                "inputColor0": CIColor(red: 0, green: 0, blue: 0, alpha: start),
                "inputColor1": CIColor(red: 0, green: 0, blue: 0, alpha: end),
            ])!.outputImage!.cropped(to: page)
        }
        let sharpThenBlurred = blurred.applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputBackgroundImageKey: picture,
            kCIInputMaskImageKey: gradient(from: 0.45, 0, to: 0.9, 1),
        ])
        // The fade and the opacity at once: 1 to 0.1 from 0.4 down, of 0.55.
        let shown = sharpThenBlurred.applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: page),
            kCIInputMaskImageKey: gradient(from: 0.4, 0.55, to: 1, 0.055),
        ])
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        return drawing.createCGImage(shown, from: page, format: .RGBA8, colorSpace: space)
    }

    /// Lets the picture go once no new tab has shown it for a few minutes:
    /// going from one to another and back keeps it, a day of web pages doesn't.
    private func releaseLater() {
        releasing?.cancel()
        releasing = Task { [weak self] in
            try? await Task.sleep(for: .seconds(180))
            if !Task.isCancelled { self?.release() }
        }
    }

    /// Your pictures in `folder`, oldest first; the one kept before there
    /// could be more is moved in with them.
    private static func kept() -> [URL] {
        let files = FileManager.default
        try? files.createDirectory(at: folder, withIntermediateDirectories: true)
        if files.fileExists(atPath: legacy.path) {
            try? files.moveItem(at: legacy, to: folder.appending(path: legacy.lastPathComponent))
        }
        let found = (try? files.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey],
                                                     options: .skipsHiddenFiles)) ?? []
        let made = { (file: URL) in (try? file.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast }
        return found.sorted { made($0) < made($1) }
    }

    /// Everything the picker offers, in its order.
    var wallpapers: [Wallpaper] {
        [.daily] + Self.own.map { .own($0.lastPathComponent) } + chosen.map { .chosen($0.lastPathComponent) }
    }

    /// The file `wallpaper` shows today.
    func file(of wallpaper: Wallpaper) -> URL? {
        Self.file(for: wallpaper, own: Self.own, chosen: chosen, day: .now)
    }

    /// One of Nerda's own that has gone, or one of yours deleted, is Daily again.
    nonisolated static func file(for wallpaper: Wallpaper, own: [URL], chosen: [URL], day: Date) -> URL? {
        switch wallpaper {
        case .own(let name): if let file = own.first(where: { $0.lastPathComponent == name }) { return file }
        case .chosen(let name): if let file = chosen.first(where: { $0.lastPathComponent == name }) { return file }
        case .daily: break
        }
        return picture(for: day, among: own)
    }

    /// A picture's name, from its file's: "3-momiji.heic" is Momiji.
    static func title(of wallpaper: Wallpaper) -> String {
        switch wallpaper {
        case .daily: "A new picture each day"
        case .chosen: "Your picture"
        case .own(let name):
            name.replacing(/^\d+-/, with: "").replacing(".heic", with: "").replacing("-", with: " ").capitalized
        }
    }

    /// One a day, in turn: the same all day, the next one tomorrow.
    nonisolated static func picture(for day: Date, among pictures: [URL]) -> URL? {
        // Days counted from a fixed one, midnight to midnight: `ordinality(of:
        // .day, in: .era)` turns the day over at noon in some time zones.
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date(timeIntervalSinceReferenceDate: 0))
        guard !pictures.isEmpty,
              let number = calendar.dateComponents([.day], from: start, to: calendar.startOfDay(for: day)).day
        else { return nil }
        return pictures[number % pictures.count]
    }

    /// Makes the picture for now ready, unless it already is. Asked at
    /// launch when Nerda opens on a new tab, and each time one shows, so a
    /// new day brings the next one.
    func load() {
        guard let file = file(of: wallpaper), file != shown else { return }
        shown = file
        let screens = NSScreen.screens.map {
            CGSize(width: $0.frame.width * $0.backingScaleFactor, height: $0.frame.height * $0.backingScaleFactor)
        }
        Task.detached(priority: .userInitiated) {
            // As big as it takes to fill the largest screen, and no bigger.
            let side = Self.size(of: file).map { Self.side(of: $0, covering: screens) } ?? Self.side
            let image = Self.image(from: file, side: side)
            await MainActor.run {
                guard self.shown == file else { return }
                withAnimation(.easeInOut(duration: 0.35)) { self.image = image }
            }
        }
    }

    /// Makes small copies of the pictures for the picker, those not made
    /// yet, as it opens (or is about to: the pointer on its button). Handed
    /// over together, so the tiles don't fill in one by one.
    func loadThumbnails() {
        let files = (Self.own + chosen).filter { !thumbnailsAsked.contains($0) }
        guard !files.isEmpty else { return }
        thumbnailsAsked.formUnion(files)
        Task.detached(priority: .utility) {
            let made = files.compactMap { file in
                // The small copy inside is at most 320 px: too thin for a
                // tile (112 × 70 pt, on Retina) from a panorama.
                let small = Self.image(from: file, side: 360, small: true).flatMap { $0.width >= 224 && $0.height >= 140 ? $0 : nil }
                return (small ?? Self.image(from: file, side: 360)).map { (file, $0) }
            }
            await MainActor.run { self.thumbnails.merge(made) { $1 } }
        }
    }

    /// Adds a copy of `file` to your pictures and shows it from now on. The
    /// copy is made off the main thread: a big picture takes a few hundred ms.
    func choose(_ file: URL) async -> Bool {
        let copy = Self.folder.appending(path: UUID().uuidString + ".heic")
        guard await Task.detached(priority: .userInitiated, operation: { Self.copy(file, to: copy, side: Self.side) }).value
        else { return false }
        chosen.append(copy)
        wallpaper = .chosen(copy.lastPathComponent)
        loadThumbnails()
        return true
    }

    /// Deletes one of your pictures; if it was showing, Daily shows instead.
    func remove(_ name: String) {
        guard let file = chosen.first(where: { $0.lastPathComponent == name }) else { return }
        try? FileManager.default.removeItem(at: file)
        chosen.removeAll { $0 == file }
        thumbnails[file] = nil
        thumbnailsAsked.remove(file)
        if wallpaper == .chosen(name) { wallpaper = .daily }
    }

    /// Asks for a picture of your own, and shows it from now on.
    func askForPicture() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.message = "Choose a picture to show behind new tabs."
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let file = panel.url else { return }
        Task {
            guard await !choose(file) else { return }
            let alert = NSAlert()
            alert.messageText = "Couldn't open the picture"
            alert.informativeText = "Nerda can't read \(file.lastPathComponent) as a picture."
            alert.runModal()
        }
    }

    /// A picture's size in pixels, read without decoding it.
    nonisolated static func size(of file: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return CGSize(width: width, height: height)
    }

    /// The longest side a picture of `size` needs to fill each of `screens`
    /// edge to edge, whatever their shapes: a tall picture on a wide screen
    /// needs more than the screen's width.
    nonisolated static func side(of size: CGSize, covering screens: [CGSize]) -> Int {
        let scale = screens.map { max($0.width / size.width, $0.height / size.height) }.max() ?? 1
        return Int((max(size.width, size.height) * scale).rounded(.up))
    }

    /// Decoded no wider or taller than `side`, and at once, so drawing it
    /// never waits. `small` takes the small copy kept inside the file, if it
    /// has one (`copy` keeps one): a few ms rather than the whole picture's
    /// hundreds.
    nonisolated static func image(from file: URL, side: Int, small: Bool = false) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            small ? kCGImageSourceCreateThumbnailFromImageIfAbsent : kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: side,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary)
    }

    /// `file` as HEIC at `destination`, no bigger than `side`, with a small
    /// copy inside for the picker. Written beside
    /// it first, so a picture that fails halfway leaves the last one as it was.
    nonisolated static func copy(_ file: URL, to destination: URL, side: Int) -> Bool {
        guard let image = image(from: file, side: side) else { return false }
        let folder = destination.deletingLastPathComponent()
        let partial = folder.appending(path: "." + destination.lastPathComponent)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let out = CGImageDestinationCreateWithURL(partial as CFURL, UTType.heic.identifier as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(out, image, [
            kCGImageDestinationLossyCompressionQuality: 0.9,
            kCGImageDestinationEmbedThumbnail: true,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(out) else { return false }
        try? FileManager.default.removeItem(at: destination)
        return (try? FileManager.default.moveItem(at: partial, to: destination)) != nil
    }
}

/// A new tab's picture across the page: clear at the top, and toward the
/// bottom blurred and fading into the window's glass, where the list of
/// suggestions grows down to. Drawn as one picture made for the page's size
/// (`Backdrop.composite`); live, as below, while the page is being resized
/// and until that picture is made.
struct BackdropView: View {
    let image: CGImage
    @Environment(\.displayScale) private var scale
    @State private var size: CGSize = .zero
    /// Counts the pictures made, so the one just made is drawn.
    @State private var made = 0

    var body: some View {
        let canvas = Backdrop.Canvas(size: size, scale: scale)
        let _ = made
        Color.clear
            .overlay {
                if let composite = Backdrop.shared.composite(of: image, for: canvas) {
                    Image(decorative: composite, scale: scale).resizable()
                } else {
                    live
                }
            }
            .onGeometryChange(for: CGSize.self, of: \.size) { size = $0 }
            .task(id: canvas) {
                guard canvas.width > 0, canvas.height > 0, Backdrop.shared.composite(of: image, for: canvas) == nil else { return }
                // Not each step of a resize: once it stops.
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                await Backdrop.shared.makeComposite(of: image, for: canvas)
                made += 1
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onAppear { Backdrop.shared.showing += 1 }
            .onDisappear { Backdrop.shared.showing -= 1 }
    }

    private var live: some View {
        // Filled to the page's edges without making the page any bigger.
        let picture = Color.clear
            .overlay { Image(decorative: image, scale: 1).resizable().scaledToFill() }
            .clipped()
        // Half see-through, over the window's glass: there to set the
        // page's mood, not to be looked at instead of the field.
        return ZStack {
            picture
            picture
                .blur(radius: 14, opaque: true)
                .mask(LinearGradient(stops: [.init(color: .clear, location: 0.45), .init(color: .black, location: 0.9)],
                                     startPoint: .top, endPoint: .bottom))
        }
        .mask(LinearGradient(stops: [.init(color: .black, location: 0.4), .init(color: .black.opacity(0.1), location: 1)],
                             startPoint: .top, endPoint: .bottom))
        .opacity(0.55)
    }
}
