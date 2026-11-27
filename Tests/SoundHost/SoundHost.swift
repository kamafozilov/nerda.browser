// A small app whose one page plays a sound to be recorded: screen capture
// takes a page's sound with the app it plays in, and the test process is
// no app to it, so the page plays here. Built and started by the test that
// records it (`SoundHostApp`), never by `swift test` itself, and not a
// target of the package.
//
//     SoundHost <page URL> <status file>
//
// Behind the windows in use, never active, with no Dock icon. It loads the
// page, has the bed's script there (`bed`) play it as a click would, and
// writes `playing <pid> <volume>` to the status file, or `failed <why>`.
// The page sets its own volume (the bed's 0.001); this refuses to play it
// louder. It quits when told to (SIGTERM), or after two minutes.
import AppKit
import WebKit

@MainActor
final class Host: NSObject, NSApplicationDelegate, WKNavigationDelegate {
    let page: URL, status: URL
    var window: NSWindow?
    var web: WKWebView?

    init(page: URL, status: URL) {
        self.page = page
        self.status = status
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 320, height: 180), configuration: WKWebViewConfiguration())
        // Behind other windows, a page would hear itself covered and hidden,
        // and WebKit would pause its video.
        let occlusion = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
        if web.responds(to: occlusion) { web.perform(occlusion, with: false) }
        web.navigationDelegate = self
        let window = NSWindow(contentRect: web.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = web
        window.orderBack(nil)
        self.web = web
        self.window = window
        web.load(URLRequest(url: page))
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) { NSApp.terminate(nil) }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task {
            do {
                let volume = try await webView.callAsyncJavaScript("""
                    while (media.readyState < 1) await new Promise(resolve => setTimeout(resolve, 20));
                    if (media.volume > 0.001 || media.muted) throw new Error('volume ' + media.volume + (media.muted ? ', muted' : ''));
                    await bed.play();
                    return media.volume;
                    """, contentWorld: .page)
                write("playing \(getpid()) \(volume ?? "")")
            } catch {
                write("failed \(error)")
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { write("failed \(error)") }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        write("failed \(error)")
    }

    private func write(_ line: String) {
        try? line.write(to: status, atomically: true, encoding: .utf8)
    }
}

let arguments = CommandLine.arguments
guard arguments.count == 3, let page = URL(string: arguments[1]) else {
    FileHandle.standardError.write(Data("usage: SoundHost <page URL> <status file>\n".utf8))
    exit(2)
}
let host = Host(page: page, status: URL(fileURLWithPath: arguments[2]))
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.delegate = host
app.run()
