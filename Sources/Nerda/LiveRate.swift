import WebKit

// Live video that doesn't stutter.
//
// A live player keeps close to the broadcast by nudging its speed: X's goes
// to 1.04 when it has fallen behind and back to 1 once it has caught up,
// every few seconds for as long as you watch. In WebKit on macOS each step
// across exactly 1 costs a pause: CoreMedia plays speed 1 on a path of its
// own, and moving on or off it builds the sound anew, with the picture held
// still until the sound is back. Safari has the same pause.
//
// Between two speeds both off 1 the sound follows without a break. So once
// a page has used a catch-up speed on a video, a 1 it asks for afterwards
// is played at 1.0001, which no one can see or hear, and the page still
// reads back the 1 it asked for. A speed picked from a menu (1.25, 1.5, 2)
// never starts it, and a page that never nudges is never touched.
//
// Taken from LiveRate.swift in Search (https://github.com/driceroland/Search):
//
//   Copyright (c) 2026 Office Commun
//
//   Permission is hereby granted, free of charge, to any person obtaining a
//   copy of this software and associated documentation files (the
//   "Software"), to deal in the Software without restriction, including
//   without limitation the rights to use, copy, modify, merge, publish,
//   distribute, sublicense, and/or sell copies of the Software, and to permit
//   persons to whom the Software is furnished to do so, subject to the
//   following conditions:
//
//   The above copyright notice and this permission notice shall be included
//   in all copies or substantial portions of the Software.
//
//   THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
//   OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
//   MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN
//   NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM,
//   DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
//   OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE
//   USE OR OTHER DEALINGS IN THE SOFTWARE.

enum LiveRate {
    /// In the page's own world, in every frame, before any of the page's
    /// scripts: the player sets the speed through this very property.
    static let source = """
        (() => {
            const media = HTMLMediaElement.prototype;
            const plain = Object.getOwnPropertyDescriptor(media, 'playbackRate');
            if (!plain?.get || !plain.set) return;
            // Off 1 by this much at most: a player catching up, not a choice.
            const nudge = 0.1, beside = 1.0001;
            const nudged = new WeakSet(), asked = new WeakMap();
            const smooth = {
                get playbackRate() {
                    const now = plain.get.call(this), was = asked.get(this);
                    // Changed some other way since (the video's own controls,
                    // an extension): then what it is now is the answer.
                    return was && Math.abs(now - was.played) < 1e-9 ? was.asked : now;
                },
                set playbackRate(value) {
                    const rate = +value;
                    const played = rate === 1 && nudged.has(this) ? beside : rate;
                    // Refused (not a number, out of range): thrown, and nothing kept.
                    plain.set.call(this, played);
                    if (rate !== 1 && Math.abs(rate - 1) <= nudge) nudged.add(this);
                    if (played !== rate) asked.set(this, { asked: rate, played });
                    else asked.delete(this);
                },
            };
            const made = Object.getOwnPropertyDescriptor(smooth, 'playbackRate');
            try {
                Object.defineProperty(media, 'playbackRate', {
                    get: made.get, set: made.set, enumerable: plain.enumerable, configurable: true,
                });
            } catch {}
        })();
        """

    static let script = WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)
}
