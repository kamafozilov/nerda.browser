import Foundation

/// The sites a lab run visits, signed out, and how each is reached.
/// Addresses chosen 2026-11-27 and checked then: a YouTube video by its
/// oEmbed answer, the others by search. Should one go, its row says so
/// (unreachable, or would not play) and the address is changed here.
struct SiteSpec: Sendable {
    enum Kind: Sendable {
        case youtube, twitch, x, instagram, local
    }

    enum Address: Sendable {
        case web(String)
        /// A page of the run's own holding a YouTube player for `video`,
        /// as another site embeds one.
        case embed(video: String)
        /// The first live channel Twitch lists, as it lists them then.
        case twitchLive
        /// The bed's movie with the sweep, from the run's own server.
        case localFile
        case localHLS
    }

    var name: String
    var kind: Kind
    var address: Address
    /// A live stream: nothing to seek to, maybe.
    var live = false

    /// Big Buck Bunny, from the Blender Foundation's own channel: ten
    /// minutes with sound all through.
    static let video = "aqz-KE-bpKQ"

    static let all: [SiteSpec] = [
        SiteSpec(name: "Local video file", kind: .local, address: .localFile),
        SiteSpec(name: "Local HLS stream", kind: .local, address: .localHLS),
        SiteSpec(name: "YouTube watch page", kind: .youtube, address: .web("https://www.youtube.com/watch?v=\(video)&t=60s")),
        // Shorts as YouTube gives them out: the first of its feed.
        SiteSpec(name: "YouTube Shorts", kind: .youtube, address: .web("https://www.youtube.com/shorts")),
        // Lofi Girl's live stream, whichever is live now (its old one ended).
        SiteSpec(name: "YouTube live stream", kind: .youtube, address: .web("https://www.youtube.com/@LofiGirl/live"), live: true),
        SiteSpec(name: "YouTube player embedded on another site", kind: .youtube, address: .embed(video: video)),
        SiteSpec(name: "X, signed out", kind: .x, address: .web("https://x.com/NASA/status/2039473910987534599")),
        SiteSpec(name: "Twitch live stream", kind: .twitch, address: .twitchLive, live: true),
        SiteSpec(name: "Instagram reel, signed out", kind: .instagram, address: .web("https://www.instagram.com/reel/CzOsYYsu9jP/")),
    ]

    var shown: String {
        switch address {
        case .web(let url): url
        case .embed(let video): "a page of the run's own with https://www.youtube.com/embed/\(video)"
        case .twitchLive: "https://www.twitch.tv/directory/all, its first live channel"
        case .localFile: "the bed's 120 s movie with the sweep, served on this Mac"
        case .localHLS: "the bed's 120 s movie with the sweep as HLS, served on this Mac"
        }
    }

    /// Addresses that mean the site put a wall before the video.
    static func wall(at url: String) -> String? {
        let walls = [
            ("consent.youtube.com", "YouTube's consent page"), ("consent.google.com", "Google's consent page"),
            ("accounts.google.com", "a Google sign-in page"), ("/accounts/login", "Instagram's sign-in page"),
            ("/i/flow/login", "X's sign-in page"), ("twitch.tv/login", "Twitch's sign-in page"),
        ]
        return walls.first { url.contains($0.0) }?.1
    }

    /// A script for the page's own world asking the site's player to play,
    /// as its own button does, for a player whose video has nothing to play
    /// yet; empty when the site has no player to ask.
    var playerPlay: String {
        switch kind {
        case .youtube: #"""
            const player = document.querySelector('#movie_player');
            if (!player?.playVideo) return '';
            player.playVideo();
            const playable = player.getPlayerResponse?.()?.playabilityStatus;
            return 'the player played (state ' + (player.getPlayerState?.() ?? '?') + ', playable ' + (playable ? playable.status + ' ' + (playable.reason ?? '') : '?') + ')';
            """#
        default: "return '';"
        }
    }

    /// A script for the main frame saying what of the site's own stands
    /// before its video now: an ad, a gate to press, a wall. Empty when
    /// nothing does.
    var obstacle: String {
        switch kind {
        case .youtube: #"""
            const player = document.querySelector('#movie_player, .html5-video-player');
            const skip = document.querySelector('.ytp-skip-ad-button, .ytp-ad-skip-button-modern, .ytp-ad-skip-button');
            if (skip && skip.offsetParent) { skip.click(); return 'ad (skipped)'; }
            if (player?.classList.contains('ad-showing')) return 'ad';
            const error = document.querySelector('.ytp-error');
            if (error && error.offsetParent) return 'error: ' + error.innerText.replace(/\s+/g, ' ').trim();
            if (document.querySelector('ytd-consent-bump-v2-lightbox, tp-yt-paper-dialog #consent-bump')) return 'consent';
            return '';
            """#
        case .twitch: #"""
            const gate = document.querySelector('[data-a-target="content-classification-gate-overlay-start-watching-button"], [data-a-target="player-overlay-mature-accept"]');
            if (gate) { gate.click(); return 'gate (pressed)'; }
            if (document.querySelector('[data-a-target="video-ad-label"], [data-a-target="video-ad-countdown"]')) return 'ad';
            return '';
            """#
        case .x, .instagram, .local: "return '';"
        }
    }
}
