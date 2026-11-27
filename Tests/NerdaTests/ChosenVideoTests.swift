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
    private func chosen(_ videos: PageVideos, in document: PageDocument = PageDocument(), at now: TimeInterval,
                        on: Bool = true, tabMuted: Bool = false, agentTab: Bool = false) -> PageVideo.ID? {
        FloatingRule.video(among: videos.all, in: document, at: now, on: on, tabMuted: tabMuted, agentTab: agentTab)
    }

    /// A page the owner went to, in sight from `since`.
    private func went(since: TimeInterval) -> PageDocument {
        PageDocument(ownersNavigation: true, startedOutOfSight: false, inSightSince: since)
    }

    /// A page that starts its video with sound as it comes in, one the owner
    /// went to (a link, an address, back): a video they chose to watch.
    @Test func aVideoStartingWithSoundAsAPageTheOwnerWentToComesInFloats() {
        var videos = PageVideos()
        videos.heard(frame: "main", main: true, [told(ownerStarted: false)], at: 102)
        #expect(chosen(videos, in: went(since: 100), at: 104.9) == nil)
        #expect(chosen(videos, in: went(since: 100), at: 105) == PageVideo.ID(frame: "main", element: 1))
    }

    /// Long after the page came in, with nothing of the owner's behind it
    /// (an ad), it stays.
    @Test func aVideoStartingWithSoundLongAfterThePageCameInStays() {
        var videos = PageVideos()
        videos.heard(frame: "main", main: true, [told(ownerStarted: false)], at: 100 + FloatingRule.firstMoments + 1)
        #expect(chosen(videos, in: went(since: 100), at: 200) == nil)
    }

    /// A page the page itself went to (a script's redirect), not the owner.
    @Test func aVideoStartingWithSoundInAPageNobodyChoseStays() {
        var videos = PageVideos()
        videos.heard(frame: "main", main: true, [told(ownerStarted: false)], at: 101)
        let document = PageDocument(ownersNavigation: false, startedOutOfSight: false, inSightSince: 100)
        #expect(chosen(videos, in: document, at: 200) == nil)
    }

    /// The page the owner went to, but a frame in it (an ad's) starting its
    /// own video with sound: not theirs.
    @Test func aFramesVideoStartingWithSoundStays() {
        var videos = PageVideos()
        videos.heard(frame: "ad", main: false, [told(ownerStarted: false)], at: 101)
        #expect(chosen(videos, in: went(since: 100), at: 200) == nil)
    }

    /// Muted, or with no sound of its own, it stays however soon it starts.
    @Test func aMutedVideoStartingAsThePageComesInStays() {
        var videos = PageVideos()
        videos.heard(frame: "main", main: true, [told(muted: true, ownerStarted: false)], at: 101)
        #expect(chosen(videos, in: went(since: 100), at: 200) == nil)
    }

    /// A page loaded out of sight, its video held until the owner brings
    /// its tab into sight: started as they do.
    @Test func aVideoStartingAsTheOwnerShowsItsTabFloats() {
        var videos = PageVideos()
        var document = PageDocument(ownersNavigation: false, startedOutOfSight: true, inSightSince: nil)
        videos.heard(frame: "main", main: true, [told(ownerStarted: false)], at: 500.2)
        #expect(chosen(videos, in: document, at: 600) == nil, "Out of sight still")
        document.inSightSince = 500
        #expect(chosen(videos, in: document, at: 600) != nil)
    }

    /// The owner's navigation brought the page it committed: WebKit's move
    /// to https and a fragment aside, not another address.
    @Test func theOwnersNavigationIsKnownByWhereItWent() {
        let asked = URL(string: "http://example.com/watch?v=1")!
        #expect(Nerda.Tab.sameDocument(asked, URL(string: "https://example.com/watch?v=1#t=3")))
        #expect(!Nerda.Tab.sameDocument(asked, URL(string: "about:blank")))
        #expect(!Nerda.Tab.sameDocument(asked, URL(string: "https://example.com/watch?v=2")))
        #expect(!Nerda.Tab.sameDocument(nil, URL(string: "https://example.com/")))
    }

    /// Only the first sound counts: a video heard first long after, though
    /// it plays again soon after a page came in, is the page's own.
    @Test func whenAVideoWasFirstHeardIsKept() {
        var videos = PageVideos()
        videos.heard(frame: "main", main: true, [told(ownerStarted: false)], at: 101)
        videos.heard(frame: "main", main: true, [told(playing: false, ownerStarted: false)], at: 102)
        videos.heard(frame: "main", main: true, [told(ownerStarted: false)], at: 300)
        #expect(chosen(videos, in: went(since: 100), at: 303) != nil)
        var late = PageVideos()
        late.heard(frame: "main", main: true, [told(playing: false, ownerStarted: false)], at: 101)
        late.heard(frame: "main", main: true, [told(ownerStarted: false)], at: 300)
        #expect(chosen(late, in: went(since: 100), at: 303) == nil)
    }

    @Test func aVideoTheOwnerStartedFloatsAfterThreeSecondsWithSound() {
        var videos = PageVideos()
        videos.heard(frame: "main", main: true, [told()], at: 100)
        #expect(chosen(videos, at: 102.9) == nil)
        #expect(chosen(videos, at: 103) == PageVideo.ID(frame: "main", element: 1))
    }

    @Test func onlyTimeWithSoundCountsTowardsTheThreeSeconds() {
        var videos = PageVideos()
        videos.heard(frame: "main", main: true, [told()], at: 100)
        videos.heard(frame: "main", main: true, [told(playing: false)], at: 102)
        videos.heard(frame: "main", main: true, [told(playing: true)], at: 200)
        #expect(chosen(videos, at: 200.9) == nil)
        videos.heard(frame: "main", main: true, [told(muted: true)], at: 200.5)
        videos.heard(frame: "main", main: true, [told()], at: 300)
        #expect(chosen(videos, at: 300.4) == nil)
        #expect(chosen(videos, at: 300.5) != nil)
    }

    @Test func aMutedVideoPlayingByItselfStaysInItsPage() {
        var videos = PageVideos()
        videos.heard(frame: "main", main: true, [told(muted: true, ownerStarted: false)], at: 0)
        #expect(chosen(videos, at: 60) == nil)
    }

    /// A hover preview, or a video the page started with its sound on.
    @Test func aVideoThePageStartedItselfStaysInItsPage() {
        var videos = PageVideos()
        videos.heard(frame: "main", main: true, [told(ownerStarted: false)], at: 0)
        #expect(chosen(videos, at: 60) == nil)
    }

    @Test func aFeedVideoTheOwnerUnmutedFloats() {
        var videos = PageVideos()
        videos.heard(frame: "main", main: true, [told(muted: true, ownerStarted: false)], at: 0)
        videos.heard(frame: "main", main: true, [told(muted: false, ownerStarted: true)], at: 10)
        #expect(chosen(videos, at: 12) == nil)
        #expect(chosen(videos, at: 13) != nil)
    }

    @Test func aMutedTabsVideoStaysInItsPage() {
        var videos = PageVideos()
        videos.heard(frame: "main", main: true, [told()], at: 0)
        #expect(chosen(videos, at: 60, tabMuted: true) == nil)
    }

    @Test func soundWithoutAPictureFloatsNothing() {
        var videos = PageVideos()
        videos.heard(frame: "main", main: true, [told(hasPicture: false)], at: 0)
        #expect(chosen(videos, at: 60) == nil)
    }

    @Test func aVideoWithNoSoundTrackStaysInItsPage() {
        var videos = PageVideos()
        videos.heard(frame: "main", main: true, [told(hasSound: false)], at: 0)
        #expect(chosen(videos, at: 60) == nil)
    }

    @Test func anAgentTabsVideoNeverFloatsByItself() {
        var videos = PageVideos()
        videos.heard(frame: "main", main: true, [told()], at: 0)
        #expect(chosen(videos, at: 60, agentTab: true) == nil)
    }

    @Test func withAutoPictureInPictureOffNothingFloats() {
        var videos = PageVideos()
        videos.heard(frame: "main", main: true, [told()], at: 0)
        #expect(chosen(videos, at: 60, on: false) == nil)
    }

    /// The largest of those that may float, whichever frame it is in; a
    /// larger one that may not (muted) doesn't count.
    @Test func ofSeveralTheLargestFloats() {
        var videos = PageVideos()
        videos.heard(frame: "main", main: true, [told(1, area: 320 * 180), told(2, muted: true, area: 1920 * 1080)], at: 0)
        videos.heard(frame: "embed", main: false, [told(1, area: 640 * 360)], at: 0)
        #expect(chosen(videos, at: 10) == PageVideo.ID(frame: "embed", element: 1))
    }

    /// A frame that went (a new document, a frame taken out) takes its videos with it.
    @Test func aFrameGoneTakesItsVideos() {
        var videos = PageVideos()
        videos.heard(frame: "embed", main: false, [told()], at: 0)
        videos.gone(frame: "embed")
        #expect(chosen(videos, at: 10) == nil)
    }

    /// A video the frame no longer tells of (taken out of the page) is gone.
    @Test func aVideoNoLongerToldOfIsGone() {
        var videos = PageVideos()
        videos.heard(frame: "main", main: true, [told(1), told(2)], at: 0)
        videos.heard(frame: "main", main: true, [told(2, playing: false)], at: 5)
        #expect(chosen(videos, at: 10) == nil)
    }
}

extension Nerda.Tab {
    /// As if its page had told Nerda of a video the owner started, playing
    /// with sound and heard long enough to float, on `browser`'s clock.
    @MainActor func playsAVideoTheOwnerChose(in browser: Browser) {
        let video = PageVideos.Told(element: 1, playing: true, muted: false, hasSound: true, hasPicture: true,
                                    ownerStarted: true, area: 640 * 360)
        heardVideos(frame: "main", in: nil, main: true, [video], at: browser.videoClock() - FloatingRule.heardAtLeast)
    }
}
