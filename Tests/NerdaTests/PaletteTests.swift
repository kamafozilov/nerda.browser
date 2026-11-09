import AppKit
import SwiftUI
import Testing
@testable import Nerda

private let looks = [false, true].flatMap { dark in [false, true].map { Palette.Look(dark: dark, highContrast: $0) } }

/// WCAG's relative luminance of an opaque sRGB colour.
private func luminance(_ color: NSColor) -> Double {
    let c = color.usingColorSpace(.sRGB)!
    func linear(_ v: CGFloat) -> Double {
        let v = Double(v)
        return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * linear(c.redComponent) + 0.7152 * linear(c.greenComponent) + 0.0722 * linear(c.blueComponent)
}

/// `color` laid over the opaque `ground`, as it is drawn.
private func over(_ color: NSColor, _ ground: NSColor) -> NSColor {
    let c = color.usingColorSpace(.sRGB)!, g = ground.usingColorSpace(.sRGB)!
    let a = c.alphaComponent
    return NSColor(srgbRed: c.redComponent * a + g.redComponent * (1 - a),
                   green: c.greenComponent * a + g.greenComponent * (1 - a),
                   blue: c.blueComponent * a + g.blueComponent * (1 - a), alpha: 1)
}

/// WCAG's contrast ratio of `color`, drawn over `ground`.
private func contrast(_ color: NSColor, on ground: NSColor) -> Double {
    let a = luminance(over(color, ground)), b = luminance(ground)
    return (max(a, b) + 0.05) / (min(a, b) + 0.05)
}

/// Text, muted text included, is easy to read on the window's background,
/// light or dark, and more so with Increase Contrast.
@Test func textMeetsContrastOnTheWindow() {
    for look in looks {
        let ground = Palette.color(.ground, look)
        #expect(contrast(Palette.color(.muted, look), on: ground) >= 4.5, "\(look)")
        #expect(contrast(Palette.color(.ink, look), on: ground) >= (look.highContrast ? 7 : 4.5), "\(look)")
    }
    // An incognito window is dark, on its own grey.
    for high in [false, true] {
        let look = Palette.Look(dark: true, highContrast: high)
        #expect(contrast(Palette.color(.muted, look), on: Palette.color(.incognito, look)) >= 4.5, "\(look)")
    }
}

/// With Increase Contrast, dividers and edges are lines you can see (3:1, as
/// WCAG asks of what marks a control), and tints are about twice as strong.
@Test func increaseContrastStrengthensEdgesAndTints() {
    for dark in [false, true] {
        let normal = Palette.Look(dark: dark), high = Palette.Look(dark: dark, highContrast: true)
        let ground = Palette.color(.ground, high)
        for name: Palette.Name in [.hairline, .rim, .edge] {
            #expect(contrast(Palette.color(name, high), on: ground) >= 3, "\(name) \(high)")
            #expect(contrast(Palette.color(name, high), on: ground)
                    > contrast(Palette.color(name, normal), on: Palette.color(.ground, normal)), "\(name) \(high)")
        }
        for name: Palette.Name in [.hover, .wash, .glass, .panel, .card, .tint] {
            #expect(Palette.color(name, high).alphaComponent > Palette.color(name, normal).alphaComponent, "\(name)")
        }
        for name: Palette.Name in [.hover, .wash] {
            #expect(Palette.color(name, high).alphaComponent >= 2 * Palette.color(name, normal).alphaComponent, "\(name)")
        }
    }
    // Incognito's own: its selected tab's edge and its field's stand off its grey.
    let high = Palette.Look(dark: true, highContrast: true)
    for name: Palette.Name in [.incognitoRim, .incognitoFieldEdge] {
        #expect(contrast(Palette.color(name, high), on: Palette.color(.incognito, high)) >= 3, "\(name)")
    }
    for name: Palette.Name in [.incognitoWash, .incognitoHover, .incognitoLit] {
        #expect(Palette.color(name, high).alphaComponent >= 1.5 * Palette.color(name, .init(dark: true)).alphaComponent,
                "\(name)")
    }
}

/// The colours views draw with are the table's, worked out for the
/// appearance they are drawn in.
@MainActor
@Test func paletteColoursFollowTheAppearance() {
    for (name, dark) in [(NSAppearance.Name.aqua, false), (.darkAqua, true)] {
        let appearance = NSAppearance(named: name)!
        #expect(Palette.Look(appearance) == Palette.Look(dark: dark))
        appearance.performAsCurrentDrawingAppearance {
            let drawn = NSColor(Palette.muted).usingColorSpace(.sRGB)!
            let table = Palette.color(.muted, .init(dark: dark)).usingColorSpace(.sRGB)!
            #expect(abs(drawn.redComponent - table.redComponent) < 0.001, "\(name)")
        }
    }
}
