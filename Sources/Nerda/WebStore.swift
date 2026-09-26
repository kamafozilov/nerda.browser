import WebKit

/// The Chrome Web Store, made to work for Nerda (after Search's StoreRelay,
/// see Extensions.swift).
///
/// The store sees a browser that isn't Chrome and says so: a banner asking
/// to switch to Chrome, and an Add to Chrome button that stays grey. On its
/// pages the banner goes and the grey button is replaced by an Add to Nerda
/// one, the button people already look for. What gets installed is read from
/// the tab's own address, never from anything the page says: the page only
/// asks, and the usual question still stands between asking and installing.
enum WebStore {
    /// Where the extensions list's Chrome Web Store goes: its extensions, not its themes.
    static let home = URL(string: "https://chromewebstore.google.com/category/extensions")!

    static func isStorePage(_ url: URL?) -> Bool {
        let host = url?.host()?.lowercased() ?? ""
        return host == "chromewebstore.google.com" || (host == "chrome.google.com" && url?.path().hasPrefix("/webstore") == true)
    }

    /// The extension a store page is about, if it is one's page.
    static func extensionID(on url: URL?) -> String? {
        guard let url, isStorePage(url) else { return nil }
        return Crx.id(in: url.path())
    }

    static func install(in configuration: WKUserContentController) {
        configuration.addUserScript(script)
        configuration.add(relay, contentWorld: .defaultClient, name: "nerdaStore")
    }

    /// The page's button was pressed: the extension its tab is showing.
    private static let relay = Relay()

    private final class Relay: NSObject, WKScriptMessageHandler {
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, (message.body as? [String: Any])?["add"] != nil,
                  let url = message.webView?.url, let id = WebStore.extensionID(on: url) else { return }
            Extensions.shared.install(from: id)
        }
    }

    /// Tells a store page what is installed and what is on its way.
    static func tell(_ page: WKWebView?) {
        guard let page, isStorePage(page.url) else { return }
        let state: [String: Any] = ["installed": Extensions.shared.installed.map(\.id), "busy": Extensions.shared.busy ?? NSNull()]
        guard let data = try? JSONSerialization.data(withJSONObject: state), let json = String(data: data, encoding: .utf8) else { return }
        page.evaluateJavaScript("window.__nerdaStore && window.__nerdaStore.state(\(json))", in: nil, in: .defaultClient)
    }

    /// Main frame, every page, returning at once anywhere but the store. The
    /// store's markup is generated and its class names change between
    /// releases, so nothing here leans on them: the store's own button is the
    /// disabled one that names Chrome, and the banner is the small block
    /// round the one enabled button that does.
    private static let script = WKUserScript(source: """
        (function () {
          if (location.hostname !== 'chromewebstore.google.com' || window.__nerdaStore) return;
          var state = { installed: [], busy: null };

          function pageID() {
            var m = location.pathname.match(/\\/detail\\/(?:[^\\/]+\\/)?([a-p]{32})/);
            return m ? m[1] : null;
          }

          function theirs() {
            var buttons = document.querySelectorAll('button[disabled]');
            for (var i = 0; i < buttons.length; i++) {
              var b = buttons[i];
              if (!b.dataset.nerda && /chrome/i.test(b.textContent || '')) return b;
            }
            return null;
          }

          // From the banner's own button up, as far as it goes without taking
          // in the header beside it: short, and holding no install button.
          function bannerOf(button) {
            var box = null, up = button.parentElement;
            while (up && up !== document.body) {
              if (up.querySelector('button[disabled], button[data-nerda]')) break;
              if ((up.innerText || '').length > 160) break;
              box = up;
              up = up.parentElement;
            }
            return box;
          }

          function hideBanner() {
            // And the floating "Switch to Chrome?" card, known by the Chrome
            // logo it carries in any language: it sits right over the button.
            var cards = document.querySelectorAll('[role="dialog"]');
            for (var c = 0; c < cards.length; c++) {
              if (!cards[c].dataset.nerda && cards[c].querySelector('img[src*="productlogos/chrome"]')) {
                cards[c].style.display = 'none';
                cards[c].dataset.nerda = 'promo';
              }
            }
            var buttons = document.querySelectorAll('button:not([disabled])');
            for (var i = 0; i < buttons.length; i++) {
              var b = buttons[i];
              if (b.dataset.nerda || !/chrome/i.test(b.getAttribute('aria-label') || '')) continue;
              var box = bannerOf(b);
              if (box && !box.dataset.nerda) {
                box.style.display = 'none';
                box.dataset.nerda = 'banner';
              }
            }
          }

          // The words only, so the button keeps the store's own shape and colour.
          function label(button, text) {
            var walker = document.createTreeWalker(button, NodeFilter.SHOW_TEXT);
            var node, last = null;
            while ((node = walker.nextNode())) { if (node.nodeValue.trim()) last = node; }
            if (last) last.nodeValue = text; else button.textContent = text;
          }

          function render(ours) {
            var id = pageID();
            var installed = !!id && state.installed.indexOf(id) >= 0;
            var busy = !!id && state.busy === id;
            label(ours, installed ? 'Added to Nerda' : (busy ? 'Adding…' : 'Add to Nerda'));
            ours.disabled = installed || busy;
          }

          // The store keeps the pages it has left, hidden, beside the one it shows.
          function renderAll() {
            var mine = document.querySelectorAll('button[data-nerda="add"]');
            for (var i = 0; i < mine.length; i++) render(mine[i]);
          }

          function mend() {
            hideBanner();
            if (!pageID()) return;
            var original = theirs();
            if (original && original.parentNode) {
              var ours = original.cloneNode(true);
              ['disabled', 'jsaction', 'jscontroller', 'jsname', 'jslog', 'aria-describedby'].forEach(function (name) {
                ours.removeAttribute(name);
              });
              ours.dataset.nerda = 'add';
              original.dataset.nerda = 'theirs';
              original.style.display = 'none';
              original.parentNode.insertBefore(ours, original.nextSibling);
            }
            renderAll();
          }

          // Caught on the window, before the store's own handlers (on the
          // document) can see the click at all.
          window.addEventListener('click', function (e) {
            var mine = e.target && e.target.closest && e.target.closest('button[data-nerda="add"]');
            if (!mine) return;
            e.preventDefault();
            e.stopImmediatePropagation();
            if (!mine.disabled) window.webkit.messageHandlers.nerdaStore.postMessage({ add: true });
          }, true);

          window.__nerdaStore = {
            state: function (next) {
              state = next || state;
              renderAll();
            }
          };

          // The store is one page that rewrites itself: whatever it redraws,
          // mend again. A timer rather than a frame: a tab out of sight gets no frames.
          var queued = false;
          new MutationObserver(function () {
            if (queued) return;
            queued = true;
            setTimeout(function () { queued = false; mend(); }, 60);
          }).observe(document.documentElement, { childList: true, subtree: true });
          mend();
        })();
        """, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient)
}
