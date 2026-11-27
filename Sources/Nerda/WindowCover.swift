import AppKit

/// How much of a window other windows cover, from plain rectangles in the
/// window server's space (as its window list gives them, top left at the
/// top left of the main screen). Of the part of the window on the screens,
/// the share that windows above it lie over, each place counted once
/// however many lie there; the part off every screen is left out, as no
/// other window can cover it either. A hidden window (minimised, Nerda
/// hidden, on another Space) or one on no screen is all covered.
nonisolated struct WindowCover: Equatable {
    var window: CGRect
    var screens: [CGRect]
    var above: [CGRect]
    var hidden = false

    /// From 0, in full view, to 1, nothing of it in sight.
    var covered: Double {
        if hidden { return 1 }
        let seen = Self.area(window, of: screens)
        guard seen > 0 else { return 1 }
        return Self.area(window, of: screens, under: above) / seen
    }

    /// Hidden, or at least half covered: its video is out of sight enough to
    /// float, as for another app.
    var hidesVideo: Bool { covered >= 0.5 }

    /// A window as the window server lists it.
    struct Listed: Equatable {
        var layer: Int
        var alpha: Double
        var bounds: CGRect
    }

    /// The levels apps' windows and panels are shown at, below the Dock's:
    /// the menu bar, the Dock, the pointer and the desktop's widgets are
    /// listed too, and cover nothing an owner would call covered.
    static let levels = 0..<Int(CGWindowLevelForKey(.dockWindow))

    /// Those of `listed` that cover what is under them: an app's, at its
    /// windows' levels, not see-through.
    static func covering(_ listed: [Listed]) -> [CGRect] {
        listed.filter { levels.contains($0.layer) && $0.alpha > 0 }.map(\.bounds)
    }

    /// The area of `window` that lies on any of `screens`, and with `under`,
    /// also under any of those: the window cut on every edge of them all
    /// into cells, each wholly in or out of each rectangle.
    private static func area(_ window: CGRect, of screens: [CGRect], under: [CGRect]? = nil) -> Double {
        let screens = screens.map(window.intersection).filter { !$0.isEmpty }
        let under = under.map { $0.map(window.intersection).filter { !$0.isEmpty } }
        guard !screens.isEmpty, under?.isEmpty != true else { return 0 }
        let all = screens + (under ?? [])
        let xs = Set(all.flatMap { [$0.minX, $0.maxX] }).sorted()
        let ys = Set(all.flatMap { [$0.minY, $0.maxY] }).sorted()
        var total = 0.0
        for (left, right) in zip(xs, xs.dropFirst()) {
            for (top, bottom) in zip(ys, ys.dropFirst()) {
                let middle = CGPoint(x: (left + right) / 2, y: (top + bottom) / 2)
                guard screens.contains(where: { $0.contains(middle) }) else { continue }
                if let under, !under.contains(where: { $0.contains(middle) }) { continue }
                total += (right - left) * (bottom - top)
            }
        }
        return total
    }
}

extension WindowCover {
    /// `window` as it is on screen now: the windows the window server lists
    /// above it, at every level, are read for their places alone, which asks
    /// for no permission (their names would).
    static func read(_ window: NSWindow) -> WindowCover {
        let screens = displays()
        // No number yet: never put on screen.
        guard let number = CGWindowID(exactly: window.windowNumber), number > 0 else {
            return WindowCover(window: window.frame, screens: screens, above: [], hidden: true)
        }
        let away = !window.isVisible || window.isMiniaturized || NSApp.isHidden || !window.occlusionState.contains(.visible)
        let listed = { (options: CGWindowListOption) in
            (CGWindowListCopyWindowInfo(options, number) as? [[String: Any]] ?? []).map { info in
                Listed(layer: info[kCGWindowLayer as String] as? Int ?? 0,
                       alpha: info[kCGWindowAlpha as String] as? Double ?? 1,
                       bounds: (info[kCGWindowBounds as String] as? NSDictionary)
                        .flatMap { CGRect(dictionaryRepresentation: $0) } ?? .zero)
            }
        }
        guard !away, let own = listed(.optionIncludingWindow).first else {
            return WindowCover(window: window.frame, screens: screens, above: [], hidden: true)
        }
        return WindowCover(window: own.bounds, screens: screens,
                           above: covering(listed([.optionOnScreenAboveWindow, .excludeDesktopElements])))
    }

    /// The screens' places, in the window list's space.
    private static func displays() -> [CGRect] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).map(CGDisplayBounds)
    }
}
