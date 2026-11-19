// The session IDs of a row (docs/behaviour/actions.md, "The IDs of a session"). The row ID
// (sessionId) never changes. The current ID is the conversation that the row shows now, and a
// /clear changes it.
import BifrostFoundation

extension SessionRow {
    // The session ID of the conversation that the row shows now.
    package var currentIdOrRow: String { currentId ?? sessionId }

    // The ID that "claude --resume" needs to continue the session of the row, parsed here, so no
    // raw text reaches the argument. For an owned (background) row it is the resume ID, the
    // original session ID of the job: a resume by another ID starts a second job. It is nil while
    // Bifrost does not know it. For an interactive (external) row it is the current ID. An ID
    // that is not a session ID also gives nil.
    package var continueId: SessionID? {
        switch kind {
        case .owned: resumeId.flatMap { SessionID($0) }
        case .external: SessionID(currentIdOrRow)
        }
    }
}
