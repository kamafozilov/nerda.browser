import AVFoundation
import CoreLocation
import SwiftUI
import WebKit

/// Permissions belong to an origin, including its scheme and port. Private
/// windows use an in-memory instance rather than the regular preferences.
@Observable
final class SiteSettings {
    static let shared = SiteSettings(defaults: .standard)
    enum Permission: String, Codable, CaseIterable, Identifiable {
        case ask, allow, block
        var id: Self { self }
        var title: String { rawValue.capitalized }
        var decision: WKPermissionDecision {
            switch self { case .ask: .prompt; case .allow: .grant; case .block: .deny }
        }
    }
    /// What a site can ask for, as its row in Site Settings and in its question.
    enum Kind: CaseIterable, Identifiable {
        case camera, microphone, location, notifications
        var id: Self { self }
        var title: String {
            switch self {
            case .camera: "Camera"
            case .microphone: "Microphone"
            case .location: "Location"
            case .notifications: "Notifications"
            }
        }
        /// What the site wants, after "example.com wants to".
        var request: String {
            switch self {
            case .camera: "Use your camera"
            case .microphone: "Use your microphone"
            case .location: "Know your location"
            case .notifications: "Show notifications"
            }
        }
        func symbol(_ permission: Permission) -> String {
            let symbol = switch self {
            case .camera: "video"
            case .microphone: "mic"
            case .location: "location"
            case .notifications: "bell"
            }
            return permission == .block ? symbol + ".slash" : symbol
        }
        var key: WritableKeyPath<Options, Permission> {
            switch self {
            case .camera: \.camera
            case .microphone: \.microphone
            case .location: \.location
            case .notifications: \.notifications
            }
        }
        /// What a site not answered for gets: asked, or blocked without
        /// asking (Settings › Site Settings), as Chrome's "Don't allow sites to ask".
        var fallback: Permission {
            UserDefaults.standard.string(forKey: fallbackKey) == Permission.block.rawValue ? .block : .ask
        }

        var fallbackKey: String { "sitePermission.\(title.lowercased())" }

        /// What a site can be given: no Ask where every site is blocked from asking.
        var choices: [Permission] { fallback == .block ? [.allow, .block] : Permission.allCases }

        /// Where the Mac lets Nerda have it at all.
        var macSettings: URL {
            URL(string: self == .notifications ? "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
                : "x-apple.systempreferences:com.apple.preference.security?Privacy_\(self == .location ? "LocationServices" : title)")!
        }
    }
    struct Options: Codable, Equatable {
        var blocksAds = true
        var camera = Permission.ask
        var microphone = Permission.ask
        var location = Permission.ask
        var notifications = Permission.ask
    }
    /// Each site with a choice of its own, by origin.
    private(set) var sites: [String: Options]
    @ObservationIgnored private let defaults: UserDefaults?

    init(defaults: UserDefaults?) {
        self.defaults = defaults
        sites = defaults?.data(forKey: "siteSettings")
            .flatMap { try? JSONDecoder().decode([String: Options].self, from: $0) } ?? [:]
    }

    nonisolated static func origin(_ url: URL?) -> String? {
        guard let url, let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host()?.lowercased(), !host.isEmpty else { return nil }
        let port = url.port ?? (scheme == "https" ? 443 : 80)
        return "\(scheme)://\(host):\(port)"
    }

    static func origin(_ origin: WKSecurityOrigin) -> String? {
        var parts = URLComponents()
        parts.scheme = origin.protocol
        parts.host = origin.host
        if origin.port > 0 { parts.port = origin.port }
        return Self.origin(parts.url)
    }

    func options(for url: URL?) -> Options { Self.origin(url).flatMap { sites[$0] } ?? Options() }

    /// What the site may do: its own choices, and for what it hasn't been
    /// answered, what Settings gives every site.
    func resolved(for url: URL?) -> Options {
        var options = options(for: url)
        for kind in Kind.allCases where options[keyPath: kind.key] == .ask {
            options[keyPath: kind.key] = kind.fallback
        }
        return options
    }

    /// The sites allowed or blocked from showing notifications, as WebKit
    /// hands them to a page's process as it starts.
    var notificationPermissions: [String: Bool] {
        sites.reduce(into: [:]) { permissions, site in
            guard site.value.notifications != .ask, let url = URL(string: site.key),
                  let origin = WebNotifications.origin(of: url) else { return }
            permissions[origin] = site.value.notifications == .allow
        }
    }

    func set(_ options: Options, for url: URL) {
        guard let key = Self.origin(url) else { return }
        sites[key] = options == Options() ? nil : options
        defaults?.set(try? JSONEncoder().encode(sites), forKey: "siteSettings")
    }

    func mediaDecision(for origin: WKSecurityOrigin, on page: WKWebView, type: WKMediaCaptureType) -> WKPermissionDecision {
        let decision = Self.mediaDecision(options: resolved(for: page.url), type: type)
        // Block applies to the whole page. Embedded origins never inherit
        // the host page's permission to capture.
        guard decision != .deny, Self.origin(origin) != Self.origin(page.url) else { return decision }
        return .prompt
    }

    static func mediaDecision(options: Options, type: WKMediaCaptureType) -> WKPermissionDecision {
        let permissions: [Permission]
        switch type {
        case .camera: permissions = [options.camera]
        case .microphone: permissions = [options.microphone]
        case .cameraAndMicrophone: permissions = [options.camera, options.microphone]
        @unknown default: return .deny
        }
        if permissions.contains(.block) { return .deny }
        return permissions.allSatisfy { $0 == .allow } ? .grant : .prompt
    }

    static let blockingSelector = NSSelectorFromString("_setContentRuleListsEnabled:exceptions:")
    static let supportsSiteBlocking = WKWebpagePreferences().responds(to: blockingSelector)

    func applyBlocking(to preferences: WKWebpagePreferences, for url: URL?, lists: [WKContentRuleList] = Blocker.shared.rules) {
        // WebKit SPI, also used by Safari. It changes this document, even
        // when a popup shares its opener's content controller. Only Nerda's
        // lists are excepted; an extension's blocking stays its own.
        // Each navigation's preferences start with every list on: only an
        // exception needs the call.
        guard Self.supportsSiteBlocking, !options(for: url).blocksAds else { return }
        let exceptions = lists.compactMap(\.identifier)
        typealias SetRules = @convention(c) (AnyObject, Selector, Bool, NSSet) -> Void
        let call = unsafeBitCast(preferences.method(for: Self.blockingSelector), to: SetRules.self)
        call(preferences, Self.blockingSelector, true, NSSet(array: exceptions))
    }
}


extension SiteSettings {
    /// What the Mac itself keeps from Nerda, whatever a site's choice.
    static func offOnMac() async -> Set<Kind> {
        var off: Set<Kind> = []
        let refused: Set<AVAuthorizationStatus> = [.denied, .restricted]
        if refused.contains(AVCaptureDevice.authorizationStatus(for: .video)) { off.insert(.camera) }
        if refused.contains(AVCaptureDevice.authorizationStatus(for: .audio)) { off.insert(.microphone) }
        if [.denied, .restricted].contains(CLLocationManager().authorizationStatus) { off.insert(.location) }
        if WebNotifications.isAvailable, !(await WebNotifications.macAllows()) { off.insert(.notifications) }
        return off
    }
}


extension SiteSettings.Options {
    /// A setting saved before it existed (notifications, from 0.0.16) keeps its default.
    init(from decoder: any Decoder) throws {
        let saved = try decoder.container(keyedBy: CodingKeys.self)
        let options = Self()
        blocksAds = try saved.decodeIfPresent(Bool.self, forKey: .blocksAds) ?? options.blocksAds
        camera = try saved.decodeIfPresent(SiteSettings.Permission.self, forKey: .camera) ?? options.camera
        microphone = try saved.decodeIfPresent(SiteSettings.Permission.self, forKey: .microphone) ?? options.microphone
        location = try saved.decodeIfPresent(SiteSettings.Permission.self, forKey: .location) ?? options.location
        notifications = try saved.decodeIfPresent(SiteSettings.Permission.self, forKey: .notifications) ?? options.notifications
    }
}

/// A site asking for something, over its tab, until you answer it or it goes.
struct PermissionRequest: Identifiable {
    let id = UUID()
    let tab: Tab.ID
    let site: URL
    let kinds: [SiteSettings.Kind]
    let answer: CheckedContinuation<Bool?, Never>
}

extension Browser {
    func webView(_ webView: WKWebView, decideMediaCapturePermissionsFor origin: WKSecurityOrigin,
                 initiatedBy frame: WKFrameInfo, type: WKMediaCaptureType) async -> WKPermissionDecision {
        guard !locked else { return .deny }
        let decision = siteSettings.mediaDecision(for: origin, on: webView, type: type)
        // A frame from another site gets WebKit's own question, naming it:
        // an answer to Nerda's would be kept for the page around it.
        guard decision == .prompt, SiteSettings.origin(origin) == SiteSettings.origin(webView.url) else { return decision }
        let options = siteSettings.resolved(for: webView.url)
        let kinds: [SiteSettings.Kind] = switch type {
        case .camera: [.camera]
        case .microphone: [.microphone]
        default: [.camera, .microphone]
        }
        return await askPermission(kinds.filter { options[keyPath: $0.key] == .ask }, on: webView)
    }

    @available(macOS 27.0, *)
    func webView(_ webView: WKWebView, requestGeolocationPermissionFor origin: WKSecurityOrigin,
                 initiatedBy frame: WKFrameInfo) async -> WKPermissionDecision {
        await locationDecision(origin, on: webView)
    }

    // The equivalent delegate on macOS 15.4–26 is SPI.
    @objc(_webView:requestGeolocationPermissionForOrigin:initiatedByFrame:decisionHandler:)
    func locationPermission(_ page: WKWebView, origin: WKSecurityOrigin, frame: WKFrameInfo,
                            decision: @escaping (WKPermissionDecision) -> Void) {
        Task { decision(await locationDecision(origin, on: page)) }
    }

    private func locationDecision(_ origin: WKSecurityOrigin, on page: WKWebView) async -> WKPermissionDecision {
        guard !locked else { return .deny }
        let decision = siteSettings.resolved(for: page.url).location.decision
        guard decision != .deny, SiteSettings.origin(origin) == SiteSettings.origin(page.url) else {
            return decision == .deny ? .deny : .prompt
        }
        return decision == .prompt ? await askPermission([.location], on: page) : decision
    }

    // SPI, as Safari's. Only the page's own site asks, never a frame's, and
    // never in incognito, as in Chrome.
    @objc(_webView:requestNotificationPermissionForSecurityOrigin:decisionHandler:)
    func notificationPermission(_ page: WKWebView, origin: WKSecurityOrigin, decision: @escaping (Bool) -> Void) {
        guard WebNotifications.isAvailable, !locked, !isPrivate, let url = page.url,
              SiteSettings.origin(origin) == SiteSettings.origin(url) else { return decision(false) }
        switch siteSettings.resolved(for: url).notifications {
        case .allow: decision(true)
        case .block: decision(false)
        case .ask:
            Task {
                let answer = await askPermission([.notifications], on: page)
                decision(answer == .grant)
                // Put off, not answered: the site may ask again another time.
                if siteSettings.options(for: url).notifications == .ask { WebNotifications.policyChanged(for: url, to: .ask) }
            }
        }
    }

    /// Nerda's question, hung from Site Settings once the page's tab is on
    /// screen, as Chrome's: Allow and Block are kept for the site; put away
    /// unanswered, the page is told no this time. One question at a time.
    func askPermission(_ kinds: [SiteSettings.Kind], on page: WKWebView) async -> WKPermissionDecision {
        guard !kinds.isEmpty, let site = page.url else { return .grant }
        var tab: Tab?
        while true {
            guard await window(showing: page) != nil, let found = self.tab(for: page),
                  SiteSettings.origin(found.site) == SiteSettings.origin(site) else { return .deny }
            if permissionRequest == nil { tab = found; break }
            await Self.nextChange { _ = self.permissionRequest }
        }
        guard let tab else { return .deny }
        // The site's own choice may have come in the meantime (another question).
        let options = siteSettings.resolved(for: site)
        let asking = kinds.filter { options[keyPath: $0.key] == .ask }
        if asking.isEmpty { return kinds.allSatisfy { options[keyPath: $0.key] == .allow } ? .grant : .deny }
        let answer = await withCheckedContinuation { answer in
            let request = PermissionRequest(tab: tab.id, site: site, kinds: asking, answer: answer)
            permissionRequest = request
            // The tab closed, asleep or gone to another site takes its question with it.
            Task { [weak self] in
                while let self, permissionRequest?.id == request.id {
                    guard tabs.contains(where: { $0 === tab }), !tab.isAsleep,
                          SiteSettings.origin(tab.site) == SiteSettings.origin(site) else { return answerPermission(request.id, nil) }
                    await Self.nextChange { _ = (self.tabs, tab.isAsleep, tab.site, self.permissionRequest) }
                }
            }
        }
        return answer == true ? .grant : .deny
    }

    func answerPermission(_ id: UUID, _ allowed: Bool?) {
        guard let request = permissionRequest, request.id == id else { return }
        permissionRequest = nil
        if let allowed {
            var options = siteSettings.options(for: request.site)
            for kind in request.kinds { options[keyPath: kind.key] = allowed ? .allow : .block }
            changeSiteOptions(options, for: request.site)
        }
        request.answer.resume(returning: allowed)
    }

    /// Waits for what `read` reads to change.
    static func nextChange(_ read: @escaping () -> Void) async {
        await withCheckedContinuation { changed in
            withObservationTracking(read) { changed.resume() }
        }
    }

    func changeSiteOptions(_ options: SiteSettings.Options, for url: URL) {
        let previous = siteSettings.options(for: url)
        siteSettings.set(options, for: url)
        if !isPrivate, previous.notifications != options.notifications {
            WebNotifications.policyChanged(for: url, to: options.notifications)
        }
        for tab in tabs where SiteSettings.origin(tab.site) == SiteSettings.origin(url) {
            // Revocation takes effect immediately, without a reload.
            if options.camera != .allow, previous.camera != options.camera {
                tab.page?.setCameraCaptureState(.none, completionHandler: nil)
            }
            if options.microphone != .allow, previous.microphone != options.microphone {
                tab.page?.setMicrophoneCaptureState(.none, completionHandler: nil)
            }
        }
    }
}

/// Beside the address, as Chrome's: what this site may do. A site's question
/// (`askPermission`) hangs from it too, so its answer is found here after.
struct SiteControls: View {
    let browser: Browser
    let url: URL
    /// The window's light or dark, not the page's the bar takes, as the
    /// extensions list.
    let scheme: ColorScheme
    @State private var shown = false

    var body: some View {
        let request = browser.permissionRequest.flatMap { $0.tab == browser.selectedID ? $0 : nil }
        BarButton(icon: "slider.horizontal.3", help: "Site Settings") { shown.toggle() }
            .accessibilityLabel("Site Settings")
            .background {
                Color.clear
                    .popover(isPresented: $shown, arrowEdge: .bottom) {
                        SitePanel(browser: browser, url: url) { shown = false }.popoverGlass()
                    }
                    .environment(\.colorScheme, scheme)
            }
            .background {
                Color.clear
                    .popover(item: Binding(get: { request }, set: { if $0 == nil, let request { browser.answerPermission(request.id, nil) } }),
                             arrowEdge: .bottom) { request in
                        PermissionPrompt(request: request) { browser.answerPermission(request.id, $0) }.popoverGlass()
                    }
                    .environment(\.colorScheme, scheme)
            }
            .onChange(of: url) { shown = false }
    }
}

/// What Site Settings shows: the site and its connection, what it may do,
/// and its data.
private struct SitePanel: View {
    let browser: Browser
    let url: URL
    let close: () -> Void

    @State private var blockingChanged = false
    /// What the Mac itself keeps from Nerda, whatever the site's choice.
    @State private var offOnMac: Set<SiteSettings.Kind> = []

    var body: some View {
        let options = browser.siteSettings.resolved(for: url)
        let secure = url.scheme == "https"
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Favicon(site: url, size: 16, plate: false)
                    .frame(width: 26, height: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(History.site(of: url) ?? url.host() ?? "")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                    Label(secure ? "Connection is secure" : "Connection is not secure",
                          systemImage: secure ? "lock.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.muted)
                        .labelStyle(TightLabel())
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 6)
            Divider().padding(.horizontal, 12).padding(.vertical, 4)
            VStack(spacing: 2) {
                SettingRow(symbol: options.blocksAds ? "shield.lefthalf.filled" : "shield.slash", title: "Ads and trackers",
                           note: Blocker.shared.isEnabled ? nil : "Blocking is off in Settings") {
                    Toggle("Block ads and trackers", isOn: Binding(get: { options.blocksAds }, set: {
                        change(\.blocksAds, to: $0)
                        blockingChanged = true
                    }))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .disabled(!SiteSettings.supportsSiteBlocking)
                }
                ForEach(kinds) { kind in
                    let permission = options[keyPath: kind.key]
                    SettingRow(symbol: kind.symbol(permission), title: kind.title,
                               note: offOnMac.contains(kind) ? "Off for Nerda in System Settings" : nil,
                               noteAction: { NSWorkspace.shared.open(kind.macSettings) }) {
                        PermissionMenu(title: kind.title, choices: kind.choices,
                                       selection: Binding(get: { permission }, set: { change(kind.key, to: $0) }))
                    }
                }
            }
            .padding(.horizontal, 6)
            Divider().padding(.horizontal, 12).padding(.vertical, 4)
            VStack(spacing: 2) {
                // Ad blocking is chosen as a page loads; the rest applies at once.
                if blockingChanged {
                    PopoverRow(symbol: "arrow.clockwise", title: "Reload to Apply") {
                        browser.selected?.reload()
                        close()
                    }
                }
                PopoverRow(symbol: "trash", title: "Clear Site Data…", action: clearData)
                if browser.siteSettings.options(for: url) != .init() {
                    PopoverRow(symbol: "arrow.counterclockwise", title: "Reset Site Settings") {
                        if !options.blocksAds { blockingChanged = true }
                        browser.changeSiteOptions(.init(), for: url)
                    }
                }
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 6)
        }
        .frame(width: 300)
        .task { offOnMac = await SiteSettings.offOnMac() }
    }

    /// Notifications only in a regular window, and only where WebKit hands them over.
    private var kinds: [SiteSettings.Kind] {
        SiteSettings.Kind.allCases.filter { $0 != .notifications || !browser.isPrivate && WebNotifications.isAvailable }
    }

    private func change<T>(_ key: WritableKeyPath<SiteSettings.Options, T>, to value: T) {
        var options = browser.siteSettings.options(for: url)
        options[keyPath: key] = value
        browser.changeSiteOptions(options, for: url)
    }

    private func clearData() {
        close()
        guard let tab = browser.selected, SiteSettings.origin(tab.site) == SiteSettings.origin(url),
              let window = browser.window else { return }
        let alert = NSAlert()
        alert.messageText = "Clear data for \(History.site(of: url) ?? "this site")?"
        alert.informativeText = "This may sign you out and remove offline data and drafts."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Clear")
        alert.buttons[1].hasDestructiveAction = true
        alert.beginSheetModal(for: window) { answer in
            if answer == .alertSecondButtonReturn { Task { await tab.clearSiteData() } }
        }
    }
}

/// One thing a site may do: its icon on a tile, what it is, and its switch or choice.
private struct SettingRow<Control: View>: View {
    let symbol: String
    let title: String
    var note: String?
    var noteAction: (() -> Void)?
    @ViewBuilder let control: Control

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Palette.ink)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Palette.wash))
                .contentTransition(.symbolEffect(.replace))
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.ink)
                if let note {
                    Button(note) { noteAction?() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.muted)
                        .disabled(noteAction == nil)
                }
            }
            Spacer(minLength: 8)
            control
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 38)
    }
}

/// Ask, Allow or Block, as a small menu at the row's end.
struct PermissionMenu: View {
    let title: String
    let choices: [SiteSettings.Permission]
    @Binding var selection: SiteSettings.Permission

    @State private var hovering = false

    var body: some View {
        Menu {
            Picker(title, selection: $selection) {
                ForEach(choices) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 4) {
                Text(selection.title)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Palette.muted)
            }
            .font(.system(size: 12))
            .foregroundStyle(selection == .ask ? Palette.muted : Palette.ink)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hovering ? Palette.wash : Palette.hover))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("\(title): \(selection.title)")
        .onHover { hovering = $0 }
    }
}

/// "example.com wants to", what it wants, and Block or Allow. Put away
/// (Esc, or a click elsewhere), it is asked another time.
private struct PermissionPrompt: View {
    let request: PermissionRequest
    let answer: (Bool?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Favicon(site: request.site, size: 16, plate: false)
                Text("\(History.site(of: request.site) ?? request.site.host() ?? "This site") wants to")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(request.kinds) { kind in
                    HStack(spacing: 10) {
                        Image(systemName: kind.symbol(.allow))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Palette.ink)
                            .frame(width: 26, height: 26)
                            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Palette.wash))
                        Text(kind.request)
                            .font(.system(size: 13))
                            .foregroundStyle(Palette.ink)
                    }
                }
            }
            .padding(.top, 12)
            HStack(spacing: 8) {
                Spacer()
                PromptButton(title: "Block") { answer(false) }
                PromptButton(title: "Allow", prominent: true) { answer(true) }
            }
            .padding(.top, 16)
        }
        .padding(16)
        .frame(width: 300)
    }
}

private struct PromptButton: View {
    let title: String
    var prominent = false
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(prominent ? Palette.ground : Palette.ink)
                .padding(.horizontal, 14)
                .frame(minWidth: 72)
                .frame(height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(prominent ? AnyShapeStyle(Palette.ink) : AnyShapeStyle(hovering ? Palette.rim : Palette.wash))
                )
                .opacity(prominent && hovering ? 0.85 : 1)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { hovering = $0 }
    }
}

/// An icon and its words closer together than a Label's.
private struct TightLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.font(.system(size: 9))
            configuration.title
        }
    }
}
