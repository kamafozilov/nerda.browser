import WebKit

/// Only a flag crosses the process boundary; no draft or password is copied.
enum PageActivity {
    // The main frame says whether a field the person edited still holds their
    // change, re-asked after a send (Enter, click, submit), on input and on
    // visibilitychange: a chat app that clears its box lets the tab sleep again.
    // A subframe can't be re-asked from the top, so its first edit, like a
    // dropped file, stays until a new document.
    static let script = WKUserScript(source: """
        (() => {
            // Only what the person did: a page's own synthetic events (and
            // Nerda's password fill) would otherwise keep every tab awake.
            // Passwords and searches are no draft to lose.
            const draft = node =>
                (node instanceof HTMLInputElement && !['password', 'search', 'hidden'].includes(node.type)) ||
                node instanceof HTMLTextAreaElement || node instanceof HTMLSelectElement || node.isContentEditable;
            const edited = event => {
                if (!event.isTrusted) return;
                let field = event.composedPath().find(draft);
                if (!field || field.closest?.('[role=search], [role=searchbox]')) return;
                while (field.isContentEditable && field.parentElement?.isContentEditable) field = field.parentElement;
                return field;
            };
            const dropped = event => event.isTrusted && event.dataTransfer?.files.length > 0;
            const post = value => webkit.messageHandlers.pageActivity.postMessage(value);
            if (window !== window.top) {
                const mark = event => {
                    if (!(event.type === 'drop' ? dropped(event) : edited(event))) return;
                    for (const type of ['input', 'change', 'drop']) removeEventListener(type, mark, true);
                    post(true);
                };
                for (const type of ['input', 'change', 'drop']) addEventListener(type, mark, true);
                return;
            }
            const fields = new Set();
            let sticky = false, posted = false, timer;
            const holdsChange = field =>
                field.isContentEditable ? field.innerText.trim() !== '' :
                field instanceof HTMLSelectElement ? [...field.options].some(option => option.selected !== option.defaultSelected) :
                ['checkbox', 'radio'].includes(field.type) ? field.checked !== field.defaultChecked :
                field.value !== field.defaultValue;
            const check = () => {
                for (const field of fields) if (!field.isConnected) fields.delete(field);
                const now = sticky || [...fields].some(holdsChange);
                if (now !== posted) post(posted = now);
            };
            // Time for the app to clear its box after sending.
            const soon = () => {
                if (!fields.size) return;
                clearTimeout(timer);
                timer = setTimeout(check, 500);
            };
            const edit = event => {
                const field = edited(event);
                if (!field) return;
                fields.add(field);
                // Once marked, reading every field on each key can wait for a pause.
                posted ? soon() : check();
            };
            addEventListener('input', edit, true);
            addEventListener('change', edit, true);
            addEventListener('drop', event => { if (dropped(event)) { sticky = true; check(); } }, true);
            addEventListener('keydown', event => { if (event.isTrusted && event.key === 'Enter') soon(); }, true);
            addEventListener('click', event => { if (event.isTrusted) soon(); }, true);
            addEventListener('submit', event => { if (event.isTrusted) soon(); }, true);
            // Re-asking only reads the fields, so a page's own event can't forge an answer.
            document.addEventListener('visibilitychange', check);
            // Back from the back-forward cache, the tab was cleared as a new document: say again.
            addEventListener('pageshow', event => { if (event.persisted) { posted = false; check(); } });
        })();
        """, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .defaultClient)

    static let messages = Messages()

    static func install(in controller: WKUserContentController) {
        controller.addUserScript(script)
        controller.add(messages, contentWorld: .defaultClient, name: "pageActivity")
    }

    final class Messages: NSObject, WKScriptMessageHandler {
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let edited = message.body as? Bool, let page = message.webView,
                  let browser = page.uiDelegate as? Browser, let tab = browser.tab(for: page) else { return }
            // A main-frame false never clears what a subframe said.
            if message.frameInfo.isMainFrame { tab.mainFrameHasDraft = edited } else if edited { tab.subframeWasEdited = true }
        }
    }
}
