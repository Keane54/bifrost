// The author of a comment or a review, and who counts as a trusted author (docs/behaviour/
// reviews.md, "The GitHub data").

// The relation of an author to the repository, as GitHub gives it. Each value that Bifrost does
// not use reads as other.
package enum AuthorAssociation: String, Sendable, Codable {
    case owner = "OWNER"
    case member = "MEMBER"
    case collaborator = "COLLABORATOR"
    case contributor = "CONTRIBUTOR"
    case none = "NONE"
    case other

    package init(from decoder: any Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: text) ?? .other
    }
}

package struct Author: Sendable, Equatable, Codable {
    package var login: String
    package var isBot: Bool
    package var association: AuthorAssociation

    package init(login: String, isBot: Bool, association: AuthorAssociation) {
        self.login = login
        self.isBot = isBot
        self.association = association
    }
}

package enum Authors {
    package static let copilotLogin = "copilot-pull-request-reviewer"

    // Copilot is a bot with one fixed login.
    package static func isCopilot(_ author: Author) -> Bool {
        author.isBot && author.login == copilotLogin
    }

    // An owner, a member or a collaborator of the repository, or Copilot. A bot other than Copilot
    // is never trusted. GitHub ignores the case of a login, so the viewer is never a trusted
    // author of their own PR, in any case.
    package static func isTrusted(_ author: Author, viewer: String) -> Bool {
        if isCopilot(author) { return true }
        guard !author.isBot, author.login.lowercased() != viewer.lowercased() else { return false }
        switch author.association {
        case .owner, .member, .collaborator: return true
        case .contributor, .none, .other: return false
        }
    }
}
