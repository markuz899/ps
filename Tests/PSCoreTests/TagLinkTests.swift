import XCTest
@testable import PSCore

final class TagPairTests: XCTestCase {
    private func partnerText(_ html: String, at needle: String, offset: Int = 1) -> String? {
        let text = html as NSString
        let index = text.range(of: needle).location + offset
        guard let pair = TagPair.partner(in: text, at: index) else { return nil }
        return "\(pair.partner.location):" + text.substring(with: pair.partner)
    }

    func testOpeningFindsClosingSkippingNested() {
        let html = #"<div class="a>b"><div>x</div><br><img src="i"/></div>"#
        let closing = (html as NSString).range(of: "</div>", options: .backwards).location + 2
        XCTAssertEqual(partnerText(html, at: "<div class"), "\(closing):div")
    }

    func testClosingFindsOpening() {
        let html = "<ul><li>a</li><li>b</li></ul>"
        XCTAssertEqual(partnerText(html, at: "</ul>", offset: 2), "1:ul")
        // Caret right after the name counts too.
        XCTAssertEqual(partnerText(html, at: "</ul>", offset: 4), "1:ul")
    }

    func testCommentsAndVoidsAndSelfClosingAreIgnored() {
        XCTAssertNil(partnerText("<br><p></p>", at: "<br"))
        XCTAssertNil(partnerText("<x/><x></x>", at: "<x/"))
        XCTAssertEqual(partnerText("<p><!-- </p> --></p>", at: "<p"), "18:p")
    }

    func testNotATag() {
        XCTAssertNil(partnerText("if a<b and c</b", at: "a<b", offset: 2))
        XCTAssertNil(TagPair.name(in: "let div = 1" as NSString, at: 5))
        XCTAssertNil(partnerText("<div>unclosed", at: "<div"))
    }
}

final class CodeLinkTests: XCTestCase {
    func testExplicitLinksOnly() {
        let text = "// see https://example.com/docs?a=1 and user.name or www.apple.com" as NSString
        XCTAssertEqual(CodeLink.url(in: text, at: text.range(of: "example").location)?.absoluteString, "https://example.com/docs?a=1")
        XCTAssertNil(CodeLink.url(in: text, at: text.range(of: "user.name").location + 2))
        XCTAssertEqual(CodeLink.url(in: text, at: text.range(of: "www.apple").location + 5)?.host, "www.apple.com")
        XCTAssertNil(CodeLink.url(in: text, at: 2))
    }
}
