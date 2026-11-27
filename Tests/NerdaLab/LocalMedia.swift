import Foundation
import MediaCheck

/// The media test bed's own media, made for the run and served on this
/// Mac: a movie with the sweep (its pitch tells the media time, so the
/// sound recorded is compared with what it should have been), as a file
/// and as an HLS stream, and a page embedding a YouTube player.
@MainActor
final class LocalMedia {
    let server: MediaServer
    /// Under three minutes: the sweep's second tone stays under AAC's cut-off.
    static let seconds = 120.0

    init() throws { server = try MediaServer() }

    func stop() { server.stop() }

    /// A page with the video at a player's usual size, its own controls,
    /// nothing else.
    private func page(_ source: URL, title: String) -> String {
        """
        <!doctype html>
        <meta charset="utf-8">
        <title>\(title)</title>
        <body style="margin:0;background:#111">
        <video src="\(source.absoluteString)" controls playsinline preload="auto" width="640" height="360"></video>
        """
    }

    private var made: Data?

    private func movie() async throws -> Data {
        if let made { return made }
        let movie = try await GeneratedMovie.mp4(seconds: Self.seconds, sound: .sweep)
        made = movie
        return movie
    }

    /// The movie itself, served.
    func fileMovie() async throws -> URL {
        try await server.serve("/media/sweep.mp4", try await movie(), type: "video/mp4")
    }

    func file() async throws -> URL {
        let movie = try await server.serve("/media/sweep.mp4", try await movie(), type: "video/mp4")
        return try await server.serve("/file.html", html: page(movie, title: "The sweep, a file"))
    }

    /// The file's page with the element itself at the bed's 0.001 as well,
    /// for the run's first check that pages play quieter still.
    func quietFile() async throws -> URL {
        let movie = try await server.serve("/media/sweep.mp4", try await movie(), type: "video/mp4")
        return try await server.serve("/quiet.html", html: """
            <!doctype html>
            <meta charset="utf-8">
            <title>The sweep, at 0.001 of 0.001</title>
            <video src="\(movie.absoluteString)" playsinline preload="auto" width="640" height="360"></video>
            <script>document.querySelector('video').volume = 0.001;</script>
            """)
    }

    func hls() async throws -> URL {
        let movie = try await GeneratedMovie.segments(seconds: Self.seconds, sound: .sweep)
        try await server.serve("/hls/init.mp4", movie.initialization, type: "video/mp4")
        for (index, segment) in movie.media.enumerated() {
            try await server.serve("/hls/\(index).m4s", segment.data, type: "video/iso.segment")
        }
        let longest = movie.media.map(\.duration).max() ?? 1
        let lines = ["#EXTM3U", "#EXT-X-VERSION:7", "#EXT-X-TARGETDURATION:\(Int(longest.rounded(.up)))",
                     "#EXT-X-PLAYLIST-TYPE:VOD", "#EXT-X-INDEPENDENT-SEGMENTS", "#EXT-X-MAP:URI=\"init.mp4\""]
            + movie.media.enumerated().flatMap { index, segment in [String(format: "#EXTINF:%.3f,", segment.duration), "\(index).m4s"] }
            + ["#EXT-X-ENDLIST"]
        let playlist = try await server.serve("/hls/index.m3u8", Data((lines.joined(separator: "\n") + "\n").utf8),
                                              type: "application/vnd.apple.mpegurl")
        return try await server.serve("/hls.html", html: page(playlist, title: "The sweep, an HLS stream"))
    }

    /// Another site's page with a YouTube player in it, as an embed is
    /// written: the player's own frame, cross-origin.
    func embedding(_ video: String) async throws -> URL {
        try await server.serve("/embed.html", html: """
            <!doctype html>
            <meta charset="utf-8">
            <title>A YouTube player on another site</title>
            <body style="margin:0">
            <iframe width="640" height="360" src="https://www.youtube.com/embed/\(video)?start=60"
                    title="YouTube video player" frameborder="0"
                    allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture; web-share"
                    referrerpolicy="strict-origin-when-cross-origin" allowfullscreen></iframe>
            """)
    }
}
