import AppKit
import SwiftUI
import os

/// The whole window: the sidebar, and the page beside it, on the window's
/// glass: the page and its address bar as one card with rounded corners,
/// clear of the window's edges. With the sidebar collapsed the card takes
/// the whole window, and the sidebar comes out over it while the pointer is
/// at the window's left edge.
///
/// The card's left edge slides with the sidebar, and the page with it, but
/// the page is resized only once, where the card's right edge hides it:
/// WebKit redraws a resized page a frame or more late (on macOS 26, with no
/// way to wait for it), and resized all the way it would judder, and show
/// blank strips. Going, the sidebar leaves the page its whole width at once,
/// and the part that doesn't fit yet waits past the card's right edge; coming,
/// the page slides aside as it is, and takes its narrower width once the
/// sidebar is in. (After driceroland/Search.)
///
/// With the tabs across the top (Settings › Appearance › Tab style), the
/// sidebar goes, and the card starts right under them, the tab on screen
/// running into it.
struct BrowserView: View {
    let browser: Browser
    let window: NSWindow

    /// The collapsed sidebar, out over the page.
    @State private var peeking = false
    @State private var overPeek = false
    @State private var downloadsShown = false
    @State private var aiChatsShown = false
    @State private var menuShown = false
    /// The page is laid out beside the sidebar (see `laidOut`).
    @State private var docked = true
    @AppStorage("sidebarWidth") private var sidebarWidth = Sidebar.defaultWidth
    /// The window went full screen for a page, and comes back with it.
    @State private var fullScreenForPage = false
    @AppStorage(TabStyle.key) private var tabStyle = TabStyle.vertical

    /// A page shows one of its elements (a video) over the whole window: the
    /// sidebar keeps out of the way until it is done.
    private var pageFullscreen: Bool { browser.fullscreenTab != nil }
    private var sidebarShown: Bool { (browser.sidebarOpen || peeking) && !pageFullscreen }
    /// The tabs across the top of the window, in place of the sidebar.
    private var horizontal: Bool { tabStyle == .horizontal }
    /// What holds the tabs, the sidebar or the strip across the top, is on screen.
    private var tabsShown: Bool { horizontal ? !pageFullscreen : sidebarShown }

    /// The page, and the address bar over it, sit as one card on the window's
    /// glass, clear of its edges by this much, their corners rounded by this.
    static let margin: CGFloat = 6
    static let cornerRadius: CGFloat = 10
    /// The card's hairline edge, which the tab on screen across the top wears too.
    static let edge = Color.primary.opacity(0.12)
    private var margin: CGFloat { pageFullscreen ? 0 : Self.margin }
    /// A sidebar the page is laid out beside, when it is open.
    private var docks: Bool { !pageFullscreen && !horizontal }
    /// Where the card's left edge is: past the open sidebar, or the margin.
    /// It slides as the sidebar does.
    private var inset: CGFloat { max(browser.sidebarOpen && docks ? sidebarWidth : 0, margin) }
    /// Where the page is laid out from: as `inset`, but changed in one step,
    /// as the sidebar starts to go and once it has fully come.
    private var laidOut: CGFloat { max(docked && docks ? sidebarWidth : 0, margin) }
    /// Where the card's top edge is: under the tabs, when they are across the
    /// top, or the margin.
    private var top: CGFloat { horizontal && !pageFullscreen ? TabStrip.height : margin }

    var body: some View {
        ZStack(alignment: .leading) {
            // The window's glass, around the card as under the sidebar; it
            // moves the window, as the title bar under it would.
            SidebarGlass(incognito: browser.isPrivate)
                .overlay { Color.clear.contentShape(Rectangle()).titleBar() }

            PageCard(browser: browser, inset: inset, laidOut: laidOut, rounded: margin > 0)
                .padding(.top, pageFullscreen ? 0 : top + AddressBar.height)
                .padding([.bottom, .trailing], margin)
                .padding(.leading, inset)

            if !pageFullscreen {
                // Beside the sidebar, and under it while it is out over the page.
                AddressBar(browser: browser, horizontal: horizontal)
                    .padding(.leading, inset)
                    .padding(.trailing, margin)
                    .padding(.top, top)
                    .frame(maxHeight: .infinity, alignment: .top)
                // With the tabs across the top, drawn over them instead (below).
                if !horizontal { cardEdge(gap: nil) }
            }

            if horizontal {
                if !pageFullscreen {
                    TabStrip(browser: browser, downloadsShown: $downloadsShown, menuShown: $menuShown)
                        .frame(maxHeight: .infinity, alignment: .top)
                }
            } else {
                // Always there, slid off to the left when not wanted, rather than
                // added and taken away, so it comes back as it was left (scrolled
                // where it was) without being built again.
                Sidebar(browser: browser, pinned: browser.sidebarOpen, downloadsShown: $downloadsShown,
                        aiChatsShown: $aiChatsShown, menuShown: $menuShown, width: $sidebarWidth)
                    .onHover { overPeek = $0 }
                    // Far enough that its shadow goes too.
                    .offset(x: sidebarShown ? 0 : -(sidebarWidth + 32))
                    .allowsHitTesting(sidebarShown)
                    .accessibilityHidden(!sidebarShown)

                if !sidebarShown, !pageFullscreen {
                    // A sliver along the edge, narrow enough not to get in the page's way.
                    Color.clear
                        .frame(width: 6)
                        .contentShape(Rectangle())
                        .onHover { if $0 { withAnimation(.slide) { peeking = true } } }
                }
            }
        }
        .overlayPreferenceValue(SelectedTabKey.self) { tab in
            if horizontal, !pageFullscreen {
                GeometryReader { window in
                    cardEdge(gap: tab.map { window[$0].insetBy(dx: -TabStrip.flare, dy: 0) })
                }
            }
        }
        .overlay {
            if menuShown, tabsShown {
                ZStack(alignment: horizontal ? .topTrailing : .bottomLeading) {
                    // A click anywhere else puts it away, as it does a system menu.
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture(perform: closeMenu)
                    SidebarMenu(browser: browser, fromTop: horizontal, close: closeMenu)
                        // Just above its button, in the sidebar's bottom corner,
                        // or just under it, at the tabs' far end.
                        .padding(horizontal ? .trailing : .leading, 8)
                        .padding(horizontal ? .top : .bottom, horizontal ? TabStrip.height : 46)
                        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: horizontal ? .topTrailing : .bottomLeading)))
                }
            }
        }
        .overlay {
            if browser.commandBarOpen {
                // The window dimmed under it, so it stands out on any page; a
                // click anywhere outside it puts it away.
                Color.black.opacity(0.2)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: browser.hideCommandBar)
                    .transition(.opacity)
            }
        }
        .overlay {
            if browser.commandBarOpen {
                GeometryReader { window in
                    ZStack(alignment: .top) {
                        CommandBar(
                            text: "",
                            place: .switcher,
                            go: { url in
                                browser.go(to: url)
                                browser.hideCommandBar()
                            },
                            dismiss: browser.hideCommandBar,
                            requests: browser.commandBarRequests,
                            tabs: browser.tabs.filter { $0.id != browser.selectedID },
                            select: { id in
                                browser.selectedID = id
                                browser.hideCommandBar()
                            },
                            history: browser.history
                        )
                        .padding(.horizontal, 12)
                        // Pinned by its top edge, a third of the way down, so the
                        // field stays put while the list under it grows and shrinks.
                        .padding(.top, window.size.height * 0.3)
                    }
                    // Across the middle of the window.
                    .frame(width: window.size.width)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .overlay {
            if let releases = Updater.shared.news {
                WhatsNew(releases: releases) { withAnimation(.easeOut(duration: 0.2)) { Updater.shared.news = nil } }
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        // What is under the lock (tab titles) is hidden from accessibility too.
        .accessibilityHidden(browser.locked)
        .overlay {
            if browser.locked { IncognitoLock() }
        }
        .ignoresSafeArea()
        // The traffic lights belong to the sidebar: they go as soon as it starts
        // to, and come once it has all but arrived, so that nothing sits on the
        // page on its own and the sidebar's toggle never slides across them.
        // Across the top, they are the tabs'. Locked, they stay, to close the
        // window without unlocking it.
        .task(id: tabsShown || browser.locked) {
            let shown = tabsShown || browser.locked
            if shown {
                try? await Task.sleep(for: .milliseconds(180))
                if Task.isCancelled { return }
            }
            window.showTrafficLights(shown)
        }
        .onChange(of: browser.sidebarOpen) { _, open in
            // Pinning it puts the floating one away (it stays where it is, now pinned).
            peeking = false
            // Going: the page takes the whole window at once, under the sidebar
            // as it slides off.
            if !open { docked = false }
        }
        // Coming: the page makes room once the sidebar has slid all the way in
        // over it (at once, if it came without animation).
        .transaction(value: browser.sidebarOpen) { transaction in
            guard browser.sidebarOpen else { return }
            transaction.addAnimationCompletion { docked = browser.sidebarOpen }
        }
        .onChange(of: browser.commandBarOpen) { if browser.commandBarOpen { peeking = false } }
        .onChange(of: tabsShown) { if !tabsShown { menuShown = false } }
        .onChange(of: tabStyle) {
            menuShown = false
            window.toolbarStyle = tabStyle.toolbarStyle
        }
        // As Chrome does: the window goes full screen with the page, unless it
        // already was, and comes back with it. Asked again once a transition
        // ends, as macOS ignores what is asked during one.
        .onChange(of: pageFullscreen) { matchWindowToPage() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification, object: window)) { _ in
            matchWindowToPage()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification, object: window)) { _ in
            fullScreenForPage = false
            matchWindowToPage()
        }
        // Leaving full screen from the window (its green button, ⌃⌘F) takes the page out too.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willExitFullScreenNotification, object: window)) { _ in
            fullScreenForPage = false
            browser.exitPageFullscreen()
        }
        // Leaving it puts it away, as quickly as it came: the moment waited is
        // only for the pointer to be seen over it once it has slid out. The
        // downloads list, the AI chats or the menu open from it holds it out.
        .task(id: peeking && !overPeek && !downloadsShown && !aiChatsShown && !menuShown) {
            guard peeking, !overPeek, !downloadsShown, !aiChatsShown, !menuShown else { return }
            try? await Task.sleep(for: .milliseconds(80))
            if !Task.isCancelled { withAnimation(.slide) { peeking = false } }
        }
    }

    /// The card's edge, a hairline all round: it holds the card apart from the
    /// glass when the page is as light or dark as it. Across the top, it
    /// leaves a `gap` for the tab on screen to run into the card.
    private func cardEdge(gap: CGRect?) -> some View {
        RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
            .strokeBorder(Self.edge)
            .padding(.leading, inset)
            .padding([.bottom, .trailing], margin)
            .padding(.top, top)
            .mask { EdgeGap(gap: gap ?? .zero).fill(style: FillStyle(eoFill: true)) }
            .allowsHitTesting(false)
    }

    private func closeMenu() {
        withAnimation(SidebarMenu.animation) { menuShown = false }
    }

    private func matchWindowToPage() {
        let windowFullScreen = window.styleMask.contains(.fullScreen)
        if pageFullscreen, !windowFullScreen {
            fullScreenForPage = true
            window.toggleFullScreen(nil)
        } else if !pageFullscreen, fullScreenForPage, windowFullScreen {
            window.toggleFullScreen(nil)
        }
    }
}

/// The page, and what goes over it, in the card: a view of its own, so that
/// switching tabs, which changes only this, doesn't make the whole window's
/// view (`BrowserView`) be worked out again.
private struct PageCard: View {
    let browser: Browser
    /// See `BrowserView.inset` and `BrowserView.laidOut`.
    let inset: CGFloat
    let laidOut: CGFloat
    /// Its lower corners, clear of the window's edges; square when it runs up
    /// to them (a page in full screen, the tabs across the top).
    let rounded: Bool

    var body: some View {
        let radius = rounded ? BrowserView.cornerRadius : 0
        return ZStack {
            // A new tab, and round the settings' card, the window's glass tinted.
            if browser.selected?.isBlank == true { browser.isPrivate ? Palette.ground : Palette.glass }
            else if browser.selected?.settings != nil || browser.selected?.showsHistory == true { Palette.panel }
            else if browser.selected?.responsive != nil { Palette.stage }
            else { Palette.ground }
            VStack(spacing: 0) {
                if let tab = browser.selected, tab.hasPage, let responsive = tab.responsive, !browser.locked {
                    ResponsiveBar(tab: tab, responsive: responsive)
                }
                // Its own width, not the card's: see the top.
                Overhang(inset: inset, laidOut: laidOut) {
                    PageView(
                        tabs: browser.tabs,
                        // Locked, no page shows, nor can be read out from under the lock.
                        selected: browser.locked ? nil : browser.selected,
                        takesFocus: !browser.commandBarOpen
                    )
                }
            }
            if let tab = browser.selected, tab.isBlank, browser.isPrivate {
                IncognitoPage(browser: browser)
                    .id(tab.id)
            } else if let tab = browser.selected, tab.isBlank {
                // A new tab: its picture across the page, where to go a third
                // of the way down it, and under all, what picture to show.
                // The field comes last, so its list of suggestions goes over the rest.
                if let picture = Backdrop.shared.image {
                    BackdropView(image: picture)
                        // A view of its own for each picture: the next one
                        // fades in over the last already filling the page,
                        // rather than growing into it.
                        .id(ObjectIdentifier(picture))
                        .transition(.opacity)
                }
                WallpaperPicker()
                GeometryReader { page in
                    CommandBar(
                        text: "",
                        place: .newTab,
                        go: { browser.selected?.go(to: $0) },
                        dismiss: {},
                        requests: browser.newTabRequests,
                        history: browser.history
                    )
                    .padding(.horizontal, 12)
                    .padding(.top, page.size.height * 0.3)
                    .frame(maxWidth: .infinity)
                }
                // Each new tab starts with an empty field.
                .id(tab.id)
                .onAppear { Backdrop.shared.load() }
            }
            if let tab = browser.selected, tab.settings != nil {
                SettingsView(browser: browser, tab: tab)
            }
            if browser.selected?.showsHistory == true {
                HistoryPage(browser: browser)
            }
            if let failure = browser.selected?.failure {
                // Switched in with the tab, as the page is: faded, it would
                // show the blank page under it, and linger over the next.
                PageFailure(message: failure.message)
                    .background(Palette.ground)
                    .transition(.identity)
            }
        }
        // Another tab comes as it is, at once: a new tab's field and picture,
        // opened with the sidebar's slide, would otherwise slide into place too.
        .transaction(value: browser.selectedID) { $0.animation = nil }
        // The card's lower corners, and its right edge, past which the page
        // may reach while the sidebar slides.
        .mask {
            UnevenRoundedRectangle(bottomLeadingRadius: radius, bottomTrailingRadius: radius, style: .continuous)
        }
        .overlay {
            if let tab = browser.selected, tab.isOnThisMac, tab.hasPage, !browser.locked {
                HazardTape(shape: UnevenRoundedRectangle(bottomLeadingRadius: radius, bottomTrailingRadius: radius,
                                                         style: .continuous))
            }
        }
        .overlay(alignment: .topTrailing) {
            // A new tab, or the settings, has no page to look in.
            if browser.findBarOpen, browser.selected?.hasPage == true {
                FindBar(browser: browser)
                    .padding(12)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .overlay(alignment: .top) {
            if let offer = browser.passwordOffer, offer.tab == browser.selectedID {
                PasswordOfferBar(browser: browser, offer: offer)
                    .padding(.top, 12)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .overlay(alignment: .topLeading) {
            if let choices = browser.passwordChoices, choices.tab == browser.selectedID, !browser.commandBarOpen {
                PasswordChoicesView(browser: browser, choices: choices)
                    .offset(x: choices.spot.minX, y: choices.spot.maxY + 4)
            }
        }
    }
}

/// Amber and black along a shape's edge, as Arc marks a page being worked
/// on: here, one from a server on this Mac (Developer Mode).
struct HazardTape<S: InsettableShape>: View {
    let shape: S
    var width: CGFloat = 3

    var body: some View {
        ZStack {
            shape.strokeBorder(Color(white: 0.1), lineWidth: width)
            shape.strokeBorder(Palette.dev, style: StrokeStyle(lineWidth: width, dash: [10, 8]))
        }
        .allowsHitTesting(false)
    }
}

/// The page in the card, as wide as it is laid out rather than as the card is
/// at this moment of the sidebar's slide: past the card's right edge by how
/// far the card's left edge (`inset`, sliding) is from where the page is laid
/// out from (`laidOut`, in one step). The card is the size it is given, so
/// the page reaching past it never makes the window any wider.
private struct Overhang: Layout {
    var inset: CGFloat
    let laidOut: CGFloat

    /// Only the edge slides; the page's own width changes in one step.
    var animatableData: CGFloat {
        get { inset }
        set { inset = newValue }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let width = max(bounds.width + inset - laidOut, 0)
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: width, height: bounds.height))
    }
}

/// The browser's window. A key nothing wanted (the page let it by, and no
/// menu has it) ends here, where AppKit would beep for it: browsers stay quiet.
final class BrowserWindow: NSWindow {
    let browser: Browser

    /// The whole screen short of the menu bar and Dock, every time. Not the
    /// frame it was left at: one stray resize would otherwise stick for good.
    /// An incognito window is always dark, and its own colours (see
    /// `IncognitoPage`), so it is plain which window is which.
    init(browser: Browser) {
        self.browser = browser
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        // No visible title bar: the sidebar runs up to the top edge and the traffic
        // lights sit on it. An empty unified toolbar makes the title bar 52pt tall,
        // which brings the lights down to the middle of the sidebar's top row, level
        // with the middle of the address bar (see `Sidebar.topRow`).
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        toolbar = NSToolbar()
        toolbarStyle = TabStyle.current.toolbarStyle
        isReleasedWhenClosed = false
        // Up in the title bar AppKit moves the window for a drag that starts
        // anywhere, a tab across the top included: only what is a title bar
        // (`titleBar`: the glass, the bars) moves it.
        isMovable = false
        contentMinSize = NSSize(width: 640, height: 420)
        // The name the Window menu lists it by.
        title = browser.isPrivate ? "Incognito" : "Nerda"
        if browser.isPrivate { appearance = NSAppearance(named: .darkAqua) }
        // Sized before it has content, so the content is laid out once, at that size.
        fill(NSScreen.main)
        // The Dock hidden or shown, or the display changed: the screen's free
        // part is another size, and a window still filling it follows.
        NotificationCenter.default.addObserver(
            self, selector: #selector(screenChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
        contentView = NSHostingView(rootView: BrowserView(browser: browser, window: self)
            .environment(\.incognito, browser.isPrivate))
        browser.window = self
    }

    /// The frame `fill` last gave it: still this, the window was left filling the screen.
    private var filled = NSRect.zero

    private func fill(_ screen: NSScreen?) {
        guard let screen else { return }
        filled = screen.visibleFrame
        setFrame(filled, display: isVisible)
    }

    /// When the Dock shows, AppKit shrinks a window it covers, but never grows
    /// it back when the Dock hides: one filling either size is sized anew.
    @objc private func screenChanged() {
        guard let screen = screen ?? NSScreen.main else { return }
        if frame == filled || frame == screen.visibleFrame { fill(screen) }
    }

    override func noResponder(for eventSelector: Selector) {
        if eventSelector == #selector(keyDown(with:)) { return }
        super.noResponder(for: eventSelector)
    }
}

extension View {
    /// Works as a title bar: dragged, it moves the window; double-clicked, it
    /// does what System Settings says (Desktop & Dock › Double-click a
    /// window's title bar), as the window's own title bar would.
    func titleBar() -> some View {
        gesture(WindowDragGesture())
            .onTapGesture(count: 2) { NSApp.keyWindow?.titleBarDoubleClicked() }
    }
}

extension NSWindow {
    /// Fill the screen (zoom, and back), minimize, or nothing: Fill unless
    /// another is chosen.
    func titleBarDoubleClicked() {
        switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
        case "Minimize": performMiniaturize(nil)
        case "None": break
        default: performZoom(nil)
        }
    }

    /// Faded rather than switched, and hidden once faded, so an invisible
    /// close button can't be clicked on the page.
    func showTrafficLights(_ shown: Bool) {
        let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap(standardWindowButton)
        if shown { buttons.forEach { $0.isHidden = false } }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = shown ? 0.15 : 0.1
            buttons.forEach { $0.animator().alphaValue = shown ? 1 : 0 }
        } completionHandler: {
            MainActor.assumeIsolated {
                buttons.forEach { $0.isHidden = $0.alphaValue == 0 }
            }
        }
    }
}

/// What the menu and the buttons both do, animated the same way from either.
extension Browser {
    /// ⌘T, and New Tab in the sidebar.
    func newTab() {
        if commandBarOpen { hideCommandBar() }
        endAddressEdit()
        let tab = Tab()
        withAnimation(.slide) { add(tab) }
        // An extension's new tab page, once you said it may be one.
        if !isPrivate, let page = Extensions.shared.newTabPage { return tab.go(to: page) }
        newTabRequests += 1
        if !isPrivate { Extensions.shared.offerNewTabPage(into: tab) }
    }

    /// ⌘, and Settings in the sidebar's menu: the settings, in a tab of their
    /// own, and only ever one, as in Chrome.
    func openSettings(_ page: SettingsPage? = nil) {
        // Nerda's own pages open in the regular window, as in Chrome.
        if isPrivate { return Windows.showRegular().openSettings(page) }
        if commandBarOpen { hideCommandBar() }
        endAddressEdit()
        if let open = tabs.first(where: { $0.settings != nil }) {
            if let page { open.settings = page }
            return selectedID = open.id
        }
        let tab = Tab()
        tab.settings = page ?? .general
        withAnimation(.slide) { add(tab) }
    }

    /// ⌘Y, and Show All History in the menus: every page visited, in a tab
    /// of its own, and only ever one, as the settings are.
    func openHistory() {
        if isPrivate { return Windows.showRegular().openHistory() }
        if commandBarOpen { hideCommandBar() }
        endAddressEdit()
        if let open = tabs.first(where: \.showsHistory) { return selectedID = open.id }
        let tab = Tab()
        tab.showsHistory = true
        withAnimation(.slide) { add(tab) }
    }

    /// Clear History…, in the menus and on the history page: the history page,
    /// with Delete browsing data over it.
    func clearHistory() {
        if isPrivate { return Windows.showRegular().clearHistory() }
        openHistory()
        clearingHistory = true
    }

    /// ⌥⌘U: the page's source, in a tab of its own beside it.
    func viewSource() {
        guard let site = selected?.site, site.scheme != ViewSource.scheme, let url = ViewSource.url(for: site) else { return }
        withAnimation(.slide) { open(url) }
    }

    /// ⌥⌘R: Responsive Design Mode on, at the page's own size, or off.
    func toggleResponsive() {
        guard let tab = selected, tab.hasPage else { return }
        tab.responsive = tab.responsive == nil ? Responsive(fitting: tab) : nil
    }

    /// Somewhere picked from the switcher or the History menu: on the new tab
    /// on screen, if that is where you are, or else in a tab of its own.
    func go(to url: URL) {
        if let tab = selected, tab.isBlank { tab.go(to: url) } else { withAnimation(.slide) { open(url) } }
    }

    func showCommandBar() {
        withAnimation(.easeOut(duration: 0.14)) {
            editingAddress = false
            commandBarOpen = true
        }
        commandBarRequests += 1
    }

    /// ⌘L, or a click on the address: the address made editable where it is,
    /// to take the tab on screen somewhere else, a new tab's too. On the
    /// settings, which have no address to edit, the command bar.
    func editAddress() {
        guard let selected else { return newTab() }
        guard selected.settings == nil else { return showCommandBar() }
        exitPageFullscreen()
        if commandBarOpen { withAnimation(.easeOut(duration: 0.14)) { commandBarOpen = false } }
        editingAddress = true
        commandBarRequests += 1
    }

    /// The copy button: the tab's address on the clipboard.
    func copyLink() {
        guard let site = selected?.site else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(site.absoluteString, forType: .string)
    }

    /// The address back as it was, and the keyboard back on the page, or a
    /// new tab's field.
    func endAddressEdit() {
        guard editingAddress else { return }
        editingAddress = false
        focusPage()
        if selected?.isBlank == true { newTabRequests += 1 }
    }

    func hideCommandBar() {
        withAnimation(.easeOut(duration: 0.14)) { commandBarOpen = false }
        // The keyboard goes back to the page it was taken from, or a new tab's
        // field. A page that is only now opening has no window yet, and takes
        // it once it does.
        focusPage()
        if selected?.isBlank == true { newTabRequests += 1 }
    }

    func showFindBar() {
        withAnimation(.easeOut(duration: 0.14)) { findBarOpen = true }
        findRequests += 1
    }

    /// Puts the find bar away, and the keyboard back on the page.
    func hideFindBar() {
        withAnimation(.easeOut(duration: 0.14)) { findBarOpen = false }
        focusPage()
    }

    func toggleSidebar() {
        withAnimation(.slide) { sidebarOpen.toggle() }
    }

    /// ⌘W. With the switcher up it is the switcher that goes, not the page
    /// behind it. A pinned tab keeps its tile but its page goes, memory and
    /// all, as Arc's does: a click on the tile opens it again. The screen goes
    /// back to the last tab below the tiles you were on, the first there, or
    /// a new tab.
    func closeSelectedTab() {
        if commandBarOpen { return hideCommandBar() }
        guard let selected else { return }
        if selected.isPinned {
            if let next = recent.last(where: { !$0.isPinned }) ?? tabs.first(where: { !$0.isPinned }) {
                selectedID = next.id
            } else {
                add(Tab())
            }
            Task {
                let look = await selected.snapshot()
                if selected.id != selectedID { selected.sleep(keeping: look) }
            }
            return
        }
        let id = selected.id
        withAnimation(.slide) { close(id) }
    }
}

// Nerda run again only to compile the block list (see Blocker), not as a browser.
if CommandLine.arguments.contains(Blocker.compileArgument) { Blocker.compileAndExit() }

let app = NSApplication.shared
app.setActivationPolicy(.regular)
// Tabs are ours; no system tab bar, and no Show Tab Bar items in the menus.
NSWindow.allowsAutomaticWindowTabbing = false
SpellCheck.registerDefault()
Theme.apply()

let browser = Browser()
History.shared.load(from: History.file)
// Before the tabs: those of bookmarks are told by them.
Bookmarks.shared.load(from: Bookmarks.file)
Favicons.shared.folder = Favicons.folder
browser.restore(from: Session.file)
Favicons.shared.preload(browser.tabs.compactMap(\.site))
// Ready before the first new tab, so it opens with its picture already there.
Backdrop.shared.load()
// Once the window is up: a page's process ready for the first page, and what
// typing in the address bar looks through.
DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
    Tab.warmUp()
    History.shared.prepare()
}
let menu = AppMenu(browser: browser)
menu.install()
if Edition.updates { Updater.shared.start() }

let window = BrowserWindow(browser: browser)
Windows.regular = window
window.makeKeyAndOrderFront(nil)
// Once the window is up: loading them takes the main thread a while.
DispatchQueue.main.async { Extensions.shared.start(for: browser) }

#if DEBUG
// Nerda Dev: which view each key goes to, for when keys stop reaching a
// page. `/usr/bin/log show --last 5m --predicate 'subsystem == "dev.nerda.browser.debug"'`
let keyLog = Logger(subsystem: "dev.nerda.browser.debug", category: "keys")
NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
    let responder = event.window?.firstResponder.map { String(describing: type(of: $0)) } ?? "none"
    let hidden = (event.window?.firstResponder as? NSView)?.isHiddenOrHasHiddenAncestor == true
    // Which key, private: the log is kept, and would spell out passwords typed.
    keyLog.notice("key \(event.keyCode, privacy: .private) to \(responder, privacy: .public)\(hidden ? " (hidden)" : "", privacy: .public)")
    return event
}
#endif

let delegate = AppDelegate(window: window, browser: browser)
app.delegate = delegate
window.delegate = delegate
// SIGTERM (`kill`, and watch.sh putting in a new build) would end the app on
// the spot; the tabs and history are saved first.
signal(SIGTERM, SIG_IGN)
let terminated = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
terminated.setEventHandler {
    MainActor.assumeIsolated { delegate.save() }
    exit(0)
}
terminated.resume()

#if DEBUG
Bench.start(browser, window)
#endif
// Not activated here: macOS brings Nerda forward when it is opened, and leaves
// it behind when asked to (`open -g`, watch.sh).
app.run()
