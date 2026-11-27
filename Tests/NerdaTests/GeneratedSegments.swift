import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// A generated movie cut in fragmented MP4 (CMAF) segments, as a stream is
/// given out: what a Media Source page appends, and what an HLS playlist
/// lists. Picture and sound are a `GeneratedMovie`'s, muxed in each segment.
struct GeneratedSegments: Sendable {
    struct Segment: Sendable {
        var data: Data
        /// Where it starts in media time, and how long it lasts, in seconds.
        var start: Double
        var duration: Double
    }

    /// What a player reads first: the tracks and their formats (`ftyp`, `moov`).
    var initialization: Data
    var media: [Segment]
    /// The codecs as a Media Source type gives them, read from the
    /// initialization segment: `avc1.42C01E,mp4a.40.2`.
    var codecs: String

    var duration: Double { media.map(\.duration).reduce(0, +) }
}

extension GeneratedMovie {
    /// The movie of `seconds` in segments of `interval` seconds each, a key
    /// frame starting each. Made on a queue of its own, as `mp4` is.
    static func segments(seconds: Double, sound: GeneratedSound, every interval: Double = 1) async throws -> GeneratedSegments {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue(label: "GeneratedMovie").async {
                continuation.resume(with: Result { try writeSegments(seconds: seconds, sound: sound, every: interval) })
            }
        }
    }

    private static func writeSegments(seconds: Double, sound: GeneratedSound, every interval: Double) throws -> GeneratedSegments {
        let writer = AVAssetWriter(contentType: UTType(AVFileType.mp4.rawValue)!)
        writer.outputFileTypeProfile = .mpeg4AppleHLS
        writer.preferredOutputSegmentInterval = CMTime(seconds: interval, preferredTimescale: 600)
        writer.initialSegmentStartTime = .zero
        let segments = Segments()
        writer.delegate = segments
        try write(seconds: seconds, sound: sound, with: writer, compression: [
            AVVideoMaxKeyFrameIntervalKey: Int(interval * Double(framesPerSecond)),
            AVVideoAllowFrameReorderingKey: false,
            AVVideoProfileLevelKey: AVVideoProfileLevelH264BaselineAutoLevel,
        ])
        let (initialization, media) = segments.taken
        guard let initialization else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "No initialization segment"])
        }
        return GeneratedSegments(initialization: initialization, media: media, codecs: "\(try avc1(in: initialization)),mp4a.40.2")
    }

    /// `avc1.PPCCLL`: the profile, its constraints and the level, as the
    /// picture's decoder configuration (`avcC`) has them.
    private static func avc1(in initialization: Data) throws -> String {
        guard let box = initialization.range(of: Data("avcC".utf8)), initialization.count >= box.upperBound + 4 else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "No avcC in the initialization segment"])
        }
        let bytes = initialization[(box.upperBound + 1)..<(box.upperBound + 4)]
        return "avc1." + bytes.map { String(format: "%02X", $0) }.joined()
    }

    /// What the writer gives out, segment by segment, on a queue of its own.
    private final class Segments: NSObject, AVAssetWriterDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var initialization: Data?
        private var media: [GeneratedSegments.Segment] = []

        var taken: (Data?, [GeneratedSegments.Segment]) { lock.withLock { (initialization, media) } }

        func assetWriter(_ writer: AVAssetWriter, didOutputSegmentData data: Data, segmentType: AVAssetSegmentType,
                         segmentReport: AVAssetSegmentReport?) {
            lock.withLock {
                switch segmentType {
                case .initialization:
                    initialization = data
                default:
                    // The sound runs on a little past the last picture, by
                    // the AAC encoder's priming: that comes on its own at
                    // the end, and goes with the last segment.
                    guard let picture = segmentReport?.trackReports.first(where: { $0.mediaType == .video }),
                          picture.duration.seconds > 0 else {
                        if !media.isEmpty { media[media.count - 1].data += data }
                        return
                    }
                    media.append(.init(data: data, start: picture.earliestPresentationTimeStamp.seconds, duration: picture.duration.seconds))
                }
            }
        }
    }
}
