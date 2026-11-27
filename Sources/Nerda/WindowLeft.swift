import Foundation

/// The owner leaving a window and coming back to it, whatever the moment:
/// another of Nerda's windows coming forward, the Dock (`WindowInFront`),
/// or another app (#169). Each says only when; leaving and coming back are
/// decided here, so a window left twice floats its video once and lands it once.
extension Browser {
    /// The owner left this window, its tab on screen with it: its video
    /// floats, as on leaving the tab, with Auto Picture-in-Picture on, a
    /// video to float (`floats(leaving:)`) and the tab not muted. Whether a
    /// video is to float. The caller checks any setting of its own first.
    @discardableResult
    func windowLeft() -> Bool {
        // A muted tab's video has no sound to keep hearing.
        guard !isForAgents, PictureInPicture.isOn(in: pictureInPictureSettings),
              let tab = selected, !tab.isMuted, floats(leaving: tab) else { return false }
        // Left already: floated once. Unless the owner landed it meanwhile
        // (the floating window's own button), and is now leaving again.
        if leftFloating === tab, tab.wantsFloating { return true }
        leftFloating = tab
        float(tab)
        return true
    }

    /// The owner is back at this window, in front: the video floated by
    /// leaving it lands, once. Nothing for a video floated otherwise (its
    /// page's own button), as with Auto Picture-in-Picture off.
    func windowCameBack() {
        guard let tab = leftFloating else { return }
        leftFloating = nil
        land(tab)
    }
}
