// Adapted from Watchdog.swift in Yab (https://github.com/yetanotherbrowser/yab), Apache License 2.0, Copyright 2026 Serafim Korablev; changed for Nerda.
import Darwin
import Foundation

/// Where the main thread stopped: every stop of 100 ms or more kept in the
/// record (Recorder.hitch), and every stall of a second or more written,
/// with where the main thread was, to a short log in the data folder
/// (stalls.log), which a feedback report carries (Feedback.diagnostics).
/// The log stays on the Mac otherwise.
///
/// Nothing here wakes the main thread. The main run loop is watched from
/// inside, by an observer that notes the time at each step of its pass: a
/// step 100 ms or more after the one before it, with no sleep between them,
/// is a hitch, measured whole, and one of a second or more a stall. A
/// timer on a queue of its own is set as the loop wakes, if it isn't set
/// already, and fires a second later, with a second's leeway for the system
/// to fold it into other wakes. If the loop has slept since, it is left
/// unset until the next wake; if the loop is awake and has moved, it is set
/// again for a second after the last step; if it hasn't moved, the stall is
/// still going on, and is written down at once with the main thread's
/// stack, so a stall that ends with Nerda forced to quit still leaves its
/// line. So the timer fires at most once a second, and only in a second
/// Nerda was awake in.
///
/// Started once, from main.swift: never in tests, which would write to the
/// development build's data folder. `NERDA_RECORDER=0` leaves it off.
enum Watchdog {
    /// A stall this long is written down.
    nonisolated static let threshold: TimeInterval = 1

    nonisolated static var file: URL { Edition.folder.appending(path: "stalls.log") }

    /// Four words the main thread writes at every step of its loop and the
    /// timer reads: the last step, in mach ticks; 1 while the loop sleeps
    /// after it; the step a stall the timer wrote down began at; 1 while the
    /// timer is set. Plain words, not behind a lock: each is written whole,
    /// a step is a few loads and stores, and a word read a moment stale
    /// costs the timer one more look, never a wrong stall.
    private nonisolated(unsafe) static let words: UnsafeMutablePointer<UInt64> = {
        let words = UnsafeMutablePointer<UInt64>.allocate(capacity: 4)
        words.initialize(repeating: 0, count: 4)
        words[1] = 1
        return words
    }()
    private nonisolated static let (last, asleep, told, armed) = (0, 1, 2, 3)

    private nonisolated static let queue = DispatchQueue(label: "nerda.watchdog", qos: .utility)
    private nonisolated(unsafe) static var timer: DispatchSourceTimer?
    private static var observer: CFRunLoopObserver?
    private nonisolated(unsafe) static var main: thread_act_t = 0
    /// Seconds in a mach tick.
    private nonisolated static let ticks: Double = {
        var base = mach_timebase_info_data_t()
        mach_timebase_info(&base)
        return Double(base.numer) / Double(base.denom) / 1e9
    }()
    private nonisolated static let limit = UInt64(threshold / ticks)
    private static let hitchLimit = UInt64(Recorder.hitchThreshold / ticks)

    /// Once, on the main thread, at launch.
    static func start() {
        guard observer == nil, Speedups.isOn("RECORDER") else { return }
        main = pthread_mach_thread_np(pthread_self())
        let timer = DispatchSource.makeTimerSource(flags: [], queue: queue)
        timer.setEventHandler { @Sendable in fired() }
        timer.schedule(deadline: .distantFuture, leeway: .seconds(1))
        timer.resume()
        self.timer = timer
        // The steps a pass has between its sleeps, and the sleep itself:
        // entering and leaving a loop inside one adds nothing to measure.
        let steps: CFRunLoopActivity = [.afterWaiting, .beforeTimers, .beforeSources, .beforeWaiting]
        let observer = CFRunLoopObserverCreateWithHandler(nil, steps.rawValue, true, Int.max) { _, activity in
            MainActor.assumeIsolated { step(going: activity == .beforeWaiting) }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        self.observer = observer
    }

    /// Each step of the main loop's pass, on the main thread.
    private static func step(going: Bool) {
        let now = mach_absolute_time()
        let was = words[last], wasAsleep = words[asleep] == 1
        words[last] = now
        words[asleep] = going ? 1 : 0
        if !wasAsleep, was > 0, now > was, now - was >= hitchLimit {
            let seconds = Double(now - was) * ticks
            Recorder.shared.hitch(seconds)
            if now - was >= limit { queue.async { ended(seconds, began: was) } }
        }
        if !going, words[armed] == 0 {
            words[armed] = 1
            timer?.schedule(deadline: .now() + threshold, leeway: .seconds(1))
        }
    }

    /// On the queue, a second after the loop woke with the timer unset.
    private nonisolated static func fired() {
        let now = mach_absolute_time()
        let stepped = words[last]
        // Asleep: nothing to watch until it wakes and sets it again.
        guard words[asleep] == 0, stepped > 0 else {
            words[armed] = 0
            return
        }
        let since = now > stepped ? now - stepped : 0
        guard since >= limit else {
            // Busy, but moving: looked at again a second after its last step.
            timer?.schedule(deadline: .now() + threshold - Double(since) * ticks, leeway: .seconds(1))
            return
        }
        // Stuck. Written down once, now, with where it is; the next step,
        // the stall's end, sets the timer again.
        guard words[told] != stepped else { return }
        words[told] = stepped
        words[armed] = 0
        let stack = mainStack()
        write(String(format: "%@  stalling %.1f s so far\n", stamp(), Double(since) * ticks) + stack)
    }

    private nonisolated static func ended(_ seconds: Double, began: UInt64) {
        let seen = words[told] == began
        write(String(format: "%@  stall %.1f s%@\n", stamp(), seconds, seen ? "" : " (ended before it was looked at)"))
    }

    /// A line of Nerda's own beside the stalls, for the next report: what
    /// it did about a page that stopped answering, say.
    nonisolated static func note(_ line: String) {
        let at = Date()
        queue.async { write("\(stamp(at))  \(line)\n") }
    }

    /// One formatter, used on the queue alone.
    private nonisolated(unsafe) static let stamps = ISO8601DateFormatter()

    private nonisolated static func stamp(_ at: Date = Date()) -> String { stamps.string(from: at) }

    /// Appended, the file kept to its last 32 KB once past 64. The throwing
    /// FileHandle calls only: the old `write(_:)` raises an Objective-C
    /// exception when the disk is full or the file is gone.
    private nonisolated static func write(_ text: String) {
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
    nonisolated static func recent(_ bytes: Int) -> String? {
        guard let data = try? Data(contentsOf: file), !data.isEmpty else { return nil }
        var kept = data.suffix(bytes)
        if kept.count < data.count, let line = kept.firstIndex(of: UInt8(ascii: "\n")) { kept = kept[(line + 1)...] }
        return kept.isEmpty ? nil : String(decoding: kept, as: UTF8.self)
    }

    // MARK: - the main thread's stack

    /// The main thread held for the few microseconds it takes to follow its
    /// frame pointers, then each address named from outside: the binary,
    /// the offset `./symbolicate.sh` reads, and the symbol where there is one.
    private nonisolated static func mainStack() -> String {
        #if arch(arm64)
        let port = main
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
