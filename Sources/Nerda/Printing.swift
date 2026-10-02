import AppKit
import WebKit

/// File › Print… (⌘P) and Export as PDF…, and a page's own Print button
/// (`window.print()`): the page laid out in pages as the Mac prints it, in a
/// sheet over its window.
extension Browser {
    /// The page on screen, in the Mac's print sheet.
    func printPage() {
        guard let page = selected?.page, let window = page.window, window.attachedSheet == nil else { return }
        Printing.run(Printing.operation(for: page), over: window)
    }

    /// The page on screen in pages, as it would print, saved as a PDF where you choose.
    func exportPDF() {
        guard let tab = selected, let page = tab.page, let window = page.window, window.attachedSheet == nil else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.directoryURL = Downloads.folder
        panel.nameFieldStringValue = Printing.fileName(for: tab.title)
        panel.beginSheetModal(for: window) { answer in
            guard answer == .OK, let file = panel.url else { return }
            let info = Printing.info()
            info.jobDisposition = .save
            info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = file
            let operation = Printing.operation(for: page, info: info)
            operation.showsPrintPanel = false
            // Once the save panel has gone: a window takes one sheet at a time.
            DispatchQueue.main.async { Printing.run(operation, over: window) }
        }
    }

    /// `window.print()`, once its tab is on screen, as a page's alert waits.
    /// The page waits for the sheet to be done, so one that closes itself
    /// once printed (a ticket, a receipt) is printed first. A frame's own
    /// print prints that frame. Once one is cancelled, the page's next is let
    /// go for 2 seconds, and after three in a row for 4, 8, then up to 32,
    /// until one prints, as Chrome lets go of too frequent ones: a page
    /// printing again each time the sheet is cancelled would never let you out.
    // WebKit SPI (WKUIDelegatePrivate), as Safari's: should it go, a page's
    // Print button does nothing, as before; File › Print… still prints.
    @objc(_webView:printFrame:pdfFirstPageSize:completionHandler:)
    func printFrame(_ page: WKWebView, frame: NSObject, pdfFirstPageSize: CGSize, completionHandler: @escaping () -> Void) {
        guard let tab = tab(for: page) else { return completionHandler() }
        if let cancels = tab.printCancels,
           Date.now.timeIntervalSince(cancels.last) < Printing.patience(afterCancelling: cancels.count) {
            return completionHandler()
        }
        Task {
            guard let window = await window(showing: page), window.attachedSheet == nil else { return completionHandler() }
            Printing.run(Printing.operation(for: page, frame: frame), over: window) { printed in
                tab.printCancels = printed ? nil : ((tab.printCancels?.count ?? 0) + 1, .now)
                completionHandler()
            }
        }
    }
}

enum Printing {
    static func info() -> NSPrintInfo {
        NSPrintInfo.shared.copy() as? NSPrintInfo ?? NSPrintInfo()
    }

    /// The page, or one frame of it (WebKit SPI, as Safari prints a frame;
    /// should it go, the whole page prints).
    static func operation(for page: WKWebView, frame: NSObject? = nil, info: NSPrintInfo = info()) -> NSPrintOperation {
        let forFrame = NSSelectorFromString("_printOperationWithPrintInfo:forFrame:")
        let framed = frame.flatMap { frame in
            page.responds(to: forFrame) ? page.perform(forFrame, with: info, with: frame)?.takeUnretainedValue() as? NSPrintOperation : nil
        }
        let operation = framed ?? page.printOperation(with: info)
        // WebKit's printing view comes without a size, and would print blank pages.
        if operation.view?.frame.isEmpty == true { operation.view?.frame = page.bounds }
        operation.jobTitle = page.title
        return operation
    }

    /// How long a page's own print is let go for after `cancels` in a row
    /// were cancelled: Chrome's 2 seconds, doubling after the third, to 32.
    static func patience(afterCancelling cancels: Int) -> TimeInterval {
        TimeInterval(min(2 << max(cancels - 3, 0), 32))
    }

    /// As a sheet over `window`; `done` once it has printed or saved (true),
    /// or been cancelled.
    static func run(_ operation: NSPrintOperation, over window: NSWindow, done: @escaping (Bool) -> Void = { _ in }) {
        let finished = Finished(done)
        // Kept until the sheet is done: AppKit keeps no hold on it.
        operation.runModal(for: window, delegate: finished, didRun: #selector(Finished.didRun(_:success:contextInfo:)),
                           contextInfo: Unmanaged.passRetained(finished).toOpaque())
    }

    /// The page's title, as a file name: no slashes or colons, which Finder
    /// would take for folders.
    static func fileName(for title: String) -> String {
        let name = title.components(separatedBy: CharacterSet(charactersIn: "/:")).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (name.isEmpty ? "Page" : String(name.prefix(120))) + ".pdf"
    }

    private final class Finished: NSObject {
        let done: (Bool) -> Void

        init(_ done: @escaping (Bool) -> Void) { self.done = done }

        @objc func didRun(_ operation: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
            if let contextInfo { Unmanaged<Finished>.fromOpaque(contextInfo).release() }
            done(success)
        }
    }
}
