import CoreGraphics
import CoreMedia
import Darwin
import Foundation
import ScreenCaptureKit
import Synchronization

/// Whether sound may be recorded here, and why not.
public enum SoundRecording {
    /// The system's permission to record the screen and the sound of apps
    /// ("Screen & System Audio Recording" in Privacy & Security), as this
    /// process has it. It belongs to the app this process runs from, such
    /// as the terminal: a test run started there uses that app's.
    public enum Permission: Sendable, Equatable {
        case granted, denied, notAsked
        /// The system didn't say, its private call being gone.
        case unknown

        /// Read without asking: never puts the system's question on screen.
        /// Granted or not from the public call; denied or never asked from
        /// the private one, when it is there.
        public static var current: Permission {
            if CGPreflightScreenCaptureAccess() { return .granted }
            guard let tcc = dlopen("/System/Library/PrivateFrameworks/TCC.framework/TCC", RTLD_LAZY),
                  let preflight = dlsym(tcc, "TCCAccessPreflight")
            else { return .unknown }
            typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int32
            return switch unsafeBitCast(preflight, to: Preflight.self)("kTCCServiceScreenCapture" as CFString, nil) {
            case 1: .denied
            case 2: .notAsked
            default: .unknown
            }
        }
    }

    /// Why a recording can't be made.
    public struct Unavailable: Error, CustomStringConvertible {
        public var description: String
    }

    /// The switch that asks a test run to record: `NERDA_RECORD_SOUND=1`.
    public static let switchName = "NERDA_RECORD_SOUND"

    /// Why a test that records is skipped: not asked for in `environment`,
    /// or `permission` missing, which is only read once asked for. Nil when
    /// it records.
    public static func skipped(environment: [String: String] = ProcessInfo.processInfo.environment,
                               permission: () -> Permission = { .current }) -> String? {
        guard environment[switchName] == "1" else { return "Sound is recorded only when asked for, with \(switchName)=1" }
        return refusal(permission())?.description
    }

    static func refusal(_ permission: Permission) -> Unavailable? {
        let app = responsibleApp.map { "\($0), the app this runs from," } ?? "the app this runs from"
        let missing = switch permission {
        case .granted: String?.none
        case .denied: "\(app) was denied Screen Recording"
        case .notAsked: "\(app) has not been asked for Screen Recording"
        case .unknown: "the system didn't say whether \(app) may use Screen Recording"
        }
        return missing.map { Unavailable(description: "No sound recorded: \($0)") }
    }

    /// The app the system holds responsible for this process, by name:
    /// the one whose permission it uses.
    static var responsibleApp: String? {
        typealias Responsible = @convention(c) (pid_t) -> pid_t
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
        let pid = unsafeBitCast(symbol, to: Responsible.self)(getpid())
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
        let components = URL(fileURLWithPath: String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)).pathComponents
        return components.last { $0.hasSuffix(".app") }.map { String($0.dropLast(4)) } ?? components.last
    }
}

/// The sound an app plays, recorded with the system's screen capture as
/// the app plays it: mono, 48,000 samples a second. Screen capture takes an
/// app's sound with the sound of the processes working for it, WebKit's GPU
/// process among them, so what every page of the app plays is recorded
/// together. It can't keep the sound from the speakers: what is recorded is
/// heard, so a page recorded plays at a volume nobody hears (the bed's
/// 0.001, −80 dB).
///
/// Made only with the permission (`SoundRecording.Permission`); without it
/// no call to screen capture is made at all, and it throws why.
public final class SoundRecorder: NSObject, SCStreamOutput, @unchecked Sendable {
    /// Samples a second.
    public let rate = 48_000.0
    private let stream: SCStream
    private let queue = DispatchQueue(label: "SoundRecorder")
    private let recorded = Recorded()

    /// The samples so far, and where screen capture's own delivery broke,
    /// added to on the recorder's queue.
    private final class Recorded: Sendable {
        struct State {
            var samples: [Float] = []
            /// Where the last buffer's sound ended, by its timestamps.
            var next: CMTime?
            var sounding = false
            var breaks: [Double] = []
        }
        let state = Mutex(State())
    }

    private init(_ stream: SCStream) { self.stream = stream }

    /// Starts recording the sound of the app whose process is `app`, with
    /// the processes working for it.
    public static func start(app: pid_t = getpid(), permission: SoundRecording.Permission = .current) async throws -> SoundRecorder {
        if let refusal = SoundRecording.refusal(permission) { throw refusal }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let application = content.applications.first(where: { $0.processID == app }) else {
            throw SoundRecording.Unavailable(description: "No sound recorded: screen capture knows no app with process \(app)")
        }
        guard let display = content.displays.first else {
            throw SoundRecording.Unavailable(description: "No sound recorded: screen capture knows no display")
        }
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.captureMicrophone = false
        configuration.excludesCurrentProcessAudio = false
        configuration.sampleRate = 48_000
        configuration.channelCount = 1
        // The picture isn't wanted: the least of it, as seldom as allowed.
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.showsCursor = false
        let stream = SCStream(filter: SCContentFilter(display: display, including: [application], exceptingWindows: []),
                              configuration: configuration, delegate: nil)
        let recorder = SoundRecorder(stream)
        try stream.addStreamOutput(recorder, type: .audio, sampleHandlerQueue: recorder.queue)
        try await stream.startCapture()
        return recorder
    }

    /// Stops recording, and gives what was recorded.
    public func stop() async throws -> [Float] {
        try await stream.stopCapture()
        return recorded.state.withLock { $0.samples }
    }

    /// Where, in seconds into the recording, screen capture's delivery left
    /// sound out or gave it twice, by its timestamps, once sound had come:
    /// a fault there is the recording's, not the page's. Its first buffers,
    /// all silence, may be stamped apart from the rest.
    public var breaks: [Double] { recorded.state.withLock { $0.breaks } }

    /// How many seconds are recorded so far.
    public var seconds: Double { recorded.state.withLock { Double($0.samples.count) } / rate }

    /// How many seconds are recorded since the first sound: screen capture
    /// gives silence for its first tenth of a second or so, before the
    /// app's sound reaches it (measured 2026-11-27: 0.07–0.16 s).
    public var heard: Double {
        recorded.state.withLock { state in
            guard let first = state.samples.firstIndex(where: { $0 != 0 }) else { return 0 }
            return Double(state.samples.count - first) / rate
        }
    }

    public func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, buffer.isValid, let samples = Self.mono(buffer) else { return }
        let time = buffer.presentationTimeStamp, length = CMTime(value: CMTimeValue(samples.count), timescale: CMTimeScale(rate))
        recorded.state.withLock { state in
            if state.sounding, let next = state.next, abs((time - next).seconds) > 0.001 {
                state.breaks.append(Double(state.samples.count) / rate)
            }
            state.sounding = state.sounding || samples.contains { $0 != 0 }
            state.next = time + length
            state.samples += samples
        }
    }

    /// The buffer's sound as one channel of floats: its channels averaged.
    private static func mono(_ buffer: CMSampleBuffer) -> [Float]? {
        guard let format = buffer.formatDescription?.audioStreamBasicDescription,
              format.mFormatID == kAudioFormatLinearPCM, format.mFormatFlags & kAudioFormatFlagIsFloat != 0, format.mBitsPerChannel == 32
        else { return nil }
        let frames = CMSampleBufferGetNumSamples(buffer)
        var samples = [Float](repeating: 0, count: frames)
        do {
            try buffer.withAudioBufferList { list, _ in
                let interleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
                var channels = 0
                for audio in list {
                    guard let data = audio.mData?.assumingMemoryBound(to: Float.self) else { continue }
                    let inBuffer = interleaved ? Int(audio.mNumberChannels) : 1
                    for frame in 0..<min(frames, Int(audio.mDataByteSize) / 4 / inBuffer) {
                        for channel in 0..<inBuffer { samples[frame] += data[frame * inBuffer + channel] }
                    }
                    channels += inBuffer
                }
                if channels > 1 { for index in samples.indices { samples[index] /= Float(channels) } }
            }
        } catch {
            return nil
        }
        return samples
    }
}
