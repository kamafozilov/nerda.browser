import AppKit
import SwiftUI
@preconcurrency import Translation
import os

/// The whole window: the sidebar, and the page beside it, on the window's
/// glass: the page and its address bar as one card with rounded corners,
/// clear of the window's edges. With the sidebar collapsed the card takes
/// the whole window, and the sidebar comes out over it while the pointer is
/// at the window's left edge.
///
/// Putting the sidebar away and bringing it back moves one edge, the card's
/// left one: the sidebar slides off whole, its top row with it, and the card,
/// address bar and page, grows after it, under the window's buttons, which
/// stay. Nothing is switched or faded on the way, so every frame of it is
/// the window as it could stand: glass with the sidebar on it, then the card.
///
/// The page slides with the card's edge, but is resized only once, where the
/// card's right edge hides it: WebKit redraws a resized page some frames
/// late, and resized on every frame it shows strips it hasn't drawn, as wide
/// as a tenth of the window, and its content trails the edge. Going, the
/// sidebar leaves the page its whole width at once, and the part that doesn't
/// fit yet waits past the card's right edge; coming, the page slides aside as
/// it is, and takes its narrower width once the sidebar is in. So the page is
/// always laid out at the wider of the two widths while it moves, and nothing
/// of it is ever missing. (After driceroland/Search.)
///
/// With the tabs across the top (Settings › Appearance › Tab style), the
/// sidebar goes, and the card starts right under them, the tab on screen
/// running into it.
struct BrowserView: View {
    let browser: Browser
    let window: NSWindow

    /// The collapsed sidebar, out over the page.
    @State private var peeking = false
    /// It came out over the page, and wears its own glass there (see
    /// `Sidebar.floating`): from when it comes out until it has gone again,
    /// or is pinned with the page moved aside from under it.
    @State private var floating = false
    @State private var overPeek = false
    @State private var downloadsShown = false
    /// Brought out for the downloads list, which opens once it is there:
    /// it stays out until then, wherever the pointer is.
    @State private var opensDownloads = false
    @State private var aiChatsShown = false
    @State private var menuShown = false
    /// The page is laid out beside the sidebar (see `laidOut`): from the
    /// start, if the sidebar is open then.
    @State private var docked: Bool
    @AppStorage("sidebarWidth") private var sidebarWidth = Sidebar.defaultWidth
    /// The window went full screen for a page, and comes back with it.
    @State private var fullScreenForPage = false
    @AppStorage(TabStyle.key) private var tabStyle = TabStyle.vertical
    @Environment(\.motionReduced) private var motionReduced
    /// Reduce Motion: the Mac's, unless the view is given its own.
    private var reduced: Bool { motionReduced ?? Motion.reduced }

    init(browser: Browser, window: NSWindow) {
        self.browser = browser
        self.window = window
        _docked = State(initialValue: browser.sidebarOpen)
    }

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
    static let edge = Palette.edge
    private var margin: CGFloat { pageFullscreen ? 0 : Self.margin }
    /// A sidebar the page is laid out beside, when it is open.
    private var docks: Bool { !pageFullscreen && !horizontal }
    /// Where the card's left edge is: past the open sidebar, or the margin.
    /// It slides as the sidebar does.
    private var inset: CGFloat { max(browser.sidebarOpen && docks ? sidebarWidth : 0, margin) }
    /// The room the address bar leaves at its start, on its own ground: with
    /// the sidebar put away, the window's buttons sit there, on the bar, so
    /// its buttons start past them, and the bar runs on under them to the
    /// card's edge, one with it, rather than leave a block of glass.
    private var barRoom: CGFloat { horizontal ? 0 : max(Self.trafficLightsWidth - inset, 0) }
    /// The window's three buttons, from its left edge, and a gap after them.
    static let trafficLightsWidth: CGFloat = 84
    /// Where the page is laid out from: as `inset`, but changed in one step,
    /// as the sidebar starts to go and once it has fully come.
    private var laidOut: CGFloat { max(docked && docks ? sidebarWidth : 0, margin) }
    /// How far off to the left the sidebar is slid when it isn't wanted: as
    /// far as the card's edge goes, so the two move as one, its right edge on
    /// the card's left all the way; from out over the page, far enough that
    /// its shadow goes too. With Reduce Motion it fades in and out where it
    /// is instead.
    private var sidebarSlid: CGFloat {
        if sidebarShown || reduced { return 0 }
        return floating ? -(sidebarWidth + 32) : margin - sidebarWidth
    }
    /// Where the card's top edge is: under the tabs, when they are across the
    /// top, or the margin.
    private var top: CGFloat { horizontal && !pageFullscreen ? TabStrip.height : margin }
    /// The sidebar wears glass of its own (`Sidebar.floating`): out over the
    /// page. With Reduce Motion it never slides clear of the page, but fades
    /// in and out where it is, so it wears it whenever the page isn't laid
    /// out beside it.
    private var sidebarFloats: Bool { floating || (reduced && !(browser.sidebarOpen && docked)) }

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
                AddressBar(browser: browser, horizontal: horizontal, room: barRoom)
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
                        // Read here, over the whole window as the strip is, and
                        // not around it all: there every view's preference is
                        // gathered on each change, the sidebar's rows included.
                        .overlayPreferenceValue(SelectedTabKey.self) { tab in
                            GeometryReader { window in
                                cardEdge(gap: tab.map { window[$0].insetBy(dx: -TabStrip.flare, dy: 0) })
                            }
                        }
                }
            } else {
                // Always there, slid off to the left when not wanted, rather than
                // added and taken away, so it comes back as it was left (scrolled
                // where it was) without being built again.
                Sidebar(browser: browser, pinned: browser.sidebarOpen, floating: sidebarFloats,
                        downloadsShown: $downloadsShown, aiChatsShown: $aiChatsShown,
                        menuShown: $menuShown, width: $sidebarWidth)
                    // Only out over the page does it matter: pinned, the pointer
                    // coming and going would have the whole window worked out again.
                    .onHover { over in if peeking || overPeek { overPeek = over } }
                    .offset(x: sidebarSlid)
                    .animation(Motion.fade) { $0.opacity(sidebarShown || !reduced ? 1 : 0) }
                    .allowsHitTesting(sidebarShown)
                    .accessibilityHidden(!sidebarShown)

                if !sidebarShown, !pageFullscreen {
                    // A sliver along the edge, narrow enough not to get in the page's way.
                    Color.clear
                        .frame(width: 6)
                        .contentShape(Rectangle())
                        .onHover { if $0 { peek() } }
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
                        .transition(Motion.moving(.opacity.combined(with: .scale(scale: 0.96, anchor: horizontal ? .topTrailing : .bottomLeading))))
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
                .transition(Motion.moving(.opacity.combined(with: .scale(scale: 0.98))))
            }
        }
        .overlay {
            if let releases = Updater.shared.news {
                WhatsNew(releases: releases) { withAnimation(.easeOut(duration: 0.2)) { Updater.shared.news = nil } }
                    .transition(Motion.moving(.opacity.combined(with: .scale(scale: 0.98))))
            }
        }
        // What is under the lock (tab titles) is hidden from accessibility too.
        .accessibilityHidden(browser.locked)
        .overlay {
            if browser.locked { IncognitoLock() }
        }
        // The window's buttons are always there, but over a page in full
        // screen; locked, they stay, to close the window without unlocking it.
        .onChange(of: pageFullscreen && !browser.locked, initial: true) { _, hidden in
            window.showTrafficLights(!hidden)
        }
        .background { TranslationTask(browser: browser) }
        .ignoresSafeArea()
        .onChange(of: browser.sidebarOpen) { _, open in
            // Pinning it puts the floating one away (it stays where it is, now pinned).
            peeking = false
            // Going: the page takes its whole width at once, and slides after
            // the sidebar with the card's edge.
            if !open {
                if docked, docks { browser.selected?.veilGrowth() }
                docked = false
            }
        }
        // Coming: the page makes room once the card's edge has slid all the way
        // aside (at once, if it came without animation), and a sidebar that
        // was out over it is then one with the window's glass.
        .transaction(value: browser.sidebarOpen) { transaction in
            guard browser.sidebarOpen else { return }
            transaction.addAnimationCompletion {
                docked = browser.sidebarOpen
                if docked { floating = false }
            }
        }
        .onChange(of: browser.commandBarOpen) {
            guard browser.commandBarOpen else { return }
            peeking = false
            if !browser.sidebarOpen { floating = false }
        }
        .onChange(of: browser.downloadsRequests) {
            if downloadsShown || pageFullscreen { return downloadsShown = false }
            guard !horizontal, !sidebarShown else { return downloadsShown = true }
            // A collapsed sidebar comes out first, as it does under the pointer,
            // and the list opens from its button once it is there.
            peek()
            opensDownloads = true
            Task {
                try? await Task.sleep(for: .milliseconds(250))
                downloadsShown = true
                opensDownloads = false
            }
        }
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
        .task(id: peeking && !overPeek && !downloadsShown && !opensDownloads && !aiChatsShown && !menuShown) {
            guard peeking, !overPeek, !downloadsShown, !opensDownloads, !aiChatsShown, !menuShown else { return }
            try? await Task.sleep(for: .milliseconds(80))
            if !Task.isCancelled { unpeek() }
        }
    }

    /// The collapsed sidebar comes out over the page, on glass of its own.
    private func peek() {
        withAnimation(.slide) {
            floating = true
            peeking = true
        }
    }

    /// And goes again. Its glass goes once it is out of sight; with Reduce
    /// Motion it fades where it is, and keeps it meanwhile.
    private func unpeek() {
        withAnimation(.slide) { peeking = false } completion: {
            if !peeking, !browser.sidebarOpen, !reduced { floating = false }
        }
    }

    /// The card's edge, a hairline all round: it holds the card apart from the
    /// glass when the page is as light or dark as it. Across the top, it
    /// leaves a `gap` for the tab on screen to run into the card.
    private func cardEdge(gap: CGRect?) -> some View {
        CardEdge(inset: inset, top: top, margin: margin, radius: Self.cornerRadius)
            .strokeBorder(Self.edge)
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

/// The card's outline, in the window: from `inset`, its left edge, which
/// slides with the sidebar.
nonisolated struct CardEdge: InsettableShape {
    var inset: CGFloat
    var top: CGFloat
    var margin: CGFloat
    var radius: CGFloat
    var inward: CGFloat = 0

    var animatableData: CGFloat {
        get { inset }
        set { inset = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let card = CGRect(x: inset, y: top, width: rect.maxX - margin - inset, height: rect.maxY - margin - top)
        return RoundedRectangle(cornerRadius: radius, style: .continuous).inset(by: inward).path(in: card)
    }

    func inset(by amount: CGFloat) -> CardEdge {
        var edge = self
        edge.inward += amount
        return edge
    }
}

/// Where the Mac asks to download a language, the first time a page is
/// translated into it; asked again for each pair the tab on screen is
/// translated between. A view of its own, as it reads the tab on screen and
/// its page's language: on the whole window's view, each tab switch and each
/// page the tab on screen loads would work all of that out again.
private struct TranslationTask: View {
    let browser: Browser

    var body: some View {
        Color.clear
            .translationTask(browser.translationConfiguration) { session in
                await browser.translator.run(session, in: browser)
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
        // The tab selected, or for a moment the one left while its video
        // floats: everything here shows that tab, the page and what stands
        // in for one (a new tab, the settings, a failure).
        let shown = browser.inSight
        return ZStack {
            // A new tab, and round the settings' card, the window's glass tinted.
            if shown?.isBlank == true { browser.isPrivate ? Palette.ground : Palette.glass }
            else if shown?.settings != nil || shown?.showsHistory == true { Palette.panel }
            else if shown?.responsive != nil { Palette.stage }
            else { Palette.ground }
            VStack(spacing: 0) {
                if let tab = shown, tab.hasPage, let responsive = tab.responsive, !browser.locked {
                    ResponsiveBar(tab: tab, responsive: responsive)
                }
                // Its own width, not the card's: see the top.
                Overhang(inset: inset, laidOut: laidOut) {
                    ZStack {
                        PageView(
                            tabs: browser.tabs,
                            // Locked, no page shows, nor can be read out from
                            // under the lock; nor under an Agent tab watched.
                            selected: browser.locked || browser.watchedTab != nil ? nil : shown,
                            takesFocus: !browser.commandBarOpen
                        )
                        if let reader = shown?.reader, !browser.locked {
                            ReaderView(page: reader, takesFocus: !browser.commandBarOpen)
                                .background(Palette.ground)
                                .id(ObjectIdentifier(reader))
                        }
                    }
                }
            }
            if let tab = shown, tab.isBlank, browser.isPrivate {
                IncognitoPage(browser: browser)
                    .id(tab.id)
            } else if let tab = shown, tab.isBlank {
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
            if let tab = shown, tab.settings != nil {
                SettingsView(browser: browser, tab: tab)
            }
            if shown?.showsHistory == true {
                HistoryPage(browser: browser)
            }
            if let failure = shown?.failure {
                // Switched in with the tab, as the page is: faded, it would
                // show the blank page under it, and linger over the next.
                PageFailure(browser: browser, failure: failure)
                    .background(Palette.ground)
                    .transition(.identity)
            }
            if let watched = browser.watched, browser.watchedTab != nil, !browser.locked {
                WatchedAgentTab(browser: browser, watched: watched)
            }
        }
        // Another tab comes as it is, at once: a new tab's field and picture,
        // opened with the sidebar's slide, would otherwise slide into place too.
        .transaction(value: shown?.id) { $0.animation = nil }
        // The card's lower corners, and its right edge, past which the page
        // may reach while the sidebar slides.
        .mask {
            UnevenRoundedRectangle(bottomLeadingRadius: radius, bottomTrailingRadius: radius, style: .continuous)
        }
        .overlay(alignment: .topTrailing) {
            // A new tab, or the settings, has no page to look in.
            if browser.findBarOpen, browser.selected?.hasPage == true {
                FindBar(browser: browser)
                    .padding(12)
                    .transition(Motion.moving(.opacity.combined(with: .move(edge: .top))))
            }
        }
        .overlay(alignment: .top) {
            if let tab = browser.selected, tab.asksAboutHang, !browser.locked {
                HungPageCard(tab: tab)
                    .padding(.top, 12)
                    .transition(Motion.moving(.opacity.combined(with: .move(edge: .top))))
            } else if let offer = browser.passwordOffer, offer.tab == browser.selectedID {
                VaultOfferCard(browser: browser, offer: offer)
                    .padding(.top, 12)
                    .transition(Motion.moving(.opacity.combined(with: .move(edge: .top))))
            } else if let offer = browser.autofillOffers.first(where: { $0.tab == browser.selectedID }) {
                AutoFillOfferBar(browser: browser, offer: offer)
                    .padding(.top, 12)
                    .transition(Motion.moving(.opacity.combined(with: .move(edge: .top))))
            }
        }
        .overlay(alignment: .bottom) {
            // An Agent tab shown here whose Agent waits on the owner.
            if let tab = browser.watchedTab ?? browser.selected, let request = AgentServer.shared.owner.handoff(on: tab),
               !browser.locked {
                HandoffBar(request: request, owner: AgentServer.shared.owner)
                    .padding(.bottom, 12)
                    .transition(Motion.moving(.opacity.combined(with: .move(edge: .bottom))))
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

    /// Where and at the size it was left (`WindowFrame`), as in Safari and
    /// Chrome; the whole screen short of the menu bar and Dock the first
    /// time. An incognito window opens where the regular one was left, and
    /// is always dark, and its own colours (see `IncognitoPage`), so it is
    /// plain which window is which.
    convenience init(browser: Browser) {
        self.init(browser: browser, filling: nil, remembered: true)
    }

    /// Filling `screen`, the main one's if none: a tab moved to a window of its own.
    convenience init(browser: Browser, filling screen: NSScreen?) {
        self.init(browser: browser, filling: screen ?? NSScreen.main, remembered: false)
    }

    private init(browser: Browser, filling screen: NSScreen?, remembered: Bool) {
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
        title = Self.title(of: browser)
        if browser.isPrivate { appearance = NSAppearance(named: .darkAqua) }
        // Sized before it has content, so the content is laid out once, at that size.
        if remembered { place() } else { fill(screen) }
        // The Dock hidden or shown, or the display changed: the screen's free
        // part is another size, and a window still filling it follows.
        NotificationCenter.default.addObserver(
            self, selector: #selector(screenChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
        if remembered, keepsFrame {
            for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.didExitFullScreenNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(remember), name: name, object: self)
            }
        }
        let content = NSHostingView(rootView: BrowserView(browser: browser, window: self)
            .environment(\.incognito, browser.isPrivate))
        contentView = content
        // The keyboard starts here, not on the first button: with Keyboard
        // navigation on, AppKit would hand it to the window's content, and
        // SwiftUI on to its first control, the sidebar's button, ringed in
        // blue as though Tab had been pressed. A page coming on screen takes
        // it from here (`PageView`); Tab goes on into the controls.
        let rest = KeyboardRest()
        content.addSubview(rest)
        initialFirstResponder = rest
        browser.window = self
    }

    /// The name the Window menu lists it by: its profile's, once there are profiles.
    static func title(of browser: Browser) -> String {
        browser.isPrivate ? "Incognito" : Profiles.shared.many ? browser.profile.name : "Nerda"
    }

    /// The frame `fill` (or `place`, filling) last gave it: still this, the
    /// window was left filling the screen.
    private var filled = NSRect.zero

    private func fill(_ screen: NSScreen?) {
        guard let screen else { return }
        filled = screen.visibleFrame
        setFrame(filled, display: isVisible)
    }

    /// Its profile's own window keeps its frame for the next launch; an
    /// incognito window, or a secondary one (see `Windows.moveToNewWindow`), doesn't.
    private var keepsFrame: Bool { !browser.isPrivate && !browser.isSecondary }
    /// Where it was left, on the screens there are now. Incognito, where the
    /// regular window was left, down and to the right of a window already there.
    private func place() {
        let screens = (NSScreen.main.map { [$0] } ?? []) + NSScreen.screens.filter { $0 != NSScreen.main }
        let visible = screens.map(\.visibleFrame)
        let saved = WindowFrame.saved(for: browser.isPrivate ? Profile.mainID : browser.profile.id)
        guard var placed = WindowFrame.place(saved, on: visible) else { return }
        if browser.isPrivate {
            let taken = NSApp.windows.filter { $0 is BrowserWindow && $0 !== self && $0.isVisible }.map(\.frame)
            placed = WindowFrame.place(placed.cascaded(past: taken), on: visible) ?? placed
        }
        if placed.fills { filled = placed.frame }
        setFrame(placed.frame, display: isVisible)
    }

    /// Moved, resized, or back from full screen: kept for the next launch,
    /// with whether it fills the screen. Not the frame of full screen (on
    /// the way in, the window already says it is), which would open the
    /// next time as a window over the whole display: the one before it stays.
    @objc private func remember() {
        guard !styleMask.contains(.fullScreen), !isMiniaturized, !Lab.isOn else { return }
        WindowFrame(frame: frame, fills: frame == filled || frame == screen?.visibleFrame).save(for: browser.profile.id)
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

    // A lab run's window (Lab): off every screen, behind, never key, never
    // full screen; a page's full screen stays inside it.
    override var canBecomeKey: Bool { Lab.isOn ? false : super.canBecomeKey }
    override var canBecomeMain: Bool { Lab.isOn ? false : super.canBecomeMain }
    override func makeKeyAndOrderFront(_ sender: Any?) { Lab.isOn ? keepAway() : super.makeKeyAndOrderFront(sender) }
    override func orderFront(_ sender: Any?) { Lab.isOn ? keepAway() : super.orderFront(sender) }
    override func orderFrontRegardless() { Lab.isOn ? keepAway() : super.orderFrontRegardless() }
    override func toggleFullScreen(_ sender: Any?) { if !Lab.isOn { super.toggleFullScreen(sender) } }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        Lab.isOn ? frameRect : super.constrainFrameRect(frameRect, to: screen)
    }

    private func keepAway() {
        // No zoom of the window shown, which AppKit flies across the screen;
        // and out of Mission Control, which would show it among the owner's,
        // and of every Space switch, as Agent tabs' window is (AgentWindow).
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        isExcludedFromWindowsMenu = true
        Lab.park(self)
        orderBack(nil)
    }

    override func order(_ place: NSWindow.OrderingMode, relativeTo otherWindow: Int) {
        if Lab.isOn {
            animationBehavior = .none
            Lab.told("BrowserWindow ordered \(place.rawValue) at \(frame)")
        }
        super.order(place, relativeTo: otherWindow)
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
    /// close button can't be clicked on the page. Switched in a window out of
    /// sight, where a fade may never be drawn, and so never end.
    func showTrafficLights(_ shown: Bool) {
        let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap(standardWindowButton)
        guard occlusionState.contains(.visible) else {
            return buttons.forEach {
                $0.alphaValue = shown ? 1 : 0
                $0.isHidden = !shown
            }
        }
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
        if !isPrivate, Extensions.started, let page = Extensions.shared.newTabPage { return tab.go(to: page) }
        newTabRequests += 1
        if !isPrivate, Extensions.started { Extensions.shared.offerNewTabPage(into: tab) }
    }

    /// ⌘, and Settings in the sidebar's menu: the settings, in a tab of their
    /// own, and only ever one, as in Chrome.
    func openSettings(_ page: SettingsPage? = nil) {
        // Nerda's own pages open in the profile's own window, as in Chrome.
        if !keepsPins { return Windows.home(of: self).openSettings(page) }
        if commandBarOpen { hideCommandBar() }
        endAddressEdit()
        if let open = tabs.first(where: { $0.settings != nil }) {
            if let page { open.content = .settings(page) }
            return selectedID = open.id
        }
        let tab = Tab()
        tab.content = .settings(page ?? .general)
        withAnimation(.slide) { add(tab) }
    }

    /// ⌘Y, and Show All History in the menus: every page visited, in a tab
    /// of its own, and only ever one, as the settings are.
    func openHistory() {
        if !keepsPins { return Windows.home(of: self).openHistory() }
        if commandBarOpen { hideCommandBar() }
        endAddressEdit()
        if let open = tabs.first(where: \.showsHistory) { return selectedID = open.id }
        let tab = Tab()
        tab.content = .history
        withAnimation(.slide) { add(tab) }
    }

    /// Clear History…, in the menus and on the history page: the history page,
    /// with Delete browsing data over it.
    func clearHistory() {
        if !keepsPins { return Windows.home(of: self).clearHistory() }
        openHistory()
        clearingHistory = true
    }

    /// ⌥⌘U: the page's source, in a tab of its own beside it.
    func viewSource() {
        guard let site = selected?.site, site.scheme != ViewSource.scheme, let url = ViewSource.url(for: site) else { return }
        withAnimation(.slide) { _ = open(url) }
    }

    /// ⌥⌘R: Responsive Design Mode on, at the page's own size, or off.
    func toggleResponsive() {
        guard let tab = selected, tab.hasPage else { return }
        tab.responsive = tab.responsive == nil ? Responsive(fitting: tab) : nil
    }

    /// Somewhere picked from the switcher or the History menu: on the new tab
    /// on screen, if that is where you are, or else in a tab of its own.
    func go(to url: URL) {
        if let tab = selected, tab.isBlank { tab.go(to: url) } else { withAnimation(.slide) { _ = open(url) } }
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

    /// Window › Downloads (⌥⌘L): the list the downloads button shows, as Safari's and Chrome's key.
    func toggleDownloads() { downloadsRequests += 1 }

    /// Edit › Find › Use Selection for Find (⌘E), as Safari's: the text
    /// selected on the page is what Find looks for, in the bar, lit, for ⌘G
    /// to go through. The keyboard stays on the page, as the selection does.
    func useSelectionForFind() async {
        guard let page = selected?.shown,
              let text = try? await page.callAsyncJavaScript("return getSelection().toString()", contentWorld: .defaultClient) as? String
        else { return }
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, selected?.shown === page else { return }
        findQuery = query
        if !findBarOpen { withAnimation(.easeOut(duration: 0.14)) { findBarOpen = true } }
        findTyped()
    }

    func showFindBar() {
        withAnimation(.easeOut(duration: 0.14)) { findBarOpen = true }
        findRequests += 1
    }

    /// Puts the find bar away, and the keyboard back on the page.
    func hideFindBar() {
        withAnimation(.easeOut(duration: 0.14)) { findBarOpen = false }
        clearFound()
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
    func closeSelectedTab(discarding: Bool = false) {
        if commandBarOpen { return hideCommandBar() }
        guard let selected else { return }
        selected.letGoHung()
        if selected.isPinned {
            if selected.hasUnsavedWork, !discarding, let page = selected.page {
                Task {
                    if await confirmDiscarding(on: page), selectedID == selected.id { closeSelectedTab(discarding: true) }
                }
                return
            }
            recorder.begin(.tabClose)
            if let next = recent.last(where: { !$0.isPinned }) ?? tabs.first(where: { !$0.isPinned }) {
                selectedID = next.id
            } else {
                add(Tab())
            }
            Task {
                let look = await selected.snapshot()
                if selected.id != selectedID { selected.sleep(keeping: look, discarding: discarding) }
            }
            return
        }
        let id = selected.id
        withAnimation(.slide) { close(id) }
    }
}

// Nerda run again only to compile the block list (see Blocker), not as a browser.
if CommandLine.arguments.contains(Blocker.compileArgument) { Blocker.compileAndExit() }
// `Nerda mcp`: the nerda-browser MCP server an agent starts, passing its
// requests to the Nerda running (AgentMCP), not a browser itself.
if CommandLine.arguments.dropFirst().first == "mcp" { AgentMCP.runStdio(socket: AgentWire.socket) }
// `Nerda cli …`: the nerda-browser command (AgentCommandLine), which
// setup's command on PATH runs.
if CommandLine.arguments.dropFirst().first == "cli" { AgentCommandLine.main(Array(CommandLine.arguments.dropFirst(2))) }
// `Nerda setup`: connects Nerda to Claude Code and Codex (AgentSetup).
if CommandLine.arguments.dropFirst().first == "setup" { AgentSetup.main(Array(CommandLine.arguments.dropFirst(2))) }
// This launch's moments, from the process start (Launch.swift).
Launch.start()
// Where the main thread stops, from the first moment on (Watchdog, Recorder).
Watchdog.start()

// Read off the main thread while the rest below gets ready.
let launchSession = Launch.stage("session") { Session.reading(Session.file) }
// Started by an agent's nerda-browser with Nerda closed: hidden until the
// owner opens Nerda (HiddenStart), its tabs and windows only then.
let startsHidden = CommandLine.arguments.contains(AgentLauncher.hiddenArgument)
let app = NSApplication.shared
// A lab run's Nerda Test (Lab) has no Dock icon and is never in front.
if Lab.isOn { app.setActivationPolicy(.accessory) } else if !startsHidden { app.setActivationPolicy(.regular) }
// Tabs are ours; no system tab bar, and no Show Tab Bar items in the menus.
NSWindow.allowsAutomaticWindowTabbing = false
SpellCheck.registerDefault()
Theme.apply()

let browser = Launch.stage("browser") { Browser() }
// Read, and indexed for typing in the address bar, while the window comes up.
Launch.stage("history") { History.shared.load(from: History.file, waiting: false) }
// Before the tabs: those of bookmarks are told by them.
Launch.stage("bookmarks") { Bookmarks.shared.load(from: Bookmarks.file) }
Favicons.shared.folder = Favicons.folder
// A lab run starts with no tabs of a run before, and keeps none for the next.
if !startsHidden, !Lab.isOn {
    Launch.stage("restore") {
        browser.restore(launchSession(), from: Session.file)
        // Read off the main thread, so the tabs' icons are there with the window.
        Favicons.shared.preload(browser.tabs.compactMap(\.site))
    }
}
// Opening on a new tab, it opens with its picture already there. On a web
// page, the picture waits for the first new tab: 20 to 100 MB not taken for one.
if browser.selected?.isBlank == true { Launch.stage("backdrop") { Backdrop.shared.load() } }
// Once the first page is in: a page already running for the next tab
// (SparePages), or with that off, a page's process ready for it.
Launch.later("spare page") { SparePages.isOn ? SparePages.keep(for: browser.dataStore, in: 0) : Tab.warmUp() }
let menu = Launch.stage("menu") {
    let menu = AppMenu(browser: browser)
    menu.install()
    return menu
}
if Edition.updates { Launch.later("updates") { Updater.shared.start() } }
Feedback.shared.start()
// Every window's pages out of sight, looked at once a minute for one stuck in a loop.
HungPages.start()
// Agents reach Nerda on its socket while Settings lets them (AgentServer).
AgentServer.shared.start()
// The skill setup wrote for Claude Code and Codex, written again if this
// version of Nerda changed it; nowhere setup didn't write it.
Task.detached(priority: .utility) { AgentSetup.installed()?.refreshSkills() }

let window = Launch.stage("window") { BrowserWindow(browser: browser) }
Windows.regular = window

/// The windows Nerda opens with: at once, or after a hidden start, once the
/// owner opens it.
func showWindows() {
    window.makeKeyAndOrderFront(nil)
    if Lab.isOn { return Lab.start(browser) }
    // A blank tab has no page to wait for: the window is the launch.
    Launch.watch(window, waitingForPage: browser.selected.map { !$0.isBlank } ?? false)
    Launch.stage("other windows") {
        Windows.reopenProfiles()
        Windows.reopenSecondary()
    }
    // Once the window is up: loading them takes the main thread a while.
    if Extensions.enabledAtLaunch { DispatchQueue.main.async { Extensions.shared.start(for: browser) } }
}

if startsHidden {
    HiddenStart.shared = HiddenStart(
        server: AgentServer.shared,
        setPolicy: { app.setActivationPolicy($0) },
        show: {
            browser.restore(from: Session.file)
            Favicons.shared.preload(browser.tabs.compactMap(\.site))
            showWindows()
        },
        quit: { app.terminate(nil) }
    )
} else {
    showWindows()
}
Launch.later("stores left") { Profiles.removeStoresLeft() }

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
delegate.dockMenu = menu.dock
app.delegate = delegate
window.delegate = delegate
// Shown before it had its delegate, it may have become the main window
// unheard: in front to begin with, unless another window has said so since.
if window.isVisible, WindowInFront.app.front == nil { WindowInFront.app.cameForward(browser) }
// SIGTERM (`kill`, and watch.sh putting in a new build) would end the app on
// the spot; the tabs and history are saved first.
signal(SIGTERM, SIG_IGN)
let terminated = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
terminated.setEventHandler {
    MainActor.assumeIsolated { delegate.save() }
    exit(0)
}
terminated.resume()

// Not activated here: macOS brings Nerda forward when it is opened, and leaves
// it behind when asked to (`open -g`, watch.sh).
app.run()

/// Where a window's keyboard rests when nothing in it has asked for it:
/// takes it without showing it, and isn't among the controls Tab goes
/// through, but Tab from here goes on into them.
final class KeyboardRest: NSView {
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { false }
    override var nextKeyView: NSView? {
        get { superview }
        set {}
    }
}
