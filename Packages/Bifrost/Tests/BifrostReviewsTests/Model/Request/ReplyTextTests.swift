import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostReviews

@Suite("the fixed texts of the replies", .testTimeLimit)
struct ReplyTextTests {
    // The quote has the first three lines of the request, 300 UTF-16 units at most and never half
    // a character, each line after "> ". A blank request gives no quote.
    @Test func theQuoteHasThreeLinesAnd300AtMost() throws {
        #expect(ReplyText.quoted("  one\r\n\r\ntwo  \nthree\nfour") == "> one\n>\n> two")
        #expect(ReplyText.quoted("one\ntwo\nthree\nfour") == "> one\n> two\n> three")
        let long = String(repeating: "a", count: 400)
        #expect(ReplyText.quoted(long) == "> " + String(repeating: "a", count: 300))
        let emoji = String(repeating: "b", count: 299) + "\u{1F600}"
        #expect(ReplyText.quoted(emoji) == "> " + String(repeating: "b", count: 299))
        #expect(ReplyText.quoted(" \n \r\n ").isEmpty)
        #expect(ReplyText.comment(quote: "> one", reply: "Done.") == "> one\n\nDone.")
        #expect(ReplyText.comment(quote: "", reply: "Done.") == "Done.")
        let commit = try #require(CommitID("abcdef1234567890abcdef1234567890abcdef12"))
        #expect(ReplyText.fixedBy(commit) == "Fixed by abcdef1")
    }

    // Each @ that can start a mention gets a zero-width space after it, also in the quote and
    // after an entity that makes an @. An email address, an @ in a link that GitHub makes, an @
    // before a space and an @ at the end are not mentions. A second pass changes nothing.
    @Test func eachMentionIsBroken() {
        let space = "\u{200B}"
        let cases: [(String, String)] = [
            ("@user-b please look", "@\(space)user-b please look"),
            ("(@team/core)", "(@\(space)team/core)"),
            ("Write to a.b@example.com", "Write to a.b@example.com"),
            ("&#64;user, &#x40;other", "@\(space)user, @\(space)other"),
            ("&commat;third", "@\(space)third"),
            ("an @ alone, and the end @", "an @ alone, and the end @"),
            ("see https://example.com/@user-d/x", "see https://example.com/@user-d/x"),
            ("<b>https://example.com/@user-d</b>", "<b>https://example.com/@\(space)user-d</b>"),
            ("x&#64;y", "x@\(space)y"),
        ]
        for (text, broken) in cases {
            #expect(ReplyText.breakMentions(text) == broken, "\(text)")
            #expect(ReplyText.breakMentions(broken) == broken, "\(text)")
        }
        #expect(
            ReplyText.quoted("Ping @user-c, mail c@example.com")
                == "> Ping @\(space)user-c, mail c@example.com")
        #expect(ReplyText.isSame("Thanks @\(space)user-b\r\n", as: "Thanks @user-b"))
        #expect(!ReplyText.isSame("Thanks @user-c", as: "Thanks @user-b"))
    }
}
