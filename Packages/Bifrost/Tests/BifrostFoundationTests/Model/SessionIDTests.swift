import BifrostFoundation
import Testing

// The parse of a session ID: a UUID in the 8-4-4-4-12 form, kept in lower case. The test support
// lets a test write a session ID as a literal, and SessionID("...") with a literal is that
// literal. So each parse here gets a String value, not a literal.
@Suite("the session ID")
struct SessionIDTests {
    @Test(
        "a UUID with hex digits of either case is a session ID in lower case",
        arguments: [
            ("2f493bf0-1598-4b3b-b419-8acb9cb11bcb", "2f493bf0-1598-4b3b-b419-8acb9cb11bcb"),
            ("2F493BF0-1598-4B3B-B419-8ACB9CB11BCB", "2f493bf0-1598-4b3b-b419-8acb9cb11bcb"),
            ("5130B970-0252-f95d-d027-1ca3458a30f2", "5130b970-0252-f95d-d027-1ca3458a30f2"),
        ])
    func good(text: String, stored: String) {
        #expect(SessionID(text)?.text == stored)
        #expect(SessionID(text)?.description == stored)
    }

    @Test(
        "a text that is not a UUID in the 8-4-4-4-12 form is not a session ID",
        arguments: [
            "2f493bf0-1598-4b3b-b419-8acb9cb11bc", "2f493bf0-1598-4b3b-b419-8acb9cb11bcbf",
            "2f493bf0-1598-4b3b-b419-8acb9cb11bcb\n", "2f493bf0159844b3bb4198acb9cb11bcb",
            "2f493bf0-1598-4b3b-b419", "2f493bf0-1598-4b3b-b419-8acb9cb11bcg", "not-a-uuid", "",
            "-", "----", "2f493bf0-1598-4b3b-b419-8acb9cb11bc\u{0}",
            "{2f493bf0-1598-4b3b-b419-8acb9cb1}", " 2f493bf0-1598-4b3b-b419-8acb9cb11bc",
            "2f493bf0-1598-4b3b-b4198-acb9cb11bcb", "٣f493bf0-1598-4b3b-b419-8acb9cb11bc",
        ])
    func bad(text: String) {
        #expect(SessionID(text) == nil, "\(text.debugDescription)")
    }

    // The two forms of one ID are one value.
    @Test func theTwoFormsOfOneIDAreOneValue() {
        let text = "73b5ca76-a4a8-4f97-9764-e41657296414"
        let lower = SessionID(text)
        let upper = SessionID(text.uppercased())
        #expect(lower != nil)
        #expect(lower == upper)
        #expect(Set([lower, upper]).count == 1)
    }

    @Test func sessionIDsSortByTheirText() {
        let texts = ["b0000000-0000-4000-8000-000000000000", "A0000000-0000-4000-8000-000000000000"]
        let ids = texts.compactMap { SessionID($0) }
        #expect(ids.count == 2)
        #expect(ids.sorted().map(\.text) == ids.map(\.text).sorted())
    }
}
