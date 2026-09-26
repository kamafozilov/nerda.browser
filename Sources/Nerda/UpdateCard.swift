import SwiftUI

/// At the foot of the sidebar once a newer Nerda is out (Updater): its
/// version, and a click to install it. A bar fills as the update comes in,
/// then Nerda opens again as the new one.
struct UpdateCard: View {
    let release: Updater.Release
    var incognito = false

    private let updater = Updater.shared
    @State private var hovering = false

    private var accent: Color { incognito ? Palette.incognitoAccent : .accentColor }

    /// How much of it is in, while it downloads and once it's being put in place.
    private var fraction: Double? {
        switch updater.state {
        case .downloading(let fraction): fraction
        case .installing: 1
        default: nil
        }
    }

    private var title: String {
        switch updater.state {
        case .downloading: "Downloading update…"
        case .installing: "Installing…"
        default: "Update available"
        }
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        Button(action: updater.install) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .background(accent.gradient, in: Circle())
                        .symbolEffect(.bounce, value: hovering && fraction == nil)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Palette.ink)
                        Text("Nerda \(release.version)")
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.muted)
                    }
                    Spacer(minLength: 0)
                    if let fraction {
                        Text(fraction, format: .percent.precision(.fractionLength(0)))
                            .font(.system(size: 11, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(Palette.muted)
                            .contentTransition(.numericText(value: fraction))
                    } else {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(hovering ? Palette.ink : Palette.muted)
                    }
                }
                if let fraction {
                    Capsule()
                        .fill(Palette.wash)
                        .frame(height: 4)
                        .overlay(alignment: .leading) {
                            GeometryReader { bar in
                                Capsule()
                                    .fill(accent.gradient)
                                    .frame(width: max(4, bar.size.width * fraction))
                            }
                        }
                        .transition(.opacity)
                }
            }
            .padding(10)
            .background(shape.fill(hovering && fraction == nil ? Palette.wash : Palette.hover))
            .overlay(shape.strokeBorder(Palette.rim))
            .contentShape(shape)
        }
        // Not disabled while it downloads, which would grey the bar out:
        // Updater takes one install at a time.
        .buttonStyle(.plain)
        .help("Install Nerda \(release.version) and relaunch")
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.14), value: hovering)
        .animation(.easeOut(duration: 0.25), value: fraction)
    }
}

/// A version's part of CHANGELOG.md, which build.sh puts in the bundle.
nonisolated struct ReleaseNotes: Equatable, Identifiable {
    /// "Unreleased" in a development build: what is on its way.
    let version: String
    let date: Date?
    let notes: String

    var id: String { version }

    /// Every version's, newest first.
    static let all: [ReleaseNotes] = Bundle.main.url(forResource: "CHANGELOG", withExtension: "md")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        .map(parse) ?? []

    /// Each `## [version] - date` and what is under it, up to the next one or
    /// the links at the bottom; a version with nothing under it is left out.
    static func parse(_ changelog: String) -> [ReleaseNotes] {
        var found: [(heading: Substring, lines: [Substring])] = []
        for line in changelog.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("## [") {
                found.append((line.dropFirst(4), []))
            } else if line.hasPrefix("["), line.contains("]: ") {
                break
            } else if !found.isEmpty {
                found[found.count - 1].lines.append(line)
            }
        }
        return found.compactMap { heading, lines in
            let notes = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !notes.isEmpty, let end = heading.firstIndex(of: "]") else { return nil }
            let date = heading[end...].split(separator: " ").last
                .flatMap { try? Date(String($0), strategy: .iso8601.year().month().day()) }
            return ReleaseNotes(version: String(heading[..<end]), date: date, notes: notes)
        }
    }
}

/// Over the window the first time a newer version opens: what each version
/// since the one that ran last brought, newest first, each heading with a
/// mark of its own. A click outside it, or Continue, puts it away.
struct WhatsNew: View {
    let releases: [ReleaseNotes]
    let close: () -> Void

    /// How tall the notes stand before they scroll.
    static let listHeight: CGFloat = 400

    @State private var notesHeight: CGFloat = 0

    nonisolated struct Section: Equatable {
        var title: String?
        var items: [String]
    }

    var body: some View {
        GeometryReader { window in
            ZStack {
                Color.black.opacity(0.1)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: close)
                VStack(spacing: 0) {
                    header
                    // A few notes' worth, however tall the window: the first
                    // are read at a glance, the rest scrolled to. Less in a
                    // window too short for that.
                    let most = min(Self.listHeight, max(120, window.size.height - 360))
                    // As tall as the notes, up to that; ViewThatFits took the
                    // whole of it and left short notes floating in its middle.
                    ScrollView {
                        list
                            .padding(.vertical, 8)
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { notesHeight = $0 }
                    }
                    .scrollIndicators(.never)
                    .scrollBounceBehavior(.basedOnSize)
                    // Fading out at its edges rather than cut off there, when it scrolls.
                    .mask {
                        let fade = notesHeight > most
                        VStack(spacing: 0) {
                            LinearGradient(colors: [fade ? .clear : .black, .black], startPoint: .top, endPoint: .bottom).frame(height: 12)
                            Color.black
                            LinearGradient(colors: [.black, fade ? .clear : .black], startPoint: .top, endPoint: .bottom).frame(height: 24)
                        }
                    }
                    .frame(height: min(notesHeight, most))
                    Button(action: close) {
                        Text("Continue").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .padding(20)
                }
                .frame(width: min(580, window.size.width - 48))
                // Lightly tinted, as the other panels over the window: the
                // window's ground at its usual strength turned it near black.
                .glassPanel(cornerRadius: 26, tint: 0.35)
            }
        }
        .onExitCommand(perform: close)
    }

    private var header: some View {
        VStack(spacing: 4) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
                .padding(.bottom, 6)
            Text("What's New in Nerda")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(Palette.ink)
            Text(releases.count > 1
                 ? "\(releases.count) updates, \(releases.last?.version ?? "") to \(Updater.current)"
                 : "Version \(Updater.current)")
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
        }
        .padding(.top, 28)
        .padding(.bottom, 18)
    }

    /// With more than one version, each under its number and date.
    private var list: some View {
        VStack(alignment: .leading, spacing: 26) {
            ForEach(releases) { release in
                VStack(alignment: .leading, spacing: 14) {
                    if releases.count > 1 { ReleaseHeading(release: release) }
                    ReleaseNotesList(notes: release.notes)
                }
            }
        }
        .padding(.horizontal, 24)
    }

    /// Keep a Changelog's headings, in plainer words, with an icon and colour each.
    static func mark(_ title: String?) -> (name: String?, icon: String, color: Color) {
        switch title {
        case "Added": ("New", "sparkles", .blue)
        case "Changed": ("Changed", "wand.and.stars", .purple)
        case "Fixed": ("Fixed", "checkmark", .green)
        case "Removed": ("Removed", "minus", .red)
        case "Deprecated": ("Going Away", "clock", .orange)
        case "Security": ("Security", "lock.fill", .orange)
        default: (nil, "circle.fill", .gray)
        }
    }

    static func inline(_ markdown: String) -> AttributedString {
        (try? AttributedString(markdown: markdown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(markdown)
    }

    /// The notes' `###` headings, each with its `- ` items; a line that
    /// starts no item carries on the one before it.
    nonisolated static func sections(_ notes: String) -> [Section] {
        var sections: [Section] = []
        for line in notes.split(separator: "\n") {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.isEmpty { continue }
            if text.hasPrefix("#") {
                sections.append(Section(title: String(text.drop { $0 == "#" || $0 == " " }), items: []))
                continue
            }
            if sections.isEmpty { sections.append(Section(items: [])) }
            if text.hasPrefix("- ") || text.hasPrefix("* ") {
                sections[sections.count - 1].items.append(String(text.dropFirst(2)))
            } else if let last = sections[sections.count - 1].items.popLast() {
                sections[sections.count - 1].items.append(last + " " + text)
            } else {
                sections[sections.count - 1].items.append(text)
            }
        }
        return sections.filter { !$0.items.isEmpty }
    }
}

/// A version's number and the day it came out.
struct ReleaseHeading: View {
    let release: ReleaseNotes

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(release.version == "Unreleased" ? "Coming next" : "Nerda \(release.version)")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Palette.ink)
            if let date = release.date {
                Text(date.formatted(date: .long, time: .omitted))
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
            }
        }
    }
}

/// A version's notes by heading, each with its mark and a dot before each line.
struct ReleaseNotesList: View {
    let notes: String

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(Array(WhatsNew.sections(notes).enumerated()), id: \.offset) { _, section in
                let mark = WhatsNew.mark(section.title)
                VStack(alignment: .leading, spacing: 10) {
                    if let title = section.title {
                        Label {
                            Text(mark.name ?? title)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Palette.ink)
                        } icon: {
                            Image(systemName: mark.icon)
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 22, height: 22)
                                .background(mark.color.gradient, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                    }
                    ForEach(Array(section.items.enumerated()), id: \.offset) { _, item in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Circle()
                                .fill(mark.color)
                                .frame(width: 5, height: 5)
                                .padding(.leading, 9)
                                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                            Text(WhatsNew.inline(item))
                                .font(.system(size: 13))
                                .foregroundStyle(Palette.ink.opacity(0.85))
                                .lineSpacing(2)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
