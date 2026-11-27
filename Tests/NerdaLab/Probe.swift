import Foundation
import MediaCheck

/// The run's scripts in a page: they find the video, read its clock as the
/// media test bed does (`currentTime` against `performance.now()`, every
/// 20 ms and at each media event, taken in the page so how late the run
/// asked never enters the numbers), and do the actions to it. Each runs in
/// the lab's own content world of one frame, through `Lab.Client`'s `run`,
/// as a click would.
enum Probe {
    /// Put before every script: the helpers, made once per frame.
    static let helpers = #"""
        window.__nerdaLab ??= (() => {
            const lab = { samples: [], marks: [], video: null, timer: null, watched: new WeakSet() };
            const area = v => { const r = v.getBoundingClientRect(); return Math.round(r.width * r.height); };
            lab.videos = () => [...document.querySelectorAll('video')];
            lab.describe = () => lab.videos().map(v => ({
                area: area(v), width: v.videoWidth, height: v.videoHeight, readyState: v.readyState, paused: v.paused,
                time: v.currentTime, duration: Number.isFinite(v.duration) ? v.duration : -1, muted: v.muted, volume: v.volume,
                source: (v.currentSrc || '').split(':')[0],
            }));
            lab.pick = () => lab.videos().filter(v => v.readyState >= 1).sort((a, b) => area(b) - area(a))[0] ?? null;
            lab.sample = event => {
                const v = lab.video;
                if (v) lab.samples.push({ wall: performance.now() / 1000, media: v.currentTime, paused: v.paused, rate: v.playbackRate, event });
            };
            lab.watch = () => {
                const v = lab.pick();
                if (!v) return false;
                lab.video = v;
                if (!lab.watched.has(v)) {
                    lab.watched.add(v);
                    for (const e of ['play', 'playing', 'pause', 'seeking', 'seeked', 'ratechange', 'waiting', 'stalled', 'timeupdate', 'ended']) {
                        v.addEventListener(e, () => { if (v === lab.video) lab.sample(e); });
                    }
                }
                lab.timer ??= setInterval(() => lab.sample('tick'), 20);
                return true;
            };
            lab.mark = name => lab.marks.push({ wall: performance.now() / 1000, name });
            lab.dropped = () => { const q = lab.video?.getVideoPlaybackQuality?.(); return q ? q.droppedVideoFrames : -1; };
            lab.take = () => {
                const out = { samples: lab.samples, marks: lab.marks, dropped: lab.dropped() };
                lab.samples = [];
                lab.marks = [];
                return JSON.stringify(out);
            };
            lab.wait = seconds => new Promise(done => setTimeout(done, seconds * 1000));
            lab.until = async (what, condition, seconds = 15) => {
                const start = performance.now();
                while (!condition()) {
                    if (performance.now() - start > seconds * 1000) throw new Error(`${what} not within ${seconds} s`);
                    await lab.wait(0.02);
                }
            };
            // Media played on by `seconds`, playing.
            lab.played = async (seconds, limit = 20) => {
                const v = lab.video, from = v.currentTime;
                await lab.until(`media playing ${seconds} s on from ${from.toFixed(3)} (at ${v.currentTime.toFixed(3)}, paused ${v.paused})`,
                                () => !v.paused && v.currentTime - from >= seconds, limit);
            };
            // Held for `seconds` by the page's clock.
            lab.hold = async seconds => { const start = performance.now(); while (performance.now() - start < seconds * 1000) await lab.wait(0.01); };
            lab.state = () => {
                const v = lab.video;
                if (!v) return null;
                const seekable = v.seekable.length ? [v.seekable.start(0), v.seekable.end(v.seekable.length - 1)] : [];
                return { time: v.currentTime, paused: v.paused, rate: v.playbackRate, readyState: v.readyState, muted: v.muted,
                         volume: v.volume, duration: Number.isFinite(v.duration) ? v.duration : -1, seekable,
                         width: v.videoWidth, height: v.videoHeight, dropped: lab.dropped(), fullscreen: !!document.fullscreenElement };
            };
            return lab;
        })();
        const lab = window.__nerdaLab;

        """#

    /// `body` with the helpers before it.
    static func script(_ body: String) -> String { helpers + body }

    static let describe = script("return JSON.stringify(lab.describe());")
    static let watch = script("return lab.watch();")
    static let state = script("return JSON.stringify(lab.state());")
    static let take = script("return lab.take();")

    /// Starts the video as the owner would press play: a click on the
    /// player's own button when there is no video ready to play yet,
    /// else the element's `play()`.
    static let start = script(#"""
        const v = lab.pick();
        if (v && v.paused) { await v.play(); return 'play'; }
        if (v) return 'playing';
        const buttons = ['.ytp-large-play-button', '.ytp-play-button', '[data-testid="playButton"]', 'button[aria-label="Play"]',
                         '[data-a-target="player-play-pause-button"]', '[aria-label="Play"]'];
        for (const selector of buttons) {
            const button = document.querySelector(selector);
            if (button) { button.click(); return selector; }
        }
        return 'none';
        """#)

    /// Pressed pause and play, as the owner does, so the video is one the
    /// owner chose (the floating rule) and plays with sound.
    static let pressPauseAndPlay = script(#"""
        const v = lab.video;
        if (!v.paused) { v.pause(); await lab.until('paused', () => v.paused, 5); }
        await lab.hold(0.2);
        await v.play();
        return true;
        """#)

    static let pauseAndPlay = script(#"""
        const v = lab.video;
        lab.mark('pause');
        v.pause();
        await lab.until('paused', () => v.paused, 5);
        await lab.hold(1);
        lab.mark('play');
        await v.play();
        return true;
        """#)

    /// Ten seconds on, or back where the stream can't go on.
    static let seek = script(#"""
        const v = lab.video, s = lab.state();
        const [start, end] = s.seekable.length ? s.seekable : [0, 0];
        const target = end - s.time > 15 ? s.time + 10 : s.time - start > 15 ? s.time - 10 : null;
        if (target === null) return JSON.stringify({ skipped: `nowhere to seek to: ${start.toFixed(1)}–${end.toFixed(1)} s around ${s.time.toFixed(1)} s` });
        const seeked = new Promise(done => v.addEventListener('seeked', done, { once: true }));
        lab.mark('seek');
        v.currentTime = target;
        await seeked;
        lab.mark('seeked');
        return JSON.stringify({ target });
        """#)

    static let speed = script(#"""
        const v = lab.video;
        lab.mark('speed');
        v.playbackRate = 1.5;
        await lab.played(3);
        lab.mark('speed back');
        v.playbackRate = 1;
        return true;
        """#)

    /// The largest video's full screen, asked in the page's own world as
    /// its player's button asks: Nerda's page full screen, inside Nerda
    /// Test's window (WebKit's own, a window over the screen, is off in a
    /// lab run). Run with `world: page`, where the lab's helpers aren't.
    static let fullScreenIn = #"""
        const area = v => { const r = v.getBoundingClientRect(); return r.width * r.height; };
        const v = [...document.querySelectorAll('video')].filter(v => v.readyState >= 1).sort((a, b) => area(b) - area(a))[0];
        await v.requestFullscreen();
        const start = performance.now();
        while (!document.fullscreenElement) {
            if (performance.now() - start > 5000) throw new Error('not in full screen within 5 s');
            await new Promise(done => setTimeout(done, 20));
        }
        return true;
        """#

    static let fullScreenOut = #"""
        await document.exitFullscreen();
        const start = performance.now();
        while (document.fullscreenElement) {
            if (performance.now() - start > 5000) throw new Error('still in full screen after 5 s');
            await new Promise(done => setTimeout(done, 20));
        }
        return true;
        """#

    static func mark(_ name: String) -> String { script("lab.mark(\(json(name))); return true;") }
    static func played(_ seconds: Double, limit: Double = 20) -> String {
        script("await lab.played(\(seconds), \(limit)); return true;")
    }

    static func json(_ string: String) -> String {
        String(decoding: try! JSONEncoder().encode(string), as: UTF8.self)
    }

    /// What `take` gave: the clock, and the frames dropped by then.
    struct Taken: Decodable {
        var samples: [MediaClock.Sample]
        var marks: [MediaClock.Mark]
        var dropped: Int

        var clock: MediaClock { MediaClock(samples: samples, marks: marks) }
    }
}
