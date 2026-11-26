// Adapted from Watchdog.swift in Yab (https://github.com/yetanotherbrowser/yab), Apache License 2.0, Copyright 2026 Serafim Korablev; changed for Nerda.
import Darwin
import Foundation
import Synchronization

/// Where the main thread stopped: every stop of 100 ms or more kept in the
/// record (Recorder.hitch), and every stall of a second or more written,
/// with where the main thread was, to a short log in the data folder
/// (stalls.log), which a feedback report carries (Feedback.diagnostics).
/// The log stays on the Mac otherwise.
///
/// The main run loop is watched from inside, by an observer that notes the
/// time at each step of its pass: a step 100 ms or more after the one
/// before it, with no sleep between them, is a hitch, measured whole, and
/// one of a second or more a stall. While the loop is awake a kernel timer
/// is set a second after its last step, with almost no leeway, and moved
/// on as the loop steps; it is taken off as the loop goes to sleep. So a
/// loop that keeps moving, however busy, never lets it fire, nor does a
/// loop asleep: it fires only a second into a stall, and then the stall is
/// written down at once with the main thread's stack, so even a stall that
/// ends with Nerda forced to quit leaves its line. Setting the timer is a
/// call into the kernel and wakes nothing: the thread waiting on it sleeps
/// until it fires.
///
/// The one Nerda runs is started once, from main.swift: never in tests,
/// which would write to the development build's data folder, and make
/// watchdogs of their own instead. `NERDA_RECORDER=0` leaves it off.
nonisolated final class Watchdog: Sendable {
    /// A stall this long is written down.
    static let threshold: TimeInterval = 1

    static var file: URL { Edition.folder.appending(path: "stalls.log") }

    /// Nerda's own, once started.
    @MainActor private static var running: Watchdog?

    /// Once, on the main thread, at launch.
    @MainActor static func start() {
        guard running == nil, Speedups.isOn(.recorder) else { return }
        let watchdog = Watchdog(file: file, recorder: .shared)
        watchdog.start()
        running = watchdog
    }

    /// Where this one writes.
    let file: URL
    private let recorder: Recorder

    init(file: URL, recorder: Recorder) {
        self.file = file
        self.recorder = recorder
    }

    // The watched thread (the main one in Nerda) writes these at each step
    // of its loop, and the watching thread reads them.
    /// The last step, in mach ticks; 0 before the first.
    private let last = Atomic<UInt64>(0)
    /// The loop is asleep after its last step.
    private let asleep = Atomic<Bool>(true)
    /// The step a stall the watching thread wrote down began at.
    private let told = Atomic<UInt64>(0)
    /// When the timer was last set, in mach ticks; 0 while it is off. The
    /// watched thread's alone.
    private let setAt = Atomic<UInt64>(0)
    /// How many times the timer fired.
    private let fired = Atomic<Int>(0)
    /// The watched thread (the main one in Nerda), set before the watching
    /// thread starts.
    private let watched = Atomic<UInt32>(0)

    /// The times the timer fired: each a second into a stall.
    var wakes: Int { fired.load(ordering: .relaxed) }

    /// The kernel queue the timer is on, which the watching thread waits on.
    private let events = kqueue()
    private static let (timerEvent, stopEvent) = (UInt(1), UInt(2))
    /// The log, written in order off the main thread.
    private let queue = DispatchQueue(label: "nerda.watchdog", qos: .utility)
    /// Set as it starts, on the watched thread: its loop, which `stop()`
    /// takes the observer off from any thread, and what hears each hitch.
    private nonisolated(unsafe) var observer: CFRunLoopObserver?
    private nonisolated(unsafe) var loop: CFRunLoop?
    private nonisolated(unsafe) var hitched: (TimeInterval) -> Void = { _ in }

    /// Seconds in a mach tick.
    private static let ticks: Double = {
        var base = mach_timebase_info_data_t()
        mach_timebase_info(&base)
        return Double(base.numer) / Double(base.denom) / 1e9
    }()
    private static let limit = UInt64(threshold / ticks)
    private static let hitchLimit = UInt64(Recorder.hitchThreshold / ticks)
    /// Steps closer than this to the timer's setting leave it as set, a
    /// little later than a second, so a pass's few steps set it once.
    private static let slack: TimeInterval = 0.01
    private static let slackTicks = UInt64(slack / ticks)

    /// Watches the main loop, from the main thread, its hitches kept in
    /// the record.
    @MainActor func start() {
        start { [recorder] seconds in
            MainActor.assumeIsolated { recorder.hitch(seconds) }
        }
    }

    /// Watches the run loop of the thread this is called on: the main one
    /// in Nerda; in tests, a thread of the test's own, so that the stalls
    /// it makes hold up no other test. `hitch` hears each hitch, on that
    /// thread.
    func start(hitch: @escaping (TimeInterval) -> Void) {
        guard events >= 0, observer == nil else { return }
        let loop = CFRunLoopGetCurrent()
        watched.store(pthread_mach_thread_np(pthread_self()), ordering: .releasing)
        hitched = hitch
        let thread = Thread { [self] in watch() }
        thread.name = "nerda.watchdog"
        thread.qualityOfService = .utility
        thread.start()
        // The steps a pass has between its sleeps, and the sleep itself:
        // entering and leaving a loop inside one adds nothing to measure.
        let steps: CFRunLoopActivity = [.afterWaiting, .beforeTimers, .beforeSources, .beforeWaiting]
        let made = CFRunLoopObserverCreateWithHandler(nil, steps.rawValue, true, Int.max) { [self] _, activity in
            step(going: activity == .beforeWaiting)
        }
        CFRunLoopAddObserver(loop, made, .commonModes)
        observer = made
        self.loop = loop
    }

    /// Stops watching, for tests.
    func stop() {
        guard let made = observer, let loop else { return }
        observer = nil
        CFRunLoopRemoveObserver(loop, made, .commonModes)
        change(Self.timerEvent, filter: EVFILT_TIMER, flags: EV_DELETE)
        change(Self.stopEvent, filter: EVFILT_USER, flags: EV_ADD | EV_ONESHOT, fflags: NOTE_TRIGGER)
    }

    /// Each step of the watched loop's pass, on its thread.
    private func step(going: Bool) {
        let now = mach_absolute_time()
        let was = last.load(ordering: .relaxed), wasAsleep = asleep.load(ordering: .relaxed)
        last.store(now, ordering: .releasing)
        asleep.store(going, ordering: .releasing)
        if !wasAsleep, was > 0, now > was, now - was >= Self.hitchLimit {
            let seconds = Double(now - was) * Self.ticks
            hitched(seconds)
            if now - was >= Self.limit { queue.async { [self] in ended(seconds, began: was) } }
        }
        let set = setAt.load(ordering: .relaxed)
        if going {
            guard set != 0 else { return }
            setAt.store(0, ordering: .relaxed)
            change(Self.timerEvent, filter: EVFILT_TIMER, flags: EV_DELETE)
        } else if set == 0 || now - set >= Self.slackTicks {
            setAt.store(now, ordering: .relaxed)
            // A second after this step, and the slack a later step in it
            // may have left the timer as it was.
            let microseconds = Int((Self.threshold + Self.slack) * 1e6)
            change(Self.timerEvent, filter: EVFILT_TIMER, flags: EV_ADD | EV_ONESHOT,
                   fflags: NOTE_USECONDS | NOTE_CRITICAL, data: microseconds)
        }
    }

    private func change(_ ident: UInt, filter: Int32, flags: Int32, fflags: Int32 = 0, data: Int = 0) {
        var event = kevent(ident: ident, filter: Int16(filter), flags: UInt16(flags), fflags: UInt32(fflags), data: data, udata: nil)
        _ = kevent(events, &event, 1, nil, 0, nil)
    }

    /// The watching thread: asleep in the kernel until the timer fires, a
    /// second into a stall.
    private func watch() {
        change(Self.stopEvent, filter: EVFILT_USER, flags: EV_ADD | EV_CLEAR)
        var event = kevent()
        while true {
            let got = kevent(events, nil, 0, &event, 1, nil)
            if got < 0, errno == EINTR { continue }
            guard got == 1, event.ident == Self.timerEvent else { break }
            fired.add(1, ordering: .relaxed)
            stalling()
        }
        close(events)
    }

    /// A second after the watched loop's last step, with no sleep since.
    private func stalling() {
        let now = mach_absolute_time()
        let stepped = last.load(ordering: .acquiring)
        // It stepped or went to sleep just as the timer fired.
        guard !asleep.load(ordering: .acquiring), stepped > 0, now > stepped, now - stepped >= Self.limit,
              told.load(ordering: .relaxed) != stepped else { return }
        told.store(stepped, ordering: .relaxed)
        let stack = Self.stack(of: watched.load(ordering: .acquiring))
        let line = String(format: "%@  stalling %.1f s so far\n", Self.stamp(), Double(now - stepped) * Self.ticks) + stack
        queue.async { [self] in write(line) }
    }

    private func ended(_ seconds: Double, began: UInt64) {
        let seen = told.load(ordering: .relaxed) == began
        write(String(format: "%@  stall %.1f s%@\n", Self.stamp(), seconds, seen ? "" : " (ended before it was looked at)"))
    }

    private static func stamp(_ at: Date = Date()) -> String {
        Date.ISO8601FormatStyle().format(at)
    }

    /// Appended, the file kept to its last 32 KB once past 64. The throwing
    /// FileHandle calls only: the old `write(_:)` raises an Objective-C
    /// exception when the disk is full or the file is gone.
    private func write(_ text: String) {
        let data = Data(text.utf8)
        let log = file
        if let handle = try? FileHandle(forWritingTo: log) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            let size = (try? handle.offset()) ?? 0
            try? handle.close()
            if size > 64 * 1024, let all = try? Data(contentsOf: log) {
                var kept = all.suffix(32 * 1024)
                if let line = kept.firstIndex(of: UInt8(ascii: "\n")) { kept = kept[(line + 1)...] }
                try? Data(kept).write(to: log, options: .atomic)
            }
        } else {
            try? data.write(to: log)
        }
    }

    /// The newest `bytes` of the log, from the start of a line, for a
    /// feedback report; nil with nothing logged.
    static func recent(_ bytes: Int, in file: URL = Watchdog.file) -> String? {
        guard let data = try? Data(contentsOf: file), !data.isEmpty else { return nil }
        var kept = data.suffix(bytes)
        if kept.count < data.count, let line = kept.firstIndex(of: UInt8(ascii: "\n")) { kept = kept[(line + 1)...] }
        return kept.isEmpty ? nil : String(decoding: kept, as: UTF8.self)
    }

    // MARK: - the watched thread's stack

    /// The watched thread held for the few microseconds it takes to follow
    /// its frame pointers, then each address named from outside: the binary,
    /// the offset `./symbolicate.sh` reads, and the symbol where there is one.
    private static func stack(of port: thread_act_t) -> String {
        #if arch(arm64)
        guard port != 0, port != pthread_mach_thread_np(pthread_self()) else { return "" }
        // Allocated before the thread is held: it may hold the allocator's lock.
        let frames = UnsafeMutablePointer<UInt>.allocate(capacity: 64)
        defer { frames.deallocate() }
        var count = 0
        guard thread_suspend(port) == KERN_SUCCESS else { return "" }
        var registers = arm_thread_state64_t()
        var size = mach_msg_type_number_t(MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<natural_t>.size)
        let got = withUnsafeMutablePointer(to: &registers) {
            $0.withMemoryRebound(to: natural_t.self, capacity: Int(size)) {
                thread_get_state(port, thread_state_flavor_t(ARM_THREAD_STATE64), $0, &size)
            }
        }
        if got == KERN_SUCCESS {
            let strip: UInt = 0x0000_7FFF_FFFF_FFFF
            frames[0] = UInt(registers.__pc) & strip
            frames[1] = UInt(registers.__lr) & strip
            count = 2
            var fp = UInt(registers.__fp)
            var pair: (UInt, UInt) = (0, 0)
            while count < 64, fp != 0, fp & 7 == 0 {
                var read: mach_vm_size_t = 0
                let ok = withUnsafeMutablePointer(to: &pair) {
                    mach_vm_read_overwrite(mach_task_self_, mach_vm_address_t(fp), 16, mach_vm_address_t(UInt(bitPattern: $0)), &read)
                }
                guard ok == KERN_SUCCESS, read == 16, pair.1 != 0 else { break }
                frames[count] = pair.1 & strip
                count += 1
                // Frames go up the stack; one that doesn't is the end.
                guard pair.0 > fp else { break }
                fp = pair.0
            }
        }
        thread_resume(port)
        var lines = ""
        for index in 0..<count {
            let address = frames[index]
            var info = Dl_info()
            if dladdr(UnsafeRawPointer(bitPattern: address), &info) != 0, let path = info.dli_fname {
                let image = (String(cString: path) as NSString).lastPathComponent
                let offset = address - UInt(bitPattern: info.dli_fbase)
                let name = info.dli_sname.map { String(cString: $0) } ?? ""
                lines += String(format: "    %2d %@ +0x%lx %@\n", index, image, offset, name)
            } else {
                lines += String(format: "    %2d 0x%lx\n", index, address)
            }
        }
        return lines
        #else
        return ""
        #endif
    }
}
