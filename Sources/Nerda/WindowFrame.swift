import AppKit

/// Where a profile's own window was left, to open there again at the next
/// launch, at the size it had. Kept per profile in the defaults; secondary
/// windows keep only their display, in their session, and fill it.
struct WindowFrame: Codable, Equatable {
    var frame: CGRect
    /// It was filling the screen's free part (`BrowserWindow.fill`): it fills
    /// it again, whatever size that is now (the Dock hidden or shown since).
    var fills: Bool

    /// Tests keep theirs apart from Nerda's.
    static var defaults = UserDefaults.standard

    private static func key(_ profile: UUID) -> String { "windowFrame.\(profile.uuidString)" }

    static func saved(for profile: UUID) -> WindowFrame? {
        defaults.data(forKey: key(profile)).flatMap { try? JSONDecoder().decode(WindowFrame.self, from: $0) }
    }

    func save(for profile: UUID) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        Self.defaults.set(data, forKey: Self.key(profile))
    }

    /// Where a window opens, given where it was left (`saved`) and the free
    /// part of each screen connected now, `main`'s first: the screen it was
    /// left filling, filled again; the frame it was left at, moved just
    /// enough to be all on the screen most of it is on. Filling the main
    /// screen the first time, and when it was left where no screen is now
    /// (a display since unplugged), or bigger than the one it is on.
    static func place(_ saved: WindowFrame?, on screens: [CGRect]) -> WindowFrame? {
        guard let main = screens.first else { return nil }
        guard let saved else { return WindowFrame(frame: main, fills: true) }
        let overlap = { (screen: CGRect) -> CGFloat in
            let common = screen.intersection(saved.frame)
            return common.isNull ? 0 : common.width * common.height
        }
        guard let screen = screens.max(by: { overlap($0) < overlap($1) }), overlap(screen) > 0 else {
            return WindowFrame(frame: main, fills: true)
        }
        let size = saved.frame.size
        if saved.fills || size.width > screen.width || size.height > screen.height {
            return WindowFrame(frame: screen, fills: true)
        }
        let x = min(max(saved.frame.minX, screen.minX), screen.maxX - size.width)
        let y = min(max(saved.frame.minY, screen.minY), screen.maxY - size.height)
        return WindowFrame(frame: CGRect(origin: CGPoint(x: x, y: y), size: size), fills: false)
    }

    /// Down and to the right of a window already at `taken`, as AppKit
    /// cascades windows, for an incognito window opened over the regular one.
    func cascaded(past taken: [CGRect]) -> WindowFrame {
        guard !fills else { return self }
        var frame = frame
        for _ in 0..<20 where taken.contains(where: { $0.origin == frame.origin }) {
            frame = frame.offsetBy(dx: 22, dy: -22)
        }
        return WindowFrame(frame: frame, fills: false)
    }
}
