import AppKit
import SwiftUI

// Every colour is a light/dark pair and follows the window's appearance, so
// nothing else in the code needs to know which one is showing.
enum Palette {
    static let ground = pair(1.0, 0.11)     // window background
    static let ink = pair(0.09, 0.93)       // text
    static let muted = pair(0.55, 0.58)     // secondary text and icons
    static let hairline = pair(0.91, 0.20)  // dividers
    static let stage = pair(0.93, 0.07)     // round a page in Responsive Design Mode
    // Over the window's glass, which shows through them, just enough that
    // the card stands off it: the settings a little less than a new tab.
    static let glass = pair(1.0, 0.11, alpha: 0.3)   // a new tab's card
    static let panel = pair(0.96, 0.14, alpha: 0.5)  // around the settings' card
    static let card = pair(1.0, 0.11, alpha: 0.5)    // the settings' card, over the panel
    static let tint = pair(0.95, 0.14, alpha: 0.7)   // over the glass, tinted (Settings › Appearance)
    // Tints rather than solid greys, so the glass under them still shows.
    static let hover = Color.primary.opacity(0.05)  // the row or button under the pointer
    static let wash = Color.primary.opacity(0.10)   // the selected tab
    static let rim = Color.primary.opacity(0.08)    // the selected tab's edge
    // An incognito window is always dark: in place of the glass round its
    // page, a plain grey a step lighter than the page.
    static let incognito = Color(white: 0.16)
    static let incognitoField = Color(white: 0.2)   // its new tab's field
    // Its accent, a muted violet, as Firefox and Arc mark private windows:
    // the selected tab, the row under the pointer, the new tab's field.
    static let incognitoAccent = Color(red: 0.63, green: 0.55, blue: 0.95)

    private static func pair(_ light: CGFloat, _ dark: CGFloat, alpha: CGFloat = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(white: isDark ? dark : light, alpha: alpha)
        })
    }
}
