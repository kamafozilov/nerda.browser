import Foundation
import Testing
@testable import Nerda

/// Site skills (spec #119, ticket #149): know-how about a site an agent is
/// pointed to when it gets there. Nerda's own ship in the app; the owner's
/// live in the data folder (here the harness's temporary one) and win over
/// Nerda's of the same name. An agent saves one only once the owner
/// approves it on a card, which a test stands in for (`SkillOwner`).
@MainActor
struct SiteSkillsTests {
    /// A skill file of the owner's, written where the server reads them.
    static func write(_ name: String, sites: String, description: String, text: String,
                      in harness: AgentHarness) throws {
        let folder = harness.server.skills.folder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = """
            ---
            name: \(name)
            description: \(description)
            sites: \(sites)
            ---

            \(text)
            """
        try file.write(to: folder.appending(path: "\(name).md"), atomically: true, encoding: .utf8)
    }

    /// The first answer on a site with a skill names it, once per session:
    /// the next answer there doesn't, nor an answer on another site, while
    /// another agent's session is told too.
    @Test func theFirstAnswerOnACoveredSiteCarriesAHint() async throws {
        let harness = try AgentHarness()
        defer { harness.close() }
        try Self.write("shop", sites: "127.0.0.1", description: "Ordering on the test shop",
                       text: "Add to the basket before you sign in.", in: harness)
        let url = try await harness.pages.serve("/shop", "<title>Shop</title><p>Things to buy</p>")
        let agent = try await harness.agent()

        let first = try await agent.call("open", ["url": AgentJSON(url)])
        #expect(!first.isError, "\(first.text)")
        let hint = try #require(first.text.split(separator: "\n").first { $0.hasPrefix("skill: ") })
        #expect(hint.contains("shop"))
        #expect(hint.contains("Ordering on the test shop"))
        // The hint is in the header, before the page's own words.
        let header = first.text.components(separatedBy: "<page-")[0]
        #expect(header.contains("skill: "))

        let again = try await agent.call("text", ["tab": "t1"])
        #expect(!again.isError, "\(again.text)")
        #expect(!again.text.contains("skill: "))

        let other = url.absoluteString.replacing("127.0.0.1", with: "localhost")
        let elsewhere = try await agent.call("open", ["url": .string(other)])
        #expect(!elsewhere.isError, "\(elsewhere.text)")
        #expect(!elsewhere.text.contains("skill: "))

        let second = try await harness.agent(session: "session-2")
        let theirs = try await second.call("open", ["url": AgentJSON(url)])
        #expect(theirs.text.contains("skill: shop"))
    }

    /// `skill` answers the named skill's text; without a name, which there
    /// are; an unknown name fails, naming them.
    @Test func skillReadsTheNamedSkill() async throws {
        let harness = try AgentHarness()
        defer { harness.close() }
        try Self.write("shop", sites: "127.0.0.1, shop.example", description: "Ordering on the test shop",
                       text: "Add to the basket before you sign in.", in: harness)
        let agent = try await harness.agent()

        let read = try await agent.call("skill", ["name": "shop"])
        #expect(!read.isError, "\(read.text)")
        #expect(read.text.contains("Add to the basket before you sign in."))
        #expect(read.text.contains("shop.example"))

        let list = try await agent.call("skill")
        #expect(!list.isError, "\(list.text)")
        #expect(list.text.contains("shop"))
        #expect(list.text.contains("Ordering on the test shop"))
        #expect(list.text.contains("github"))

        let missing = try await agent.call("skill", ["name": "nowhere"])
        #expect(missing.isError)
        #expect(missing.text.contains("shop"))
    }

    /// The skills tools are a group of their own, out of the lean list
    /// until an agent asks for them.
    @Test func theSkillToolsAreAGroup() async throws {
        let harness = try AgentHarness()
        defer { harness.close() }
        let agent = try await harness.agent()
        let names = { try await agent.tools().compactMap { $0["name"]?.string } }
        #expect(try await !names().contains("skill"))
        _ = try await agent.call("more_tools", ["group": "skills"])
        #expect(try await names().contains("skill"))
        #expect(try await names().contains("skill_save"))
    }

    /// `skill_save` puts the whole skill on a card for the owner and saves
    /// nothing until they approve it: the agent hears needs_user meanwhile,
    /// then that it was saved, and the next agent on the site is pointed
    /// to it.
    @Test func skillSaveSavesOnlyAfterTheOwnerApproves() async throws {
        let owner = SkillOwner()
        let harness = try AgentHarness(approveSkill: owner.approve)
        defer { harness.close() }
        let agent = try await harness.agent(waits: HandoffTests.quick)
        let skill: [String: AgentJSON] = [
            "name": "shop", "description": "Ordering on the test shop", "sites": ["127.0.0.1"],
            "text": "Pick the size before Add to basket; it is greyed out until then.",
        ]
        let file = harness.server.skills.folder.appending(path: "shop.md")

        let waiting = try await agent.call("skill_save", skill)
        #expect(!waiting.isError, "needs_user is no failure: \(waiting.text)")
        #expect(waiting.text.contains("needs_user"))
        let card = try #require(owner.shown.first)
        #expect(owner.shown.count == 1)
        #expect(card.asker == "Claude")
        #expect(card.skill.file.contains("Pick the size before Add to basket"))
        #expect(card.skill.file.contains("127.0.0.1"))
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(try await agent.call("skill", ["name": "shop"]).isError)

        let call = Task { try await agent.call("skill_save", skill, progressToken: "s1") }
        try await Task.sleep(for: .milliseconds(300))
        owner.verdict = true
        let saved = try await call.value
        #expect(!saved.isError, "\(saved.text)")
        #expect(saved.text.contains("saved"))
        // Asked again by the same agent, the owner saw one card.
        #expect(owner.shown.count == 1)
        #expect(FileManager.default.fileExists(atPath: file.path))

        let read = try await agent.call("skill", ["name": "shop"])
        #expect(read.text.contains("Pick the size before Add to basket"))
        let url = try await harness.pages.serve("/shop", "<title>Shop</title><p>Things to buy</p>")
        let next = try await harness.agent(session: "session-2")
        #expect(try await next.call("open", ["url": AgentJSON(url)]).text.contains("skill: shop"))
    }

    /// The owner saying no saves nothing, and the agent is told so.
    @Test func aSkillTheOwnerDeclinesIsntSaved() async throws {
        let owner = SkillOwner()
        owner.verdict = false
        let harness = try AgentHarness(approveSkill: owner.approve)
        defer { harness.close() }
        let agent = try await harness.agent(waits: HandoffTests.quick)

        let answer = try await agent.call("skill_save", [
            "name": "shop", "description": "Ordering", "sites": ["127.0.0.1"], "text": "Something",
        ], progressToken: "s1")
        #expect(!answer.isError, "\(answer.text)")
        #expect(answer.text.contains("didn't"))
        #expect(owner.shown.count == 1)
        #expect(!FileManager.default.fileExists(atPath: harness.server.skills.folder.appending(path: "shop.md").path))
    }

    /// A skill too long, or without a name or a site, is refused at once,
    /// with no card for the owner.
    @Test func aSkillPastTheCapIsRefusedWithoutACard() async throws {
        let owner = SkillOwner()
        let harness = try AgentHarness(approveSkill: owner.approve)
        defer { harness.close() }
        let agent = try await harness.agent(waits: HandoffTests.quick)

        let long = try await agent.call("skill_save", [
            "name": "shop", "description": "Ordering", "sites": ["127.0.0.1"],
            "text": .string(String(repeating: "word ", count: SiteSkill.mostCharacters / 4)),
        ])
        #expect(long.isError)
        #expect(long.text.contains("\(SiteSkill.mostCharacters)"))
        let unnamed = try await agent.call("skill_save", [
            "name": "Shop Things!", "description": "Ordering", "sites": ["127.0.0.1"], "text": "Something",
        ])
        #expect(unnamed.isError)
        let nowhere = try await agent.call("skill_save", [
            "name": "shop", "description": "Ordering", "sites": [], "text": "Something",
        ])
        #expect(nowhere.isError)
        #expect(owner.shown.isEmpty)
    }

    /// The owner's skill takes the place of Nerda's own of the same name,
    /// in what `skill` reads and in the list; Nerda's own reads as shipped
    /// until then.
    @Test func anOwnersSkillOverridesABuiltInOne() async throws {
        let harness = try AgentHarness()
        defer { harness.close() }
        let agent = try await harness.agent()
        let builtIn = try #require(harness.server.skills.builtIn.first { $0.name == "github" })
        #expect(builtIn.covers("github.com"))

        let shipped = try await agent.call("skill", ["name": "github"])
        #expect(!shipped.isError, "\(shipped.text)")
        #expect(shipped.text.contains(builtIn.text))

        try Self.write("github", sites: "github.com", description: "My own way with GitHub",
                       text: "Always open pull requests as drafts.", in: harness)
        let mine = try await agent.call("skill", ["name": "github"])
        #expect(mine.text.contains("Always open pull requests as drafts."))
        #expect(!mine.text.contains(builtIn.text))
        let list = try await agent.call("skill")
        #expect(list.text.contains("My own way with GitHub"))
        #expect(!list.text.contains(builtIn.description))
    }
}

/// Stands in for the owner looking at skill cards: keeps each card shown
/// and answers once `verdict` is set.
@MainActor
final class SkillOwner {
    private(set) var shown: [SiteSkillCard] = []
    var verdict: Bool?

    var approve: SiteSkills.Approve {
        { [self] card in
            shown.append(card)
            while verdict == nil { try? await Task.sleep(for: .milliseconds(50)) }
            return verdict
        }
    }
}
