import WebKit

/// Only a flag crosses the process boundary; no draft or password is copied.
enum PageActivity {
    // ponytail: edited pages stay awake until navigation; recognize a site's
    // save-state signal once it provides one, rather than guessing it saved.
    static let script = WKUserScript(source: """
        (() => {
            // Only what the person did: a page's own synthetic events (and
            // Nerda's password fill) would otherwise keep every tab awake.
            // Passwords and searches are no draft to lose.
            const draft = node =>
                (node instanceof HTMLInputElement && !['password', 'search', 'hidden'].includes(node.type)) ||
                node instanceof HTMLTextAreaElement || node instanceof HTMLSelectElement || node.isContentEditable;
            const mark = () => {
                removeEventListener('input', edit, true);
                removeEventListener('change', edit, true);
                removeEventListener('drop', drop, true);
                webkit.messageHandlers.pageActivity.postMessage(true);
            };
            const edit = event => {
                if (!event.isTrusted) return;
                const field = event.composedPath().find(draft);
                if (field && !field.closest?.('[role=search], [role=searchbox]')) mark();
            };
            const drop = event => { if (event.isTrusted && event.dataTransfer?.files.length) mark(); };
            addEventListener('input', edit, true);
            addEventListener('change', edit, true);
            addEventListener('drop', drop, true);
        })();
        """, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .defaultClient)

    static let messages = Messages()

    static func install(in controller: WKUserContentController) {
        controller.addUserScript(script)
        controller.add(messages, contentWorld: .defaultClient, name: "pageActivity")
    }

    final class Messages: NSObject, WKScriptMessageHandler {
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.body as? Bool == true, let page = message.webView,
                  let browser = page.uiDelegate as? Browser else { return }
            browser.tab(for: page)?.hasUnsavedWork = true
        }
    }
}
