import CoreAudio
import Foundation
import Lab
import SoundCheck

/// `./lab.sh`: the lab run on the real sites. Builds Nerda Test, opens it
/// behind the windows in use with pages at a volume nobody hears, visits
/// each site signed out (SiteSpec.all), does each action to its video,
/// and writes what it found to build/lab/, a JSON file and its summary.
///
///     ./lab.sh                     every site
///     ./lab.sh --only YouTube      the sites whose name has these words
///     ./lab.sh --no-build          Nerda Test as built already
@MainActor
enum LabCommand {
    static func main() async -> Int32 {
        // Each line as it comes, into a log too.
        setvbuf(stdout, nil, _IOLBF, 0)
        let arguments = Array(CommandLine.arguments.dropFirst())
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        guard FileManager.default.fileExists(atPath: root.appending(path: "Package.swift").path) else {
            print("Run it from the repository's root, as ./lab.sh does.")
            return 2
        }
        let only = arguments.firstIndex(of: "--only").flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
        let sites = SiteSpec.all.filter { spec in only.map { spec.name.localizedCaseInsensitiveContains($0) } ?? true }

        let lock: LabLock
        do {
            lock = try LabLock.take()
        } catch {
            print(error)
            return 3
        }
        defer { lock.release() }
        let running = NerdaTest.alreadyRunning
        guard running.isEmpty else {
            print("Nerda Test is running already (process \(running.map(String.init).joined(separator: ", "))): "
                + "the lab run starts a Nerda Test of its own and quits it after. Quit that one first; this run stops here.")
            return 3
        }

        let started = Date()
        let stamp = stampFormat.string(from: started)
        let folder = root.appending(path: "build/lab", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let mac = LabRun.Mac(system: "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)", load: load(), output: output())

        if !arguments.contains("--no-build") {
            let log = folder.appending(path: "lab-\(stamp).build.log")
            FileManager.default.createFile(atPath: log.path, contents: nil)
            print("Building Nerda Test (\(log.path))…")
            guard Shell.run("/bin/bash", ["./build.sh", "test"], log: log, in: root) != nil else {
                print("Nerda Test didn't build: see \(log.path)")
                return 1
            }
        }

        let channel: Channel, media: LocalMedia
        do {
            channel = try Channel()
            media = try LocalMedia()
        } catch {
            print("The run's servers didn't start: \(error)")
            return 1
        }
        defer { channel.stop(); media.stop() }
        let nerda = NerdaTest(app: root.appending(path: "build/Nerda Test.app"), channel: channel)
        let floatingBefore = Watch.floatingWindows()
        var watch: Watch?
        var results: [LabRun.Site] = []
        var stopped: String?
        var quiet: String?
        do {
            try await nerda.start()
            let watching = Watch(pid: nerda.pid)
            watching.onBroken = { kill(nerda.pid, SIGKILL) }
            watching.floating = { (try? await nerda.send("windows", timeout: 1)) as? [Int] }
            watching.start()
            watch = watching
            nerda.watch = watching
            let refused = SoundRecording.skipped(environment: [SoundRecording.switchName: "1"])
            // Unheard first, or nothing at all: without a recording, the run can't tell.
            if let refused { throw Quiet.Loud(description: "the pages' volume can't be checked: \(refused)") }
            let (full, low) = try await Quiet.check(nerda, media)
            quiet = "Pages played unheard: the check's sweep, its element at 0.001, came out at \(Quiet.decibels(full)) of full scale "
                + "at the page's full volume and at \(Quiet.decibels(low)) at the run's page volume of 0.001."
            print(quiet ?? "")
            guard full >= Quiet.heard else {
                throw Quiet.Loud(description: "the recording didn't hear the check's sweep (\(Quiet.decibels(full))), so the pages' volume can't be shown: no site was visited")
            }
            guard low * 100 <= full else {
                throw Quiet.Loud(description: "the run's page volume didn't make the check quieter (\(Quiet.decibels(full)) and \(Quiet.decibels(low))): no site was visited")
            }
            for spec in sites {
                guard watching.broken.isEmpty, nerda.running else {
                    stopped = watching.broken.isEmpty ? "Nerda Test quit by itself" : "something came forward"
                    break
                }
                print("\(spec.name)…")
                var visit = Visit(spec: spec, nerda: nerda, media: media, soundRefused: refused)
                visit.recordings = folder.appending(path: "lab-\(stamp)", directoryHint: .isDirectory)
                let site = await visit.run()
                print("  \(site.outcome.status)\(site.outcome.reason.map { ": \($0)" } ?? "")")
                results.append(site)
            }
        } catch {
            stopped = "\(error)"
            print("Stopped: \(error)")
        }
        await nerda.quit()
        // After Nerda Test, alone: only one app's sound is recorded at a time.
        print("\(WebKitAlone.name)…")
        let alone = await WebKitAlone.compare(media, root: root, recordings: folder.appending(path: "lab-\(stamp)", directoryHint: .isDirectory))
        await watch?.check()
        watch?.stop()
        var broken = watch?.broken ?? []
        if nerda.running { broken.append("Nerda Test was still running at the end") }
        // The system's floating window goes a moment after its app.
        var floatingAfter = Watch.floatingWindows()
        for _ in 0..<30 where floatingAfter > floatingBefore {
            try? await Task.sleep(for: .milliseconds(100))
            floatingAfter = Watch.floatingWindows()
        }
        if floatingAfter > floatingBefore { broken.append("\(floatingAfter - floatingBefore) floating window(s) were left on screen") }
        if let stopped { broken.append("the run stopped early: \(stopped)") }

        let run = LabRun(started: started, ended: Date(), nerda: nerda.version, mac: mac,
                         safety: LabRun.Safety(checks: watch?.checks ?? 0, broken: broken,
                                               quiet: [quiet, watch.map { "The system's floating window was on screen in \($0.floated) of the checks, as floating a video puts it there." }]
                                                   .compactMap(\.self).joined(separator: " ")),
                         sites: results, comparisons: comparisons() + [alone])
        let file = folder.appending(path: "lab-\(stamp).json"), summary = folder.appending(path: "lab-\(stamp).md")
        do {
            try run.file().write(to: file)
            try run.summary.write(to: summary, atomically: true, encoding: .utf8)
        } catch {
            print("The result couldn't be written: \(error)")
            return 1
        }
        print(run.summary)
        print("Written: \(file.path)\n         \(summary.path)")
        return broken.isEmpty ? 0 : 1
    }

    static let stampFormat: DateFormatter = {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyyMMdd-HHmmss"
        return format
    }()

    static func load() -> [Double] {
        var loads = [Double](repeating: 0, count: 3)
        return getloadavg(&loads, 3) == 3 ? loads.map { ($0 * 100).rounded() / 100 } : []
    }

    /// The sound output in use, by its name.
    static func output() -> String? {
        var device = AudioDeviceID(0), size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else { return nil }
        var name: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        address.mSelector = kAudioObjectPropertyName
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr else { return nil }
        return name?.takeRetainedValue() as String?
    }

    /// Safari and Chrome playing the sweep across a pause and play, where
    /// they can be without coming before the owner.
    static func comparisons() -> [LabRun.Comparison] {
        let safariRunning = !NSRunningApplicationList.with("com.apple.Safari").isEmpty
        let safari = "Safari opens a private window only from its File menu or with ⇧⌘N, keys typed into Safari, which "
            + "brings it forward; its scripting dictionary has no private window, and a window of any other kind is the owner's own "
            + "Safari, with their data" + (safariRunning ? "; Safari was also running, and recording it would take in all its tabs" : "")
        let chrome = NSRunningApplicationList.installed("com.google.Chrome")
            ? "Chrome is on this Mac, but starting it unseen, with data of its own, isn't built or proven yet"
            : "Chrome isn't installed on this Mac, and the run installs nothing"
        return [
            LabRun.Comparison(browser: "Safari, private window", sound: .notMeasured(safari)),
            LabRun.Comparison(browser: "Chrome, data of its own", sound: .notMeasured(chrome)),
        ]
    }
}

exit(await LabCommand.main())
