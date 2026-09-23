import AppKit
import SwiftUI

// Every colour is a light/dark pair and follows the window's appearance, so
// nothing else in the code needs to know which one is showing.
enum Palette {
    static let ground = pair(1.0, 0.11)     // window background
    static let ink = pair(0.09, 0.93)       // text
    static let muted = pair(0.55, 0.58)     // secondary text and icons
    static let hairline = pair(0.91, 0.20)  // dividers
    // Tints rather than solid greys, so the glass under them still shows.
    static let hover = Color.primary.opacity(0.05)  // the row or button under the pointer
    static let wash = Color.primary.opacity(0.10)   // the selected tab
    static let rim = Color.primary.opacity(0.08)    // the selected tab's edge

    private static func pair(_ light: CGFloat, _ dark: CGFloat) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(white: isDark ? dark : light, alpha: 1)
        })
    }
}
