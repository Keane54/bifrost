import Foundation
import Testing

@testable import BifrostWindows

// The reading of the answer of the GitHub releases API (docs/behaviour/updates.md, "Release
// notes"): the summary, the shown sections with their friendly titles, and the list of releases.
@Suite("release notes")
struct ReleaseNotesTests {
    @Test func theSectionsHaveFriendlyTitlesInTheirOrder() {
        let parts = ReleaseNotes.parseBody(fullBody)
        #expect(parts.summary == "Release of the new window.")
        // Documentation is hidden. Changed comes first.
        #expect(parts.sections.map(\.title) == ["Changed", "New", "Fixed", "Faster"])
        #expect(
            parts.sections[0].items == [ReleaseItem(scope: "settings", text: "the key file moved")]
        )
        #expect(
            parts.sections[1].items == [
                ReleaseItem(scope: "chat", text: "a **bold** and `code` item"),
                ReleaseItem(text: "an item with no scope"),
            ])
    }

    // The commit link, and all text after it (a "closes" link), are not a part of the item.
    @Test func theCommitLinkAndWhatFollowsItAreDropped() {
        let parts = ReleaseNotes.parseBody(fullBody)
        #expect(parts.sections[2].items == [ReleaseItem(scope: "keys", text: "fix one")])
    }

    @Test func aBodyWithNoHeadingIsOnlyASummary() {
        let parts = ReleaseNotes.parseBody("Just a note.\n\nSecond paragraph.")
        #expect(parts.summary == "Just a note.\n\nSecond paragraph.")
        #expect(parts.sections.isEmpty)
        #expect(ReleaseNotes.parseBody("").summary.isEmpty)
    }

    @Test func twoSectionsWithTheSameFriendlyTitleBecomeOne() {
        let body = "### BREAKING CHANGES\n* one\n\n### ⚠ BREAKING CHANGES\n* two\n"
        let parts = ReleaseNotes.parseBody(body)
        #expect(parts.sections.map(\.title) == ["Changed"])
        #expect(parts.sections[0].items.map(\.text) == ["one", "two"])
    }

    @Test func aSectionWithNoItemAndALineThatIsNoItemAreDropped() {
        let body = "### Features\n\nsome words\n  * indented\n\n### Bug Fixes\n* kept\n"
        let parts = ReleaseNotes.parseBody(body)
        #expect(parts.sections.map(\.title) == ["Fixed"])
    }

    @Test func aScopeNeedsTextAfterIt() {
        let body = "### Features\n* **chat:**\n* **chat:** text\n* - dash item\n"
        let items = ReleaseNotes.parseBody(body).sections.first?.items
        #expect(items?.first == ReleaseItem(text: "**chat:**"))
        #expect(items?.dropFirst().first == ReleaseItem(scope: "chat", text: "text"))
    }

    @Test func aListOfReleasesComesNewestFirst() throws {
        let data = releasesAnswer(
            releaseJSON(tag: "v1.1.0", body: "Older."), releaseJSON(tag: "v1.10.0", body: fullBody),
            releaseJSON(tag: "v1.2.0"))
        let releases = try #require(ReleaseNotes.parse(data))
        #expect(releases.map(\.version.description) == ["1.10.0", "1.2.0", "1.1.0"])
        #expect(releases[0].summary == "Release of the new window.")
        #expect(releases[0].sections.count == 4)
        #expect(releases[0].page.absoluteString == releasePage("v1.10.0"))
        #expect(releases[2].summary == "Older.")
        #expect(releases[0].date == Date(timeIntervalSince1970: 1_794_301_200))
    }

    @Test func aListWithABadReleaseDropsIt() throws {
        let data = releasesAnswer(
            releaseJSON(tag: "v1.0.0"), releaseJSON(tag: "v1.1.0", draft: true),
            releaseJSON(tag: "v1.2.0", prerelease: true), releaseJSON(tag: "v1.3.0-beta.1"),
            releaseJSON(tag: "latest"), releaseJSON(tag: "v1.4.0", date: "yesterday"),
            releaseJSON(tag: "v1.5.0", page: "http://github.com/example/bifrost/releases/tag/x"),
            "42", "null", #"{"tag_name": 7}"#, releaseJSON(tag: "v1.6.0", body: nil))
        let releases = try #require(ReleaseNotes.parse(data))
        #expect(releases.map(\.version.description) == ["1.6.0", "1.0.0"])
        #expect(releases[0].summary.isEmpty)
        #expect(releases[0].isInternalOnly)
    }

    @Test func aReleaseOutsideTheReleasesPageIsDropped() throws {
        let other = "https://github.com/someone/other/releases/tag/v2.0.0"
        let data = releasesAnswer(
            releaseJSON(tag: "v1.0.0"), releaseJSON(tag: "v2.0.0", page: other),
            releaseJSON(tag: "v3.0.0", page: releasesPage.absoluteString + "x/tag/v3.0.0"))
        let all = try #require(ReleaseNotes.parse(data))
        #expect(all.count == 3)
        let under = try #require(ReleaseNotes.parse(data, pagesUnder: releasesPage))
        #expect(under.map(\.version.description) == ["1.0.0"])
    }

    @Test func aRepeatedVersionComesOnce() throws {
        let data = releasesAnswer(
            releaseJSON(tag: "v1.0.0", body: "First."), releaseJSON(tag: "1.0.0", body: "Second."),
            releaseJSON(tag: "v1.0.0+build", body: "Third."), releaseJSON(tag: "v0.9.0"))
        let releases = try #require(ReleaseNotes.parse(data))
        #expect(releases.map(\.version.description) == ["1.0.0", "0.9.0"])
        #expect(releases.first?.summary == "First.")
    }

    @Test func atMostTenReleasesStay() throws {
        let entries = (0..<14).map { releaseJSON(tag: "v1.\($0).0") }
        let data = Data(("[" + entries.joined(separator: ",") + "]").utf8)
        let releases = try #require(ReleaseNotes.parse(data))
        #expect(releases.count == ReleaseNotes.maxReleases)
        #expect(releases.first?.version.description == "1.13.0")
    }

    @Test func anAnswerThatIsNotAListIsNil() {
        #expect(ReleaseNotes.parse(Data(#"{"message": "Not Found"}"#.utf8)) == nil)
        #expect(ReleaseNotes.parse(Data("not json".utf8)) == nil)
        #expect(ReleaseNotes.parse(Data()) == nil)
        #expect(ReleaseNotes.parse(Data("[]".utf8)) == [])
    }

    @Test func theDateShowsAsDayMonthYear() {
        let date = Date(timeIntervalSince1970: 1_794_301_200)
        #expect(ReleaseNotesText.date(date, zone: .gmt) == "10 Nov 2026")
    }
}
