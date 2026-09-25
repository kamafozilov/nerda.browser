import AppKit
import SwiftUI

/// ⌘Q asks first, as Dia does: a slip of the finger shouldn't close every
/// tab. Return quits, Esc stays. "Always quit" stops the asking; Settings ›
/// General › Warn before quitting brings it back.
enum QuitConfirmation {
    enum Answer { case quit, alwaysQuit, cancel }

    static let key = "warnsBeforeQuitting"

    static var isWanted: Bool {
        get { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    private static var answer = Answer.cancel

    /// Macs quit their apps to log out, restart or shut down, and to install
    /// updates: a question then would hold that up, and they don't wait for one.
    static var systemIsQuitting: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return false }
        return event.eventID == kAEQuitApplication && event.attributeDescriptor(forKeyword: kAEQuitReason) != nil
    }

    /// Asks, over the middle of the screen the window is on, and waits for the answer.
    static func ask() -> Answer {
        answer = .cancel
        let panel = KeyPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .modalPanel
        panel.isReleasedWhenClosed = false
        let content = NSHostingView(rootView: QuitDialog(answer: settle))
        panel.contentView = content
        panel.setContentSize(content.fittingSize)
        if let screen = NSApp.mainWindow?.screen ?? NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.midY - panel.frame.height / 2))
        }

        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        NSApp.runModal(for: panel)
        panel.orderOut(nil)
        return answer
    }

    /// Puts the question away with `answer`.
    static func settle(_ answer: Answer) {
        Self.answer = answer
        NSApp.stopModal()
    }

    /// Borderless windows can't take the keyboard unless they say so.
    private final class KeyPanel: NSPanel {
        override var canBecomeKey: Bool { true }
    }
}

private struct QuitDialog: View {
    let answer: (QuitConfirmation.Answer) -> Void

    private let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 32, height: 32)
            Text("Are you sure you want to quit Nerda?")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(Palette.ink)
                .padding(.top, 14)
            Text("You may lose unsaved work in your tabs.")
                .font(.system(size: 13))
                .foregroundStyle(Palette.muted)
                .padding(.top, 8)
            HStack(spacing: 8) {
                DialogButton(title: "Always quit") { answer(.alwaysQuit) }
                Spacer(minLength: 24)
                DialogButton(title: "Cancel", key: Text("ESC").font(.system(size: 9, weight: .bold))) { answer(.cancel) }
                    .keyboardShortcut(.cancelAction)
                DialogButton(title: "Quit", key: Image(systemName: "return").font(.system(size: 13, weight: .medium)),
                             prominent: true) { answer(.quit) }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 32)
            // ⌘Q again quits, as in Chrome: the menu bar is out of reach while the question is up.
            .background {
                Button("") { answer(.quit) }
                    .keyboardShortcut("q")
                    .opacity(0)
            }
        }
        .padding(24)
        .frame(width: 424)
        .background(Palette.ground, in: shape)
        .overlay(shape.strokeBorder(Palette.hairline))
        .clipShape(shape)
    }
}

private struct DialogButton<Key: View>: View {
    let title: String
    var key: Key?
    var prominent = false
    let action: () -> Void

    init(title: String, key: Key? = nil, prominent: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.key = key
        self.prominent = prominent
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(prominent ? .white : Palette.ink)
                if let key {
                    if prominent {
                        key.foregroundStyle(.white.opacity(0.6))
                    } else {
                        // A key cap.
                        key.foregroundStyle(Palette.muted)
                            .padding(.horizontal, 5)
                            .frame(height: 18)
                            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Palette.muted.opacity(0.6)))
                    }
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 34)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(prominent ? AnyShapeStyle(Color(red: 0.82, green: 0.16, blue: 0.13)) : AnyShapeStyle(Palette.wash))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }
}

extension DialogButton where Key == EmptyView {
    init(title: String, action: @escaping () -> Void) {
        self.init(title: title, key: nil, action: action)
    }
}
