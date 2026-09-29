import AppKit
import UserNotifications
import WebKit

/// A site's notifications, as the Mac's own, once you let the site send them
/// (Site Settings). WebKit hands a page's notifications (`new Notification`)
/// to an app only through its C API, and a service worker's through its data
/// store's delegate: both SPI, as Safari's. Should either go, sites are told
/// notifications are blocked, as in an incognito window.
enum WebNotifications {
    typealias Ref = UnsafeRawPointer

    private static let webKit = dlopen("/System/Library/Frameworks/WebKit.framework/WebKit", RTLD_NOW)
    private static func function<T>(_ name: String) -> T? { dlsym(webKit, name).map { unsafeBitCast($0, to: T.self) } }

    private static let managerOf: (@convention(c) (Ref) -> Ref?)? = function("WKContextGetNotificationManager")
    private static let setProvider: (@convention(c) (Ref, Ref) -> Void)? = function("WKNotificationManagerSetProvider")
    private static let copyTitle: (@convention(c) (Ref) -> Ref?)? = function("WKNotificationCopyTitle")
    private static let copyBody: (@convention(c) (Ref) -> Ref?)? = function("WKNotificationCopyBody")
    private static let copyTag: (@convention(c) (Ref) -> Ref?)? = function("WKNotificationCopyTag")
    private static let idOf: (@convention(c) (Ref) -> UInt64)? = function("WKNotificationGetID")
    private static let alertOf: (@convention(c) (Ref) -> UInt32)? = function("WKNotificationGetAlert")
    private static let originOf: (@convention(c) (Ref) -> Ref?)? = function("WKNotificationGetSecurityOrigin")
    private static let copyOrigin: (@convention(c) (Ref) -> Ref?)? = function("WKSecurityOriginCopyToString")
    private static let makeOrigin: (@convention(c) (Ref) -> Ref?)? = function("WKSecurityOriginCreateFromString")
    private static let makeString: (@convention(c) (CFString) -> Ref?)? = function("WKStringCreateWithCFString")
    private static let copyString: (@convention(c) (CFAllocator?, Ref) -> Unmanaged<CFString>)? = function("WKStringCopyCFString")
    private static let makeArray: (@convention(c) (UnsafePointer<Ref?>, Int) -> Ref?)? = function("WKArrayCreate")
    private static let release: (@convention(c) (Ref) -> Void)? = function("WKRelease")
    private static let didShow: (@convention(c) (Ref, UInt64) -> Void)? = function("WKNotificationManagerProviderDidShowNotification")
    private static let didClick: (@convention(c) (Ref, UInt64) -> Void)? = function("WKNotificationManagerProviderDidClickNotification")
    private static let didUpdate: (@convention(c) (Ref, Ref, Bool) -> Void)? = function("WKNotificationManagerProviderDidUpdateNotificationPolicy")
    private static let didRemove: (@convention(c) (Ref, Ref) -> Void)? = function("WKNotificationManagerProviderDidRemoveNotificationPolicies")

    static let isAvailable = managerOf != nil && setProvider != nil && copyTitle != nil && copyBody != nil
        && copyTag != nil && idOf != nil && alertOf != nil && originOf != nil && copyOrigin != nil && makeOrigin != nil
        && makeString != nil && copyString != nil && makeArray != nil && release != nil && didShow != nil
        && didClick != nil && didUpdate != nil && didRemove != nil
        && WKWebsiteDataStore.instancesRespond(to: NSSelectorFromString("set_delegate:"))

    private static var manager: Ref?
    private static let delegate = Delegate()
    /// Those on screen, by WebKit's number: the identifier the Mac knows each
    /// by, and the page it came from, for a click to go back to.
    private static var shown: [UInt64: (identifier: String, page: Weak<WKWebView>)] = [:]

    /// Once, as the first page is made in `pool`, the one every tab shares.
    static func start(pool: Any?) {
        guard manager == nil, isAvailable, Bundle.main.bundleIdentifier != nil,
              let pool = pool as AnyObject?, let managerOf, let setProvider,
              let found = managerOf(Unmanaged.passUnretained(pool).toOpaque()) else { return }
        manager = found
        setProvider(found, provider)
        WKWebsiteDataStore.default().setValue(delegate, forKey: "_delegate")
        UNUserNotificationCenter.current().delegate = delegate
    }

    /// WebKit's WKNotificationProviderV0: its version, then seven callbacks.
    private static let provider: Ref = {
        typealias Show = @convention(c) (Ref?, Ref, Ref?) -> Void
        typealias One = @convention(c) (Ref, Ref?) -> Void
        typealias Permissions = @convention(c) (Ref?) -> Ref?
        // WebKit calls them on the main thread.
        let show: Show = { page, notification, _ in
            nonisolated(unsafe) let (page, notification) = (page, notification)
            MainActor.assumeIsolated { WebNotifications.show(notification, from: page) }
        }
        let cancel: One = { notification, _ in
            nonisolated(unsafe) let notification = notification
            MainActor.assumeIsolated { WebNotifications.cancel(notification) }
        }
        let destroyed: One = { notification, _ in
            nonisolated(unsafe) let notification = notification
            MainActor.assumeIsolated { WebNotifications.forget(notification) }
        }
        let none: One = { _, _ in }
        // Asked only when the data store's delegate has none to give.
        let permissions: Permissions = { _ in nil }
        let memory = UnsafeMutableRawPointer.allocate(byteCount: 72, alignment: 8)
        memory.initializeMemory(as: UInt8.self, repeating: 0, count: 72)
        memory.storeBytes(of: show, toByteOffset: 16, as: Show.self)
        memory.storeBytes(of: cancel, toByteOffset: 24, as: One.self)
        memory.storeBytes(of: destroyed, toByteOffset: 32, as: One.self)
        memory.storeBytes(of: none, toByteOffset: 40, as: One.self)
        memory.storeBytes(of: none, toByteOffset: 48, as: One.self)
        memory.storeBytes(of: permissions, toByteOffset: 56, as: Permissions.self)
        memory.storeBytes(of: none, toByteOffset: 64, as: One.self)
        return Ref(memory)
    }()

    private static func string(_ ref: Ref?) -> String? {
        guard let ref, let copyString, let release else { return nil }
        defer { release(ref) }
        return copyString(nil, ref).takeRetainedValue() as String
    }

    /// The origin as WebKit writes it: no port where it is the scheme's own.
    nonisolated static func origin(of url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), let host = url.host()?.lowercased() else { return nil }
        let port = url.port.flatMap { $0 == (scheme == "https" ? 443 : 80) ? nil : $0 }
        return "\(scheme)://\(host)" + (port.map { ":\($0)" } ?? "")
    }

    /// Whether a notification from `url` may show: its site is allowed, and
    /// it is not an incognito window's.
    private static func allowed(_ url: URL, on page: WKWebView?) -> Bool {
        guard SiteSettings.shared.options(for: url).notifications == .allow else { return false }
        return page.flatMap(browser(of:))?.isPrivate != true
    }

    private static func show(_ notification: Ref, from pageRef: Ref?) {
        guard let manager, let idOf, let didShow, let copyTitle, let copyBody, let copyTag, let alertOf,
              let origin = originOf?(notification).flatMap({ string(copyOrigin?($0)) }), let site = URL(string: origin)
        else { return }
        let page = pageRef.flatMap(page(for:))
        guard page != nil, allowed(site, on: page) else { return }
        let id = idOf(notification)
        let tag = string(copyTag(notification)) ?? ""
        // One with the same tag takes the place of the last, as in Chrome.
        let identifier = tag.isEmpty ? "web.\(id)" : "web.\(origin).\(tag)"
        let content = UNMutableNotificationContent()
        content.title = string(copyTitle(notification)) ?? ""
        content.body = string(copyBody(notification)) ?? ""
        content.subtitle = History.site(of: site) ?? origin
        content.threadIdentifier = origin
        // kWKNotificationAlertSilent
        if alertOf(notification) & 2 == 0 { content.sound = .default }
        content.userInfo = ["webNotification": String(id)]
        shown[id] = (identifier, Weak(page))
        post(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
        didShow(manager, id)
    }

    private static func post(_ request: UNNotificationRequest) {
        let center = UNUserNotificationCenter.current()
        Task {
            // Asks the Mac once, the first time; after that it only answers.
            guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
            try? await center.add(request)
        }
    }

    private static func cancel(_ notification: Ref) {
        guard let id = idOf?(notification), let identifier = shown.removeValue(forKey: id)?.identifier else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [identifier])
    }

    private static func forget(_ notification: Ref) {
        if let id = idOf?(notification) { shown[id] = nil }
    }

    /// A site's choice changed in Site Settings, or in its question: its pages
    /// open now see it, where WebKit tells a page only as its process starts.
    static func policyChanged(for url: URL, to permission: SiteSettings.Permission) {
        guard let manager, let makeString, let makeOrigin, let release, let didUpdate, let didRemove, let makeArray,
              let key = origin(of: url), let name = makeString(key as CFString) else { return }
        defer { release(name) }
        guard let origin = makeOrigin(name) else { return }
        defer { release(origin) }
        switch permission {
        case .allow:
            didUpdate(manager, origin, true)
            // The Mac's own question for Nerda, now rather than at the first notification.
            Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) }
        case .block: didUpdate(manager, origin, false)
        case .ask:
            var origins: [Ref?] = [origin]
            guard let array = makeArray(&origins, 1) else { return }
            didRemove(manager, array)
            release(array)
        }
    }

    /// Whether the Mac lets Nerda show notifications at all, for Site Settings to say so.
    static func macAllows() async -> Bool {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus != .denied
    }

    private static let pageRef = NSSelectorFromString("_pageRefForTransitionToWKWebView")

    private static func page(for ref: Ref) -> WKWebView? {
        typealias Get = @convention(c) (AnyObject, Selector) -> Ref?
        for case let window as BrowserWindow in NSApp.windows {
            for tab in window.browser.tabs {
                guard let page = tab.page, page.responds(to: pageRef) else { continue }
                if unsafeBitCast(page.method(for: pageRef), to: Get.self)(page, pageRef) == ref { return page }
            }
        }
        return nil
    }

    private static func browser(of page: WKWebView) -> Browser? {
        NSApp.windows.lazy.compactMap { ($0 as? BrowserWindow)?.browser }.first { $0.tab(for: page) != nil }
    }

    /// The tab that sent it on screen, in its window, in front.
    private static func bringForward(_ page: WKWebView?) {
        NSApp.activate()
        guard let page, let browser = browser(of: page), let tab = browser.tab(for: page) else { return }
        browser.select(tab.id)
        browser.window?.makeKeyAndOrderFront(nil)
    }

    /// The same, for a service worker's: a tab of its site, or a new one.
    private static func bringForward(_ site: URL) {
        NSApp.activate()
        guard let browser = (NSApp.keyWindow as? BrowserWindow)?.browser
                ?? NSApp.windows.lazy.compactMap({ ($0 as? BrowserWindow)?.browser }).first(where: { !$0.isPrivate }),
              !browser.isPrivate else { return }
        if let tab = browser.tabs.first(where: { SiteSettings.origin($0.site) == SiteSettings.origin(site) }) {
            browser.select(tab.id)
        } else {
            browser.open(site)
        }
        browser.window?.makeKeyAndOrderFront(nil)
    }

    private final class Delegate: NSObject, UNUserNotificationCenterDelegate {
        @objc(notificationPermissionsForWebsiteDataStore:)
        func permissions(_ store: WKWebsiteDataStore) -> [String: NSNumber] {
            SiteSettings.shared.notificationPermissions.mapValues { NSNumber(value: $0) }
        }

        /// A service worker's (`registration.showNotification`).
        @objc(websiteDataStore:showNotification:)
        func show(_ store: WKWebsiteDataStore, notification: NSObject) {
            guard let origin = notification.value(forKey: "origin") as? String, let site = URL(string: origin),
                  WebNotifications.allowed(site, on: nil),
                  let identifier = notification.value(forKey: "identifier") as? String else { return }
            let content = UNMutableNotificationContent()
            content.title = notification.value(forKey: "title") as? String ?? ""
            content.body = notification.value(forKey: "body") as? String ?? ""
            content.subtitle = History.site(of: site) ?? origin
            content.threadIdentifier = origin
            content.sound = .default
            content.userInfo = ["workerNotification": notification.value(forKey: "userInfo") as? [String: Any] ?? [:], "site": origin]
            WebNotifications.post(UNNotificationRequest(identifier: "worker.\(identifier)", content: content, trigger: nil))
        }

        /// Shown while Nerda is in front too, as in Chrome.
        nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
            [.banner, .list, .sound]
        }

        nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
            guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else { return }
            let info = response.notification.request.content.userInfo
            let web = (info["webNotification"] as? String).flatMap(UInt64.init)
            nonisolated(unsafe) let worker = info["workerNotification"] as? [String: Any]
            let site = (info["site"] as? String).flatMap(URL.init(string:))
            await MainActor.run {
                if let web {
                    WebNotifications.bringForward(WebNotifications.shown[web]?.page.value)
                    if let manager = WebNotifications.manager { WebNotifications.didClick?(manager, web) }
                } else if let worker, let site {
                    WebNotifications.bringForward(site)
                    WebNotifications.clickWorker(worker)
                } else {
                    // An extension's, which has no page to go back to.
                    NSApp.activate()
                }
            }
        }
    }

    private static func clickWorker(_ info: [String: Any]) {
        let click = NSSelectorFromString("_processPersistentNotificationClick:completionHandler:")
        let store = WKWebsiteDataStore.default()
        guard store.responds(to: click) else { return }
        typealias Click = @convention(c) (AnyObject, Selector, NSDictionary, @escaping @convention(block) (Bool) -> Void) -> Void
        unsafeBitCast(store.method(for: click), to: Click.self)(store, click, info as NSDictionary) { _ in }
    }
}

/// A reference that doesn't keep what it points to alive.
struct Weak<T: AnyObject> {
    weak var value: T?
    init(_ value: T?) { self.value = value }
}
