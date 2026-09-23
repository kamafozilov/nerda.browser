import AppKit
import SwiftUI

// Every colour is a light/dark pair and follows the window's appearance, so
// nothing else in the code needs to know which one is showing.
enum Palette {
    static let ground = pair(1.0, 0.11)     // window background
    static let ink = pair(0.09, 0.93)       // text
    static let muted = pair(0.55, 0.58)     // secondary text and icons
    static let hairline = pair(0.91, 0.20)  // dividers
    // A tint rather than a solid grey, so the glass under it still shows.
    static let hover = Color.primary.opacity(0.05)  // the button under the pointer

    private static func pair(_ light: CGFloat, _ dark: CGFloat) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(white: isDark ? dark : light, alpha: 1)
        })
    }
}
