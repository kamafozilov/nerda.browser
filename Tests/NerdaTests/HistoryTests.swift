import Foundation
import Testing
@testable import Nerda

private func historyFile() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder.appending(path: "history.json")
}

/// Switching apps saves only what changed; a page renaming itself goes in
/// with the next save.
@MainActor
@Test func historyIsWrittenOnlyWhenItChanged() throws {
    let file = try historyFile()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let history = History()
    history.load(from: file)
    let page = URL(string: "https://example.com/")!
    history.visit(page, title: "Example")
    history.save()
    #expect(FileManager.default.fileExists(atPath: file.path()))

    try FileManager.default.removeItem(at: file)
    history.save()
    #expect(!FileManager.default.fileExists(atPath: file.path()))

    history.name(page, "Example Domain")
    history.save(waiting: false)
    history.save()
    let next = History()
    next.load(from: file)
    #expect(next.visits[page]?.title == "Example Domain")
}

/// Past the limit the pages last visited longest ago go, and what is left
/// is still found, in order.
@MainActor
@Test func historyPastItsLimitDropsTheOldest() throws {
    let file = try historyFile()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let history = History()
    history.load(from: file)
    let now = Date.now
    for page in 0...20_000 {
        history.visit(URL(string: "https://example.com/\(page)")!, title: "Page \(page)", at: now.addingTimeInterval(Double(page)))
    }
    history.visit(URL(string: "https://old.example/")!, title: "Old", at: now.addingTimeInterval(-100 * 86400))
    #expect(history.recent(1).first?.title == "Page 20000")
    history.save()

    #expect(history.visits.count == 20_000)
    #expect(history.visits[URL(string: "https://example.com/0")!] == nil)
    #expect(history.visits[URL(string: "https://old.example/")!] == nil)
    #expect(history.pages(matching: "old").isEmpty)
    #expect(history.recent(20_001).count == 20_000)
    #expect(history.recent(1).first?.title == "Page 20000")
}

/// A page renamed stays in its place; one visited again goes first.
@MainActor
@Test func renamedPagesKeepTheirPlace() {
    let history = History()
    let now = Date.now
    let first = URL(string: "https://a.example/")!
    history.visit(first, title: "A", at: now.addingTimeInterval(-60))
    history.visit(URL(string: "https://b.example/")!, title: "B", at: now)
    #expect(history.recent(2).map(\.title) == ["B", "A"])
    history.name(first, "(3) A")
    #expect(history.recent(2).map(\.title) == ["B", "(3) A"])
    history.visit(first, title: "", at: now.addingTimeInterval(60))
    #expect(history.recent(2).map(\.title) == ["(3) A", "B"])
}

/// Read off the main thread at launch: pages visited before it is taken in
/// are added to what was read, and History cleared meanwhile stays cleared.
@MainActor
@Test func historyReadInTheBackgroundKeepsVisitsMadeMeanwhile() throws {
    let file = try historyFile()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let page = URL(string: "https://example.com/")!
    let saved = History()
    saved.load(from: file)
    saved.visit(page, title: "Example", at: .now.addingTimeInterval(-60))
    saved.visit(page, title: "Example", at: .now.addingTimeInterval(-60))
    saved.save()

    let history = History()
    history.load(from: file, waiting: false)
    history.visit(page, title: "")
    history.visit(URL(string: "https://new.example/")!, title: "New")
    history.settle()
    #expect(history.visits[page]?.count == 3)
    #expect(history.visits[page]?.title == "Example")
    #expect(history.recent(2).map(\.title) == ["New", "Example"])

    let cleared = History()
    cleared.load(from: file, waiting: false)
    cleared.clear()
    #expect(cleared.visits.isEmpty)
    cleared.settle()
    #expect(cleared.visits.isEmpty)
}

/// The history page's search and extensions' find a word anywhere, case and
/// accents aside, latest first, within the times asked.
@MainActor
@Test func pagesAreFoundByWhatTheyContain() {
    let history = History()
    let now = Date.now
    history.visit(URL(string: "https://cafe.example/menu")!, title: "Café Menu", at: now.addingTimeInterval(-3600))
    history.visit(URL(string: "https://docs.swift.org/")!, title: "Swift Documentation", at: now)
    history.visit(URL(string: "https://example.com/old")!, title: "Old news", at: now.addingTimeInterval(-3 * 86400))

    #expect(history.pages(containing: [""]).map(\.title) == ["Swift Documentation", "Café Menu", "Old news"])
    #expect(history.pages(containing: ["cafe"]).map(\.title) == ["Café Menu"])
    #expect(history.pages(containing: ["ocumen"]).map(\.title) == ["Swift Documentation"])
    #expect(history.pages(containing: ["swift.org"]).map(\.title) == ["Swift Documentation"])
    #expect(history.pages(containing: ["menu", "CAFÉ"]).count == 1)
    #expect(history.pages(containing: ["example"], from: now.addingTimeInterval(-86400)).map(\.title) == ["Café Menu"])
    #expect(history.pages(containing: [], through: now.addingTimeInterval(-60)).map(\.title) == ["Café Menu", "Old news"])
    #expect(history.pages(containing: [], limit: 1).map(\.title) == ["Swift Documentation"])
}

/// What history suggests for what is typed is found once; the search
/// engine's guesses, arriving later, are added under it.
@MainActor
@Test func suggestionsAreFoundOnceForWhatIsTyped() {
    let history = History()
    for _ in 1...2 { history.visit(URL(string: "https://www.youtube.com/")!, title: "YouTube") }
    let found = CommandBar.Found()
    let first = CommandBar.suggestions(for: "yo", guesses: [], history: history, found: found)
    #expect(first.map(\.url.absoluteString) == ["https://www.youtube.com/", "https://www.google.com/search?q=yo"])

    // Visited since, but the list for "yo" is the one already found.
    history.visit(URL(string: "https://yoga.example/")!, title: "Yoga")
    let guessed = CommandBar.suggestions(for: "yo", guesses: ["yoga"], history: history, found: found)
    #expect(guessed.map(\.url.absoluteString)
        == ["https://www.youtube.com/", "https://www.google.com/search?q=yo", "https://www.google.com/search?q=yoga"])
    #expect(history.sites(startingWith: "yo", limit: 1).map(\.url.absoluteString) == ["https://www.youtube.com/"])
}

/// A name and password written into an address never reach the history
/// file, and those an earlier version kept leave it as soon as it is read.
@MainActor
@Test func historyKeepsNoPasswordsInAddresses() throws {
    let file = try historyFile()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let page = URL(string: "https://example.com/admin")!
    let history = History()
    history.load(from: file)
    history.visit(URL(string: "https://me:secret@example.com/admin")!, title: "")
    history.name(URL(string: "https://me:secret@example.com/admin")!, "Admin")
    history.save()
    #expect(history.visits.keys.map(\.absoluteString) == [page.absoluteString])
    #expect(history.visits[page]?.title == "Admin")
    #expect(!String(decoding: try Data(contentsOf: file), as: UTF8.self).contains("secret"))

    // Kept with them by an earlier version: joined to the page without them,
    // and written again at once, nothing else visited.
    let old = [History.Visit(url: URL(string: "https://me:secret@old.example/")!, title: "Old", count: 2, last: .now),
               History.Visit(url: URL(string: "https://old.example/")!, title: "", count: 3, last: .now.addingTimeInterval(-60))]
    try JSONEncoder().encode(old).write(to: file)
    let loaded = History()
    loaded.load(from: file)
    #expect(loaded.visits[URL(string: "https://old.example/")!] == History.Visit(
        url: URL(string: "https://old.example/")!, title: "Old", count: 5, last: old[0].last))
    #expect(!String(decoding: try Data(contentsOf: file), as: UTF8.self).contains("secret"))
}

/// Counts from a file edited by hand are held to a sane range, and added
/// to without overflowing.
@MainActor
@Test func historyCountsCantOverflow() throws {
    let file = try historyFile()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let big = URL(string: "https://big.example/")!, negative = URL(string: "https://negative.example/")!
    try JSONEncoder().encode([History.Visit(url: big, title: "Big", count: .max, last: .now),
                              History.Visit(url: negative, title: "Negative", count: -5, last: .now)]).write(to: file)
    let history = History()
    history.load(from: file)
    history.visit(big, title: "Big")
    #expect(history.visits[big]?.count == History.mostVisits)
    #expect(history.visits[negative]?.count == 0)

    // Pages visited while it is read are added to what was read.
    try JSONEncoder().encode([History.Visit(url: big, title: "Big", count: .max, last: .now)]).write(to: file)
    let meanwhile = History()
    meanwhile.load(from: file, waiting: false)
    meanwhile.visit(big, title: "")
    meanwhile.settle()
    #expect(meanwhile.visits[big]?.count == History.mostVisits)
}

/// A page's new title doesn't draw again the views that list pages, as a
/// page counting in its title would at every tick; they find it the next
/// time they look. A new page does draw them again.
@MainActor
@Test func aNewTitleDoesntRedrawWhatListsPages() {
    let history = History()
    let page = URL(string: "https://mail.example/")!
    history.visit(page, title: "Inbox")
    final class Flag: @unchecked Sendable { var raised = false }
    let told = Flag()
    withObservationTracking { _ = history.recent(10) } onChange: { told.raised = true }
    history.name(page, "(3) Inbox")
    #expect(!told.raised)
    #expect(history.recent(1).first?.title == "(3) Inbox")
    #expect(history.pages(containing: ["(3)"]).count == 1)
    #expect(history.visits[page]?.title == "(3) Inbox")

    history.visit(URL(string: "https://other.example/")!, title: "Other")
    #expect(told.raised)
}

/// Typing doesn't wait for history: the rows for what was typed before stay
/// up until those for what is typed now are looked up off the main thread,
/// the same rows as found at once. A look cancelled by typing on gives up.
@MainActor
@Test func historyIsLookedUpAsYouTypeWithoutWaiting() async {
    let history = History()
    for _ in 1...2 { history.visit(URL(string: "https://www.youtube.com/")!, title: "YouTube") }
    history.visit(URL(string: "https://www.youtube.com/watch?v=1")!, title: "Your video")
    let found = CommandBar.Found()
    let yo = CommandBar.suggestions(for: "yo", guesses: [], history: history, found: found)
    let you = CommandBar.suggestions(for: "you", guesses: [], history: history)
    #expect(you.map(\.url.absoluteString) == ["https://www.youtube.com/", "https://www.google.com/search?q=you",
                                              "https://www.youtube.com/watch?v=1"])

    #expect(CommandBar.suggestions(for: "you", guesses: [], history: history, found: found, waiting: false).map(\.url)
        == yo.map(\.url))
    let looked = await CommandBar.lookUp("you", in: history.snapshot)
    #expect(CommandBar.suggestions(for: "you", guesses: [], history: history, found: CommandBar.Found("you", looked),
                                   waiting: false).map(\.url) == you.map(\.url))

    // The sites you went to last don't stay up under what is typed.
    let recent = CommandBar.Found()
    #expect(!CommandBar.suggestions(for: "", guesses: [], history: history, found: recent).isEmpty)
    #expect(CommandBar.suggestions(for: "you", guesses: [], history: history, found: recent, waiting: false).isEmpty)

    let cancelled = Task { await CommandBar.lookUp("you", in: history.snapshot) }
    cancelled.cancel()
    #expect(await cancelled.value.rows.map(\.url.absoluteString) == ["https://www.google.com/search?q=you"])
}
