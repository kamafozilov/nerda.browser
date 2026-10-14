import Foundation
import Testing
import WebKit
@testable import Nerda

/// A page is offered for translation only in a language that is none of
/// yours, by language alone; what isn't a language is never offered.
@MainActor
@Test func onlyAPageInAnotherLanguageIsOffered() {
    #expect(Translator.foreign("ru", to: ["en-US", "uz-Latn-UZ"]) == "ru")
    #expect(Translator.foreign("zh-TW", to: ["en-US"]) == "zh-TW")
    #expect(Translator.foreign("en-GB", to: ["en-US"]) == nil)
    #expect(Translator.foreign("UZ", to: ["uz-Latn-UZ"]) == nil)
    #expect(Translator.foreign("x-default", to: ["en-US"]) == nil)
    #expect(Translator.foreign("und", to: ["en-US"]) == nil)
    #expect(Translator.foreign(nil, to: ["en-US"]) == nil)
    #expect(Translator.yours(["en-US", "en-GB", "ru-UZ"]) == ["en-US", "ru-UZ"])
}

/// What the page shows is sent a block at a time, the title first and then
/// what is on screen, and comes back in its place with the spaces and markup
/// round it; code, a field's text and what the page keeps from translation
/// stay. Text added later is taken up, and Show Original puts back every word.
@MainActor
@Test func aPageIsTranslatedInPlaceAndBack() async throws {
    let page = try await translatable("""
        <title>Bonjour</title>
        <p id=far style="position: absolute; top: 5000px">Loin</p>
        <p id=line> Bonjour <b>le monde</b> </p>
        <img id=image alt="Un chat" title="Chat"><input id=field placeholder="Nom">
        <code>let x</code><script>var s = 'Salut'</script><p>123</p>
        <p translate=no>Paris</p><span class=notranslate>Lyon</span><div contenteditable>Texte</div>
        """)
    func next(_ count: Int) async throws -> [String] {
        let batch = try await page.run("return nerdaTranslate.next(\(count), 3000)") as? [[String: Any]] ?? []
        _ = try await page.run("nerdaTranslate.put(batch.map(({ id, text }) => ({ id, text: text.toUpperCase() })))",
                               ["batch": batch])
        return batch.compactMap { $0["text"] as? String }
    }

    #expect(try await next(2) == ["Bonjour", "Bonjour ⟦1⟧le monde⟦/1⟧"])
    #expect(Set(try await next(10)) == ["Un chat", "Chat", "Nom", "Loin"])
    #expect(try await next(10) == [])
    #expect(try await page.run("return line.innerHTML") as? String == " BONJOUR <b>LE MONDE</b> ")
    #expect(try await page.run("return document.title") as? String == "BONJOUR")
    #expect(try await page.run("return [image.alt, image.title, field.placeholder, far.textContent]") as? [String]
        == ["UN CHAT", "CHAT", "NOM", "LOIN"])
    #expect(try await page.run("return document.body.innerText.includes('let x') && document.body.innerText.includes('Texte')") as? Bool == true)

    _ = try await page.run("document.body.insertAdjacentHTML('beforeend', '<p id=late>Encore</p>'); line.firstChild.data = 'Salut '")
    try await Task.sleep(for: .milliseconds(50))
    #expect(Set(try await next(10)) == ["Encore", "Salut ⟦1⟧le monde⟦/1⟧"])

    _ = try await page.run("nerdaTranslate.restore()")
    #expect(try await page.run("return line.innerHTML") as? String == "Salut <b>le monde</b> ")
    #expect(try await page.run("return [document.title, image.alt, image.title, field.placeholder, late.textContent]") as? [String]
        == ["Bonjour", "Un chat", "Chat", "Nom", "Encore"])
}

/// A sentence split by links and bold goes as one, and each link comes back
/// round its own words, where the translation puts it, still the same link;
/// a note's number stays as it is, after the words if the translation lost
/// its place. One whose marks come back broken still reads right, without
/// its link. Show Original puts back the very same markup.
@MainActor
@Test func aSentenceKeepsItsLinks() async throws {
    let original = ##"Le <a href="/chat">chat</a> de <b>Marie</b> dort<sup><a href="#n1">[1]</a></sup>."##
    let page = try await translatable("<p id=para>\(original)</p><p id=lost>Un <a href=/x>lien</a> perdu</p>")
    _ = try await page.run("window.cat = para.querySelector('a')")
    let batch = try await page.run("return nerdaTranslate.next(10, 3000)") as? [[String: Any]] ?? []
    #expect(batch.compactMap { $0["text"] as? String } == ["Le ⟦1⟧chat⟦/1⟧ de ⟦2⟧Marie⟦/2⟧ dort⟦3⟧⟦/3⟧.", "Un ⟦1⟧lien⟦/1⟧ perdu"])

    let english = ["⟦2⟧Mary⟧/2⟧'s ⟦1⟧cat⟦/1⟧ sleeps.", "A lost link"]
    _ = try await page.run("nerdaTranslate.put(batch.map(({ id }, i) => ({ id, text: english[i] })))",
                           ["batch": batch, "english": english])
    #expect(try await page.run("return para.innerHTML") as? String
        == ##"<b>Mary</b>'s <a href="/chat">cat</a> sleeps.<sup><a href="#n1">[1]</a></sup>"##)
    #expect(try await page.run("return cat === para.querySelector('a')") as? Bool == true)
    #expect(try await page.run("return lost.innerHTML") as? String == #"A lost link<a href="/x"></a>"#)

    _ = try await page.run("nerdaTranslate.restore()")
    #expect(try await page.run("return para.innerHTML") as? String == original)
    #expect(try await page.run("return lost.innerHTML") as? String == #"Un <a href="/x">lien</a> perdu"#)
}

/// A page with Nerda's translation script in it.
@MainActor
private func translatable(_ html: String) async throws -> WKWebView {
    let page = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
    page.loadHTMLString(html, baseURL: URL(string: "https://example.com"))
    while page.isLoading { try await Task.sleep(for: .milliseconds(20)) }
    _ = try await page.run(Translator.script)
    return page
}

private extension WKWebView {
    func run(_ script: String, _ arguments: [String: Any] = [:]) async throws -> Any? {
        try await callAsyncJavaScript(script, arguments: arguments, contentWorld: .defaultClient)
    }
}
