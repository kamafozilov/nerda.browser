import AudioToolbox
import CoreAudio
import Darwin
import Foundation
import Synchronization

/// Whether sound may be recorded here, and why not.
public enum SoundRecording {
    /// The system's permission to record other apps' sound ("System Audio
    /// Recording Only" in Privacy & Security), as this process has it. It
    /// belongs to the app this process runs from, such as the terminal.
    public enum Permission: Sendable, Equatable {
        case granted, denied, notAsked
        /// The system didn't say, its private call being gone.
        case unknown

        /// Read without asking: never puts the system's question on screen.
        public static var current: Permission {
            guard let tcc = dlopen("/System/Library/PrivateFrameworks/TCC.framework/TCC", RTLD_LAZY),
                  let preflight = dlsym(tcc, "TCCAccessPreflight")
            else { return .unknown }
            typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int32
            return switch unsafeBitCast(preflight, to: Preflight.self)("kTCCServiceAudioCapture" as CFString, nil) {
            case 0: .granted
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
        case .denied: "\(app) was denied System Audio Recording"
        case .notAsked: "\(app) has not been asked for System Audio Recording"
        case .unknown: "the system didn't say whether \(app) may use System Audio Recording"
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

/// The sound some processes play, recorded with the system's process tap
/// as they play it, and kept from the speakers while it records where the
/// system allows (`mutedWhenTapped`). Mono, at the output device's rate.
///
/// A WebKit page's sound comes out of its GPU process (`WKWebView`'s
/// `_gpuProcessIdentifier`), shared by every page of the app: what all of
/// them play is recorded, and kept from the speakers, together.
///
/// Made only with the permission (`SoundRecording.Permission`); without it
/// no call to the system's sound is made at all, and it throws why.
public final class SoundRecorder: @unchecked Sendable {
    /// Samples a second.
    public let rate: Double
    private let tap: AudioObjectID, device: AudioObjectID
    private var reading: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "SoundRecorder")
    private let recorded = Recorded()

    /// The samples so far, added to on the device's queue.
    private final class Recorded: Sendable {
        let samples = Mutex<[Float]>([])
    }

    /// Starts recording what `processes` play.
    public init(processes: [pid_t], permission: SoundRecording.Permission = .current) throws {
        if let refusal = SoundRecording.refusal(permission) { throw refusal }
        let objects = try processes.map(Self.soundObject)
        let description = CATapDescription(stereoMixdownOfProcesses: objects)
        description.name = "Nerda sound check"
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped
        var tap = AudioObjectID(kAudioObjectUnknown)
        try Self.check(AudioHardwareCreateProcessTap(description, &tap), "creating the process tap")
        self.tap = tap
        var format = AudioStreamBasicDescription()
        do {
            try Self.read(tap, kAudioTapPropertyFormat, into: &format)
            guard format.mFormatID == kAudioFormatLinearPCM, format.mFormatFlags & kAudioFormatFlagIsFloat != 0, format.mBitsPerChannel == 32 else {
                throw SoundRecording.Unavailable(description: "The process tap gives sound as \(format), not 32-bit floats")
            }
        } catch {
            AudioHardwareDestroyProcessTap(tap)
            throw error
        }
        rate = format.mSampleRate
        // A private device of the tap alone, on the output device's clock.
        var output = AudioObjectID(kAudioObjectUnknown), uid: CFString = "" as CFString
        do {
            try Self.read(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultSystemOutputDevice, into: &output)
            try Self.read(output, kAudioDevicePropertyDeviceUID, into: &uid)
        } catch {
            AudioHardwareDestroyProcessTap(tap)
            throw error
        }
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Nerda sound check",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: uid as String,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: uid as String]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        var device = AudioObjectID(kAudioObjectUnknown)
        if let error = Self.failure(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device), "creating the recording device") {
            AudioHardwareDestroyProcessTap(tap)
            throw error
        }
        self.device = device
        let channels = Int(max(format.mChannelsPerFrame, 1))
        let status = AudioDeviceCreateIOProcIDWithBlock(&reading, device, queue) { [recorded] _, input, _, _, _ in
            // Interleaved floats, the channels averaged to one.
            for buffer in UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input)) {
                guard let data = buffer.mData else { continue }
                let floats = data.assumingMemoryBound(to: Float.self)
                let perBuffer = Int(buffer.mNumberChannels) > 0 ? Int(buffer.mNumberChannels) : channels
                let frames = Int(buffer.mDataByteSize) / 4 / perBuffer
                var mono = [Float](repeating: 0, count: frames)
                for frame in 0..<frames {
                    var sum: Float = 0
                    for channel in 0..<perBuffer { sum += floats[frame * perBuffer + channel] }
                    mono[frame] = sum / Float(perBuffer)
                }
                recorded.samples.withLock { $0 += mono }
                break
            }
        }
        if let error = Self.failure(status, "reading the recording device") ?? (reading == nil ? Self.failure(-1, "reading the recording device") : nil)
            ?? Self.failure(AudioDeviceStart(device, reading), "starting the recording device") {
            tear()
            throw error
        }
    }

    /// Stops recording, and gives what was recorded.
    public func stop() -> [Float] {
        tear()
        return recorded.samples.withLock { $0 }
    }

    private var torn = false

    private func tear() {
        guard !torn else { return }
        torn = true
        if let reading {
            AudioDeviceStop(device, reading)
            AudioDeviceDestroyIOProcID(device, reading)
        }
        if device != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(device) }
        AudioHardwareDestroyProcessTap(tap)
    }

    deinit { tear() }

    /// The system's sound object of the process `pid`.
    private static func soundObject(of pid: pid_t) throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var pid = pid, object = AudioObjectID(kAudioObjectUnknown), size = UInt32(MemoryLayout<AudioObjectID>.size)
        try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object),
                  "finding process \(pid)'s sound")
        guard object != kAudioObjectUnknown else {
            throw SoundRecording.Unavailable(description: "Process \(pid) has played no sound the system knows of")
        }
        return object
    }

    private static func read<Value>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, into value: inout Value) throws {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<Value>.size)
        try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value), "reading \(selector)")
    }

    private static func check(_ status: OSStatus, _ doing: String) throws {
        if let error = failure(status, doing) { throw error }
    }

    private static func failure(_ status: OSStatus, _ doing: String) -> SoundRecording.Unavailable? {
        status == noErr ? nil : SoundRecording.Unavailable(description: "The system's sound failed \(doing): \(status)")
    }
}
