import AppKit
import SwiftUI

// Every colour is a light/dark pair, and a stronger pair for Increase
// Contrast (System Settings › Accessibility › Display), and follows the
// window's appearance, so nothing else in the code needs to know which one
// is showing.
enum Palette {
    static let ground = shade(.ground)       // window background
    static let ink = shade(.ink)             // text
    static let muted = shade(.muted)         // secondary text and icons
    static let hairline = shade(.hairline)   // dividers
    static let stage = shade(.stage)         // round a page in Responsive Design Mode
    // Over the window's glass, which shows through them, just enough that
    // the card stands off it: the settings a little less than a new tab.
    static let glass = shade(.glass)    // a new tab's card
    static let panel = shade(.panel)    // around the settings' card
    static let card = shade(.card)      // the settings' card, over the panel
    static let tint = shade(.tint)      // over the glass, tinted (Settings › Appearance)
    // Tints rather than solid greys, so the glass under them still shows.
    static let hover = shade(.hover)    // the row or button under the pointer
    static let wash = shade(.wash)      // the selected tab
    static let rim = shade(.rim)        // the selected tab's edge
    static let edge = shade(.edge)      // the page card's edge, and the tab on screen across the top
    // An incognito window is always dark: in place of the glass round its
    // page, a plain grey a step lighter than the page.
    static let incognito = shade(.incognito)
    static let incognitoField = shade(.incognitoField)   // its new tab's field
    // Its accent, a muted violet, as Firefox and Arc mark private windows:
    // the selected tab, the row under the pointer, the new tab's field.
    static let incognitoAccent = Color(red: 0.63, green: 0.55, blue: 0.95)
    static let incognitoWash = shade(.incognitoWash)     // its selected tab
    static let incognitoHover = shade(.incognitoHover)   // its row under the pointer
    static let incognitoRim = shade(.incognitoRim)       // its selected tab's edge
    static let incognitoLit = shade(.incognitoLit)       // its menu's row under the pointer
    static let incognitoFieldEdge = shade(.incognitoFieldEdge)   // round its new tab's field

    /// What a colour is drawn for: light or dark, and whether Increase
    /// Contrast is on.
    nonisolated struct Look: Hashable {
        var dark: Bool
        var highContrast = false

        init(dark: Bool, highContrast: Bool = false) {
            self.dark = dark
            self.highContrast = highContrast
        }

        init(_ appearance: NSAppearance) {
            let match = appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua,
                                                    .accessibilityHighContrastDarkAqua])
            dark = match == .darkAqua || match == .accessibilityHighContrastDarkAqua
            // An incognito window's appearance is set to plain Dark Aqua, which
            // never matches a high-contrast one: the setting itself decides too.
            highContrast = match == .accessibilityHighContrastAqua || match == .accessibilityHighContrastDarkAqua
                || NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        }
    }

    nonisolated enum Name: CaseIterable {
        case ground, ink, muted, hairline, stage, glass, panel, card, tint, hover, wash, rim, edge
        case incognito, incognitoField, incognitoWash, incognitoHover, incognitoRim, incognitoLit, incognitoFieldEdge
    }

    /// Each colour, for each look. With Increase Contrast, text is darker
    /// (lighter, in dark mode), what stood off the glass covers more of it,
    /// tints are about twice as strong and edges are lines you can see.
    /// Muted text keeps at least 4.5:1 on the window's background either way.
    nonisolated static func color(_ name: Name, _ look: Look) -> NSColor {
        let high = look.highContrast
        // (light, dark), as greys.
        func grey(_ light: CGFloat, _ dark: CGFloat, alpha: CGFloat = 1) -> NSColor {
            NSColor(white: look.dark ? dark : light, alpha: alpha)
        }
        // Black over a light window, white over a dark one: as
        // `Color.primary`, which is the label colour, 85% opaque.
        func primary(_ alpha: CGFloat, high highAlpha: CGFloat) -> NSColor {
            NSColor(white: look.dark ? 1 : 0, alpha: high ? highAlpha : alpha * 0.85)
        }
        func violet(_ alpha: CGFloat, high highAlpha: CGFloat) -> NSColor {
            NSColor(red: 0.63, green: 0.55, blue: 0.95, alpha: high ? highAlpha : alpha)
        }
        switch name {
        case .ground: return grey(1.0, high ? 0.08 : 0.11)
        case .ink: return high ? grey(0, 1) : grey(0.09, 0.93)
        case .muted: return high ? grey(0.30, 0.75) : grey(0.45, 0.58)
        case .hairline: return high ? grey(0.55, 0.45) : grey(0.91, 0.20)
        case .stage: return grey(high ? 0.88 : 0.93, high ? 0.03 : 0.07)
        case .glass: return grey(1.0, 0.11, alpha: high ? 0.6 : 0.3)
        case .panel: return grey(0.96, 0.14, alpha: high ? 0.8 : 0.5)
        case .card: return grey(1.0, 0.11, alpha: high ? 0.85 : 0.5)
        case .tint: return grey(0.95, 0.14, alpha: high ? 0.9 : 0.7)
        case .hover: return primary(0.05, high: 0.12)
        case .wash: return primary(0.10, high: 0.22)
        case .rim: return primary(0.08, high: 0.45)
        case .edge: return primary(0.12, high: 0.5)
        case .incognito: return NSColor(white: high ? 0.10 : 0.16, alpha: 1)
        case .incognitoField: return NSColor(white: high ? 0.24 : 0.2, alpha: 1)
        case .incognitoWash: return violet(0.22, high: 0.4)
        case .incognitoHover: return violet(0.1, high: 0.22)
        case .incognitoRim: return violet(0.35, high: 0.7)
        case .incognitoLit: return violet(0.18, high: 0.35)
        case .incognitoFieldEdge: return violet(0.45, high: 0.8)
        }
    }

    // A page from a server on this Mac (Developer Mode): amber, as Arc's
    // hazard tape, round the page, round its tab, and on its port.
    static let dev = Color(red: 0.96, green: 0.72, blue: 0.23)
    // As text (the port in the address): darker over a light page, to be read.
    static let devInk = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(red: 0.96, green: 0.72, blue: 0.23, alpha: 1) : NSColor(red: 0.62, green: 0.40, blue: 0, alpha: 1)
    })

    /// A profile's colour (Settings › Profiles), on its symbol: the Mac's own
    /// accent colours, as Safari's profiles take theirs, light and dark alike.
    enum Accent: String, CaseIterable, Identifiable {
        case blue, purple, pink, red, orange, yellow, green, graphite
        var id: Self { self }
        var name: String { rawValue.capitalized }
        var color: Color {
            switch self {
            case .blue: .blue
            case .purple: .purple
            case .pink: .pink
            case .red: .red
            case .orange: .orange
            case .yellow: .yellow
            case .green: .green
            case .graphite: .gray
            }
        }
    }

    /// Worked out again whenever the appearance changes, Increase Contrast
    /// included, so a view drawn with it needs nothing to follow it. On
    /// whatever thread draws it, so tied to none.
    private static func shade(_ name: Name) -> Color {
        Color(nsColor: NSColor(name: nil) { @Sendable appearance in color(name, Look(appearance)) })
    }
}
