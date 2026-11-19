import Foundation
import Testing

@testable import BifrostReviews

// The authors that Reviews trusts.

private func author(
    _ login: String, bot: Bool = false, _ association: AuthorAssociation = .none
) -> Author {
    Author(login: login, isBot: bot, association: association)
}

@Suite("trusted authors", .timeLimit(.minutes(1)))
struct AuthorsTests {
    @Test func copilotIsTrustedButNeverAReviewer() {
        let copilot = author(Authors.copilotLogin, bot: true)
        #expect(Authors.isCopilot(copilot))
        #expect(Authors.isTrusted(copilot, viewer: "viewer-a"))
        // A person with the login of Copilot is no bot, so it is neither Copilot nor trusted.
        #expect(!Authors.isCopilot(author(Authors.copilotLogin)))
        #expect(!Authors.isTrusted(author(Authors.copilotLogin), viewer: "viewer-a"))
    }

    @Test func theViewerIsNeverATrustedAuthorOfTheirOwnPR() {
        for association in [AuthorAssociation.owner, .member, .collaborator] {
            #expect(!Authors.isTrusted(author("Viewer-A", association), viewer: "viewer-a"))
            #expect(Authors.isTrusted(author("user-b", association), viewer: "viewer-a"))
        }
    }

    @Test func anOutsiderOrAnotherBotIsNotTrusted() {
        for association in [AuthorAssociation.contributor, .none, .other] {
            #expect(!Authors.isTrusted(author("user-b", association), viewer: "viewer-a"))
        }
        #expect(!Authors.isTrusted(author("some-bot", bot: true, .member), viewer: "viewer-a"))
        #expect(!Authors.isCopilot(author("some-bot", bot: true)))
    }

    @Test func anUnknownAssociationReadsAsOther() throws {
        let decoded = try JSONDecoder().decode(
            [AuthorAssociation].self,
            from: Data(#"["OWNER","FIRST_TIME_CONTRIBUTOR","NONE"]"#.utf8))
        #expect(decoded == [.owner, .other, .none])
    }
}
