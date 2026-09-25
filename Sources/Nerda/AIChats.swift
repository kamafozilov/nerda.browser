import SwiftUI

/// An AI chat's site, one click away by the downloads in the sidebar's
/// bottom corner.
struct AIChat: Codable, Identifiable, Equatable {
    var id: String { url.absoluteString }
    let name: String
    let url: URL

    var host: String { url.host() ?? "" }

    /// Its icon from Google's icon service, big enough to be drawn sharp:
    /// /favicon.ico is refused (ChatGPT), missing (Gemini, Grok, DeepSeek)
    /// or small on most of them. Asked by its https address: by its host
    /// alone, some (Copilot) come back as a globe.
    var icon: URL? {
        var parts = URLComponents(string: "https://t0.gstatic.com/faviconV2")
        parts?.queryItems = [
            URLQueryItem(name: "client", value: "SOCIAL"), URLQueryItem(name: "type", value: "FAVICON"),
            URLQueryItem(name: "fallback_opts", value: "TYPE,SIZE,URL"),
            URLQueryItem(name: "url", value: "https://\(host)"), URLQueryItem(name: "size", value: "128"),
        ]
        return parts?.url
    }

    /// A name from the address, for one added without: chat.deepseek.com, DeepSeek's.
    static func name(of host: String) -> String {
        let labels = host.split(separator: ".")
        let name = labels.count > 1 ? labels[labels.count - 2] : labels.first ?? ""
        return name.prefix(1).uppercased() + name.dropFirst()
    }
}

/// The AI chats offered, in their order: these to start with, then the ones
/// added with + or taken away with a right-click. Their icons are kept on disk.
@Observable
final class AIChats {
    static let shared = AIChats()
    private static let key = "aiChats"
    private static let folder = Edition.folder.appending(path: "AIChatIcons")

    static let defaults = [
        AIChat(name: "ChatGPT", url: URL(string: "https://chatgpt.com")!),
        AIChat(name: "Claude", url: URL(string: "https://claude.ai")!),
        AIChat(name: "Gemini", url: URL(string: "https://gemini.google.com")!),
        AIChat(name: "Grok", url: URL(string: "https://grok.com")!),
        AIChat(name: "Perplexity", url: URL(string: "https://www.perplexity.ai")!),
        AIChat(name: "DeepSeek", url: URL(string: "https://chat.deepseek.com")!),
    ]

    private(set) var list = UserDefaults.standard.data(forKey: AIChats.key)
        .flatMap { try? JSONDecoder().decode([AIChat].self, from: $0) } ?? AIChats.defaults
    /// By host.
    private(set) var icons: [String: Icon] = [:]
    @ObservationIgnored private var loading: Set<String> = []

    struct Icon {
        let image: NSImage
        /// The colour its square is filled with to the edges (Claude's orange),
        /// for the tile round it; nil for a mark alone (Gemini's star).
        let fill: NSColor?
    }

    func add(_ chat: AIChat) {
        guard !list.contains(chat) else { return }
        list.append(chat)
        save()
    }

    func remove(_ chat: AIChat) {
        list.removeAll { $0 == chat }
        save()
    }

    private func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(list), forKey: Self.key)
    }

    func loadIcon(of chat: AIChat) async {
        let host = chat.host
        guard icons[host] == nil, !loading.contains(host), let url = chat.icon else { return }
        loading.insert(host)
        defer { loading.remove(host) }

        let folder = Self.folder
        let file = folder.appending(path: host + ".png")
        var data = await Task.detached(priority: .userInitiated) { try? Data(contentsOf: file) }.value
        // One it has none for is a 404.
        if data == nil, let (fetched, response) = try? await URLSession.shared.data(from: url),
           (response as? HTTPURLResponse)?.statusCode == 200 {
            data = fetched
            await Task.detached(priority: .utility) {
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try? fetched.write(to: file, options: .atomic)
            }.value
        }
        if let data, let image = NSImage(data: data) {
            icons[host] = Icon(image: image, fill: Self.fill(of: image))
        }
    }

    /// The colour at the middle of its top and left edges, when both are
    /// solid: the icon is a square of that colour, or one with rounded corners.
    private static func fill(of image: NSImage) -> NSColor? {
        let side = 16
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        func color(_ x: Int, _ y: Int) -> NSColor? {
            let i = (y * side + x) * 4
            guard pixels[i + 3] > 240 else { return nil }
            return NSColor(srgbRed: Double(pixels[i]) / 255, green: Double(pixels[i + 1]) / 255,
                           blue: Double(pixels[i + 2]) / 255, alpha: 1)
        }
        guard color(0, side / 2) != nil else { return nil }
        return color(side / 2, 0)
    }
}

struct AIChatsButton: View {
    let browser: Browser
    @Binding var shown: Bool

    @State private var hovering = false

    var body: some View {
        Button { shown.toggle() } label: {
            Image(systemName: "sparkles")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(hovering || shown ? Palette.ink : Palette.muted)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(hovering || shown ? Palette.hover : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("AI Chats")
        .accessibilityLabel("AI Chats")
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.14), value: hovering)
        .popover(isPresented: $shown, arrowEdge: .top) {
            AIChatsList(browser: browser) { shown = false }
        }
    }
}

/// The chats, three to a row, and + at the end to add another.
private struct AIChatsList: View {
    let browser: Browser
    let close: () -> Void

    @State private var adding = false
    private var chats: AIChats { .shared }

    var body: some View {
        if adding {
            AddAIChat(suggested: suggestion) { adding = false }
        } else {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(AIChatIcon.tileWidth), spacing: 4), count: 3), spacing: 4) {
                ForEach(chats.list) { chat in
                    AIChatTile(title: chat.name, action: { open(chat) }) { AIChatIcon(chat: chat) }
                        .contextMenu { Button("Remove") { withAnimation { chats.remove(chat) } } }
                }
                AIChatTile(title: "Add", action: { adding = true }) {
                    RoundedRectangle(cornerRadius: AIChatIcon.radius, style: .continuous)
                        .strokeBorder(Palette.muted.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                        .overlay {
                            Image(systemName: "plus")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(Palette.muted)
                        }
                        .frame(width: AIChatIcon.size, height: AIChatIcon.size)
                }
                .help("Add an AI chat")
            }
            .padding(8)
        }
    }

    /// The site on screen, to add, if it isn't one already.
    private var suggestion: String {
        guard let site = browser.selected?.site, ["http", "https"].contains(site.scheme),
              let host = site.host(), !chats.list.contains(where: { $0.host == host }) else { return "" }
        return host
    }

    /// Its tab if one is open, so the chat going on there is the one shown.
    private func open(_ chat: AIChat) {
        close()
        if let tab = browser.tabs.first(where: { $0.site?.host() == chat.host }) {
            browser.select(tab.id)
        } else {
            browser.open(chat.url)
        }
    }
}

private struct AddAIChat: View {
    let done: () -> Void

    @State private var address: String
    @State private var name = ""
    @FocusState private var focused: Bool

    init(suggested: String, done: @escaping () -> Void) {
        _address = State(initialValue: suggested)
        self.done = done
    }

    /// Only an address: anything else would be a search.
    private var url: URL? {
        guard let url = Address.url(from: address), url != Address.search(address),
              ["http", "https"].contains(url.scheme), url.host() != nil else { return nil }
        return url
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Add an AI Chat")
                .font(.headline)
            TextField("Address, like chat.mistral.ai", text: $address)
                .focused($focused)
            TextField(url.map { AIChat.name(of: $0.host() ?? "") } ?? "Name", text: $name)
            HStack {
                Spacer()
                Button("Cancel", action: done)
                    .keyboardShortcut(.cancelAction)
                Button("Add", action: add)
                    .keyboardShortcut(.defaultAction)
                    .disabled(url == nil)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(14)
        .frame(width: 264)
        // A popover opened by a click on a button isn't given the keyboard:
        // taken, so the address can be typed straight away.
        .background(KeyWindow { focused = true })
    }

    private func add() {
        guard let url else { return }
        let name = name.trimmingCharacters(in: .whitespaces)
        AIChats.shared.add(AIChat(name: name.isEmpty ? AIChat.name(of: url.host() ?? "") : name, url: url))
        done()
    }
}

private struct KeyWindow: NSViewRepresentable {
    /// Once it has the keyboard.
    let then: () -> Void

    func makeNSView(context: Context) -> NSView { Taker(then: then) }
    func updateNSView(_ view: NSView, context: Context) {}

    final class Taker: NSView {
        let then: () -> Void
        init(then: @escaping () -> Void) {
            self.then = then
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { nil }

        // Once the popover is on screen: before, it can't be made key.
        override func viewDidMoveToWindow() {
            DispatchQueue.main.async { [weak self] in
                self?.window?.makeKey()
                self?.then()
            }
        }
    }
}

private struct AIChatTile<Icon: View>: View {
    let title: String
    let action: () -> Void
    @ViewBuilder let icon: Icon

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                icon
                Text(title)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, 4)
            .frame(width: AIChatIcon.tileWidth, height: 76)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(hovering ? Palette.hover : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.14), value: hovering)
    }
}

/// Each icon as an app's is on the Dock: a rounded square of one size. One
/// that is a square already fills it, on its own colour so its corners
/// don't show; a mark alone sits in the middle of a white one, and a site
/// without one has its name's first letter there.
private struct AIChatIcon: View {
    static let size: CGFloat = 40
    static let tileWidth: CGFloat = 76
    static let radius: CGFloat = 10

    let chat: AIChat

    var body: some View {
        let icon = AIChats.shared.icons[chat.host]
        let shape = RoundedRectangle(cornerRadius: Self.radius, style: .continuous)

        ZStack {
            Color(nsColor: icon?.fill ?? .white)
            if let icon {
                Image(nsImage: icon.image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .padding(icon.fill == nil ? 7 : 0)
                    .transition(.opacity)
            } else {
                Text(chat.name.prefix(1))
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .foregroundStyle(.black.opacity(0.55))
            }
        }
        .frame(width: Self.size, height: Self.size)
        .clipShape(shape)
        .overlay(shape.strokeBorder(.black.opacity(0.1), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 1.5, y: 1)
        .animation(.easeOut(duration: 0.15), value: icon != nil)
        .task(id: chat.host) { await AIChats.shared.loadIcon(of: chat) }
    }
}
