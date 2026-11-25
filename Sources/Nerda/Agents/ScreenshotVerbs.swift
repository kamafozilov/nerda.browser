import AppKit
import WebKit

/// Seeing an Agent tab's page, though it is never on screen, and clicking
/// at a point of that picture, for pages with nothing to read but pixels
/// (canvas, maps).
nonisolated extension AgentVerb {
    static let screenshotVerbs: [AgentVerb] = [screenshot, clickAt]

    static let screenshot = AgentVerb(
        name: "screenshot",
        summary: """
            A picture of what an Agent tab's page shows (its viewport), as a JPEG \
            \(AgentShot.width) pixels wide, or at full resolution with full. \
            click_at takes points in it.
            """,
        arguments: [.tab, .boolean("full", "Full resolution rather than \(AgentShot.width) pixels wide")],
        readOnly: true
    ) { call in
        let tab = try call.tab()
        let full = call.arguments["full"]?.bool ?? false
        let shot = try await AgentShot.take(tab, full: full)
        call.shown.jpeg = shot.jpeg
        return "tab: \(tab.ref)\nscreenshot: \(shot.width)×\(shot.height) of \(tab.tab.url?.absoluteString ?? "")"
    }

    static let clickAt = AgentVerb(
        name: "click_at",
        summary: """
            Click at a point of an Agent tab's screenshot, in its pixels from the top left, \
            as a person would. For pages with nothing else to click by, such as a canvas or a map.
            """,
        arguments: [
            .tab,
            .integer("x", "Pixels from the screenshot's left edge", required: true),
            .integer("y", "Pixels from the screenshot's top edge", required: true),
            .boolean("full", "The point is in a full-resolution screenshot"),
        ]
    ) { call in
        let tab = try call.tab()
        guard let x = call.arguments["x"]?.number, let y = call.arguments["y"]?.number else {
            throw AgentError(.invalid, "Give x and y as numbers: pixels in the screenshot.")
        }
        let full = call.arguments["full"]?.bool ?? false
        try AgentShot.click(tab, at: CGPoint(x: x, y: y), full: full)
        return "Clicked \(tab.ref) at \(Int(x)), \(Int(y)) of the screenshot."
    }
}

/// Screenshots of Agent tabs, and the points in them.
@MainActor
enum AgentShot {
    /// How wide a screenshot is unless asked for full resolution: enough to
    /// read a page by, small enough to cost a model little.
    nonisolated static let width = 1024

    /// The page's viewport as a JPEG, `width` pixels wide or at the
    /// screen's resolution. The page is in its off-screen window and drawn,
    /// so the picture is the page, not a blank.
    static func take(_ agentTab: AgentTab, full: Bool) async throws -> (jpeg: Data, width: Int, height: Int) {
        guard let page = agentTab.tab.page, page.bounds.width > 0, page.window != nil else {
            throw AgentError(.failed, "Tab \(agentTab.ref) has no page to take a picture of yet. Try again once it has loaded.")
        }
        let configuration = WKSnapshotConfiguration()
        configuration.rect = page.bounds
        let image: NSImage
        do { image = try await page.takeSnapshot(configuration: configuration) } catch {
            throw AgentError(.failed, "Tab \(agentTab.ref)'s page couldn't be pictured: \(error.localizedDescription)")
        }
        guard let pixels = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let jpeg = await Self.jpeg(pixels, width: full ? nil : width) else {
            throw AgentError(.failed, "Tab \(agentTab.ref)'s page couldn't be pictured.")
        }
        let wide = full ? pixels.width : width
        return (jpeg, wide, Int((Double(pixels.height) * Double(wide) / Double(pixels.width)).rounded()))
    }

    /// The image, `width` pixels wide if given, as a JPEG, off the main thread.
    @concurrent nonisolated static func jpeg(_ image: CGImage, width: Int?) async -> Data? {
        var image = image
        if let width, width != image.width {
            let height = max(1, Int((Double(image.height) * Double(width) / Double(image.width)).rounded()))
            guard let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return nil }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let scaled = context.makeImage() else { return nil }
            image = scaled
        }
        return NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.8])
    }

    /// A click at `point` of the tab's screenshot (`width` wide, or full
    /// resolution), sent to the page as the mouse's own, so it sees a
    /// trusted click.
    static func click(_ agentTab: AgentTab, at point: CGPoint, full: Bool) throws {
        guard let page = agentTab.tab.page, let window = page.window, page.bounds.width > 0 else {
            throw AgentError(.failed, "Tab \(agentTab.ref) has no page to click in yet. Try again once it has loaded.")
        }
        let imageWidth = full ? page.bounds.width * window.backingScaleFactor : CGFloat(width)
        let scale = page.bounds.width / imageWidth
        let inPage = CGPoint(x: point.x * scale, y: point.y * scale)
        guard page.bounds.contains(inPage) else {
            throw AgentError(.invalid, "\(Int(point.x)), \(Int(point.y)) is outside the screenshot.")
        }
        let inView = page.isFlipped ? inPage : CGPoint(x: inPage.x, y: page.bounds.height - inPage.y)
        let location = page.convert(inView, to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(
                with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                pressure: type == .leftMouseDown ? 1 : 0
            ) else { continue }
            if type == .leftMouseDown { page.mouseDown(with: event) } else { page.mouseUp(with: event) }
        }
    }
}
