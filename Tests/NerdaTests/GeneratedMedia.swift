import AVFoundation
import Foundation

/// The sound generated media carries, quiet of itself (`level`): a second
/// guard beside the volume a page plays it at (`MediaTestBed.inaudible`).
enum GeneratedSound: Sendable, Hashable {
    /// A sine at `hertz`.
    case tone(hertz: Double)

    /// The loudest the sound goes, of full scale: −20 dB.
    static let level = 0.1

    /// The sound at `seconds` into the media, from −`level` to `level`.
    func sample(at seconds: Double) -> Double {
        switch self {
        case .tone(let hertz): Self.level * sin(2 * .pi * hertz * seconds)
        }
    }
}

/// Media made as a test runs, never checked in and never fetched: a movie
/// of `seconds` with a picture that tells its frame (`GeneratedMovie.frame`)
/// and the sound asked for.
enum GeneratedMovie {
    static let width = 320, height = 180, framesPerSecond = 30, sampleRate = 48_000

    /// The frame number in the picture: 16 squares across the top, 20
    /// points each, white for a 1, black for a 0, the lowest bit first, on
    /// grey. A page can read it back from a canvas to tell which frame shows.
    static let frameBits = 16, frameSquare = 20

    /// An MP4 (H.264 and AAC) with its index at the front, as a page fetches
    /// one bit by bit. Made on a queue of its own, off the main thread and
    /// off Swift's shared threads, which the writer would otherwise hold.
    static func mp4(seconds: Double, sound: GeneratedSound) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue(label: "GeneratedMovie").async {
                continuation.resume(with: Result { try write(seconds: seconds, sound: sound) })
            }
        }
    }

    private static func write(seconds: Double, sound: GeneratedSound) throws -> Data {
        let file = FileManager.default.temporaryDirectory.appending(path: "generated-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: file) }
        let writer = try AVAssetWriter(outputURL: file, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        try write(seconds: seconds, sound: sound, with: writer)
        return try Data(contentsOf: file)
    }

    /// Picture and sound for `seconds` through `writer`, finished, on the
    /// caller's thread; `compression` adds to the picture's settings.
    static func write(seconds: Double, sound: GeneratedSound, with writer: AVAssetWriter,
                              compression: [String: Any] = [:]) throws {
        var videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
        ]
        if !compression.isEmpty { videoSettings[AVVideoCompressionPropertiesKey] = compression }
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000,
        ])
        for input in [video, audio] {
            input.expectsMediaDataInRealTime = false
            writer.add(input)
        }
        let pictures = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)

        // Picture and sound each fed as the writer takes more of it, on a
        // queue of its own: the writer holds one back until the other has
        // caught up, so fed by turns from one loop, the two wait on each other.
        let frames = Int(seconds * Double(framesPerSecond)), perFrame = sampleRate / framesPerSecond
        let picture = Feed(video, count: frames) { frame in
            guard let pool = pictures.pixelBufferPool else { return false }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { return false }
            draw(frame, into: buffer)
            return pictures.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(framesPerSecond)))
        }
        let tone = Feed(audio, count: frames) { frame in
            let first = frame * perFrame
            let samples = (first..<first + perFrame).map { Int16(sound.sample(at: Double($0) / Double(sampleRate)) * Double(Int16.max)) }
            guard let buffer = try? soundBuffer(samples, at: first) else { return false }
            return audio.append(buffer)
        }
        // Should an append fail, the writer stops asking the other input for
        // more: bounded, so a failing writer fails the test, not hangs it.
        let fed = DispatchGroup()
        for feed in [picture, tone] { feed.start(in: fed) }
        guard fed.wait(timeout: .now() + 60) == .success, writer.status == .writing else {
            writer.cancelWriting()
            throw writer.error ?? CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "The movie was never written"])
        }
        let finished = DispatchSemaphore(value: 0)
        writer.finishWriting { finished.signal() }
        guard finished.wait(timeout: .now() + 60) == .success else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "The movie never finished"])
        }
        guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }

    /// One input of the writer fed `count` pieces, `append` making and
    /// appending each, as fast as the writer takes them; finished when all
    /// are in or one fails. Its state is only touched on its own queue.
    private final class Feed: @unchecked Sendable {
        let input: AVAssetWriterInput
        let count: Int
        let append: (Int) -> Bool
        private var next = 0
        private let queue = DispatchQueue(label: "GeneratedMovie.Feed")

        init(_ input: AVAssetWriterInput, count: Int, append: @escaping (Int) -> Bool) {
            self.input = input
            self.count = count
            self.append = append
        }

        func start(in group: DispatchGroup) {
            group.enter()
            input.requestMediaDataWhenReady(on: queue) { [self] in
                guard next < count else { return }
                while input.isReadyForMoreMediaData, next < count {
                    let appended = append(next)
                    next = appended ? next + 1 : count
                    guard next == count else { continue }
                    input.markAsFinished()
                    group.leave()
                }
            }
        }
    }

    /// Grey, then the frame's squares row by row: a test build does every
    /// pixel of a minute of frames one by one far too slowly.
    private static func draw(_ frame: Int, into picture: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(picture, [])
        defer { CVPixelBufferUnlockBaseAddress(picture, []) }
        let row = CVPixelBufferGetBytesPerRow(picture)
        let pixels = CVPixelBufferGetBaseAddress(picture)!
        memset(pixels, 128, row * height)
        for y in 0..<frameSquare {
            for bit in 0..<frameBits {
                memset(pixels + y * row + bit * frameSquare * 4, frame >> bit & 1 == 1 ? 255 : 0, frameSquare * 4)
            }
        }
    }

    /// Mono 16-bit samples as the writer takes sound, starting `at` samples in.
    private static func soundBuffer(_ samples: [Int16], at first: Int) throws -> CMSampleBuffer {
        var description = AudioStreamBasicDescription(
            mSampleRate: Double(sampleRate), mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
        var format: CMAudioFormatDescription?
        try check(CMAudioFormatDescriptionCreate(allocator: nil, asbd: &description, layoutSize: 0, layout: nil,
                                                 magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format))
        let length = samples.count * 2
        var block: CMBlockBuffer?
        try check(CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: length, blockAllocator: nil,
                                                     customBlockSource: nil, offsetToData: 0, dataLength: length,
                                                     flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block))
        try samples.withUnsafeBytes {
            try check(CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: length))
        }
        var buffer: CMSampleBuffer?
        try check(CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block!, formatDescription: format!, sampleCount: samples.count,
            presentationTimeStamp: CMTime(value: CMTimeValue(first), timescale: CMTimeScale(sampleRate)),
            packetDescriptions: nil, sampleBufferOut: &buffer))
        return try requireNotNil(buffer)
    }

    private static func check(_ status: OSStatus) throws {
        guard status == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
}

/// `value`, or an error saying it was missing: for the writer's own
/// optionals, on a queue where a test's `#require` can't be used.
private func requireNotNil<T>(_ value: T?, _ what: String = "\(T.self)") throws -> T {
    guard let value else { throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "No \(what)"]) }
    return value
}
