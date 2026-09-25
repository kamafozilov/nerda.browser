import WebKit

/// Selected text lit as Chrome lights it: the text, and nothing else. WebKit
/// also fills a selection's "gaps" once it runs past a line: from each line's
/// end out to the page's edges, over margins and between paragraphs, so three
/// clicks on a line of a GitHub page lit a band the window's width. It has no
/// setting against it. So WebKit's own highlight is made clear, and the
/// selection is drawn instead as a highlight of the page's (CSS Custom
/// Highlight), which colours text only, in WebKit's colours for a selection.
/// WebKit still draws a site's own selection colour, gaps and all, and what a
/// page's highlight can't reach: text fields, images, and the insides of
/// components (shadow DOM), where WebKit tells a page nothing of a selection.
// ponytail: a selection running from the page into a component shows only its
// part inside: WebKit gives it no range to draw.
enum Selection {
    static func install(in controller: WKUserContentController) {
        // WebKit SPI, as Safari's extensions use: a style sheet of the user's,
        // under the page's own, so a site's `::selection` still wins. Should it
        // go, WebKit draws selections itself, as before.
        let add = NSSelectorFromString("_addUserStyleSheet:")
        guard let type = NSClassFromString("_WKUserStyleSheet") as? NSObject.Type, controller.responds(to: add) else { return }
        let initializer = NSSelectorFromString("initWithSource:forMainFrameOnly:")
        typealias Initializer = @convention(c) (AnyObject, Selector, NSString, Bool) -> AnyObject
        let sheet = unsafeBitCast(type.instanceMethod(for: initializer), to: Initializer.self)(
            type.perform(NSSelectorFromString("alloc")).takeUnretainedValue(), initializer, css as NSString, false)
        controller.perform(add, with: sheet)
        controller.addUserScript(script)
    }

    /// Clear, but told apart from a site's own clear (one hiding its selections).
    private static let clear = "rgba(1, 2, 3, 0)"

    /// Only the page's own elements (`:root` doesn't reach into components).
    /// The colours are WebKit's for a selection in the window in use
    /// (`Highlight`), and for one in a window behind or a frame not in use
    /// (unemphasized, made see-through as WebKit makes it).
    private static let css = """
        :root :not(input, textarea, img, video, canvas, svg)::selection { background-color: \(clear); }
        ::highlight(nerda-selection) { background-color: Highlight; }
        ::highlight(nerda-selection-inactive) { background-color: light-dark(rgb(196 196 196 / .6), rgb(70 70 70 / .8)); }
        """

    private static let script = WKUserScript(source: """
        (() => {
            if (!window.CSS?.highlights) return;
            const highlight = new Highlight();
            let active = document.hasFocus();
            // A site's own selection colour at both ends: WebKit's to draw.
            const ours = node => {
                const element = node?.nodeType === Node.ELEMENT_NODE ? node : node?.parentElement;
                return element && getComputedStyle(element, '::selection').backgroundColor === '\(clear)';
            };
            // Set again with each selection, should the page have cleared the page's highlights.
            const show = () => {
                CSS.highlights.delete(active ? 'nerda-selection-inactive' : 'nerda-selection');
                CSS.highlights.set(active ? 'nerda-selection' : 'nerda-selection-inactive', highlight);
            };
            document.addEventListener('selectionchange', () => {
                highlight.clear();
                const selection = getSelection();
                if (!selection.rangeCount || selection.isCollapsed) return;
                if (!ours(selection.anchorNode) && !ours(selection.focusNode)) return;
                highlight.add(selection.getRangeAt(0).cloneRange());
                show();
            });
            addEventListener('focus', () => { active = true; show(); });
            addEventListener('blur', () => { active = false; show(); });
        })();
        """, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .defaultClient)
}
