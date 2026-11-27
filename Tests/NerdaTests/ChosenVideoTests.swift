import Foundation
import Testing
@testable import Nerda

/// Which video of a page floats as the owner leaves it, decided over what
/// its frames told Nerda (`PageVideos`), with no page or window: only one
/// the owner chose, playing with sound for three seconds, the largest.
@MainActor
struct ChosenVideoTests {
    /// The page's word for a video: playing with sound, started by the owner.
    private func told(_ element: Int = 1, playing: Bool = true, muted: Bool = false,
                      hasSound: Bool = true, hasPicture: Bool = true, ownerStarted: Bool = true,
                      area: Double = 640 * 360) -> PageVideos.Told {
        PageVideos.Told(element: element, playing: playing, muted: muted, hasSound: hasSound,
                        hasPicture: hasPicture, ownerStarted: ownerStarted, area: area)
    }

    /// The video chosen to float at `now`, with the setting on, in an
    /// owner's tab with its sound on, unless said otherwise.
    private func chosen(_ videos: PageVideos, at now: TimeInterval, on: Bool = true, tabMuted: Bool = false,
                        agentTab: Bool = false) -> PageVideo.ID? {
        FloatingRule.video(among: videos.all, at: now, on: on, tabMuted: tabMuted, agentTab: agentTab)
    }

    @Test func aVideoTheOwnerStartedFloatsAfterThreeSecondsWithSound() {
        var videos = PageVideos()
        videos.heard(frame: "main", [told()], at: 100)
        #expect(chosen(videos, at: 102.9) == nil)
        #expect(chosen(videos, at: 103) == PageVideo.ID(frame: "main", element: 1))
    }

    @Test func onlyTimeWithSoundCountsTowardsTheThreeSeconds() {
        var videos = PageVideos()
        videos.heard(frame: "main", [told()], at: 100)
        videos.heard(frame: "main", [told(playing: false)], at: 102)
        videos.heard(frame: "main", [told(playing: true)], at: 200)
        #expect(chosen(videos, at: 200.9) == nil)
        videos.heard(frame: "main", [told(muted: true)], at: 200.5)
        videos.heard(frame: "main", [told()], at: 300)
        #expect(chosen(videos, at: 300.4) == nil)
        #expect(chosen(videos, at: 300.5) != nil)
    }

    @Test func aMutedVideoPlayingByItselfStaysInItsPage() {
        var videos = PageVideos()
        videos.heard(frame: "main", [told(muted: true, ownerStarted: false)], at: 0)
        #expect(chosen(videos, at: 60) == nil)
    }

    /// A hover preview, or a video the page started with its sound on.
    @Test func aVideoThePageStartedItselfStaysInItsPage() {
        var videos = PageVideos()
        videos.heard(frame: "main", [told(ownerStarted: false)], at: 0)
        #expect(chosen(videos, at: 60) == nil)
    }

    @Test func aFeedVideoTheOwnerUnmutedFloats() {
        var videos = PageVideos()
        videos.heard(frame: "main", [told(muted: true, ownerStarted: false)], at: 0)
        videos.heard(frame: "main", [told(muted: false, ownerStarted: true)], at: 10)
        #expect(chosen(videos, at: 12) == nil)
        #expect(chosen(videos, at: 13) != nil)
    }

    @Test func aMutedTabsVideoStaysInItsPage() {
        var videos = PageVideos()
        videos.heard(frame: "main", [told()], at: 0)
        #expect(chosen(videos, at: 60, tabMuted: true) == nil)
    }

    @Test func soundWithoutAPictureFloatsNothing() {
        var videos = PageVideos()
        videos.heard(frame: "main", [told(hasPicture: false)], at: 0)
        #expect(chosen(videos, at: 60) == nil)
    }

    @Test func aVideoWithNoSoundTrackStaysInItsPage() {
        var videos = PageVideos()
        videos.heard(frame: "main", [told(hasSound: false)], at: 0)
        #expect(chosen(videos, at: 60) == nil)
    }

    @Test func anAgentTabsVideoNeverFloatsByItself() {
        var videos = PageVideos()
        videos.heard(frame: "main", [told()], at: 0)
        #expect(chosen(videos, at: 60, agentTab: true) == nil)
    }

    @Test func withAutoPictureInPictureOffNothingFloats() {
        var videos = PageVideos()
        videos.heard(frame: "main", [told()], at: 0)
        #expect(chosen(videos, at: 60, on: false) == nil)
    }

    /// The largest of those that may float, whichever frame it is in; a
    /// larger one that may not (muted) doesn't count.
    @Test func ofSeveralTheLargestFloats() {
        var videos = PageVideos()
        videos.heard(frame: "main", [told(1, area: 320 * 180), told(2, muted: true, area: 1920 * 1080)], at: 0)
        videos.heard(frame: "embed", [told(1, area: 640 * 360)], at: 0)
        #expect(chosen(videos, at: 10) == PageVideo.ID(frame: "embed", element: 1))
    }

    /// A frame that went (a new document, a frame taken out) takes its videos with it.
    @Test func aFrameGoneTakesItsVideos() {
        var videos = PageVideos()
        videos.heard(frame: "embed", [told()], at: 0)
        videos.gone(frame: "embed")
        #expect(chosen(videos, at: 10) == nil)
    }

    /// A video the frame no longer tells of (taken out of the page) is gone.
    @Test func aVideoNoLongerToldOfIsGone() {
        var videos = PageVideos()
        videos.heard(frame: "main", [told(1), told(2)], at: 0)
        videos.heard(frame: "main", [told(2, playing: false)], at: 5)
        #expect(chosen(videos, at: 10) == nil)
    }
}
