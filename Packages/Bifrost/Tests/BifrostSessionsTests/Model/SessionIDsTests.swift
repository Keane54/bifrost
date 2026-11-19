// The IDs of a row (docs/behaviour/actions.md, "The IDs of a session"): the row ID never
// changes, the current ID is the conversation that the row shows now, and the continue ID is
// the session ID that a resume of the row needs.
import BifrostFoundation
import BifrostTestSupport
import Testing

@testable import BifrostSessions

private let rowId = "a1b2c3d4-0000-4000-8000-000000000001"
private let now = "a1b2c3d4-0000-4000-8000-000000000002"
private let job = "a1b2c3d4-0000-4000-8000-000000000003"

private func row(
    kind: SessionKind, sessionId: String = rowId, currentId: String? = nil,
    resumeId: String? = nil
) -> SessionRow {
    var row = SessionRow.test(sessionId: sessionId, kind: kind)
    row.currentId = currentId
    row.resumeId = resumeId
    return row
}

@Suite("the IDs of a row")
struct SessionIDsTests {
    @Test func theCurrentIdIsTheConversationOfNowElseTheRowId() {
        #expect(row(kind: .owned).currentIdOrRow == rowId)
        #expect(row(kind: .owned, currentId: now).currentIdOrRow == now)
        #expect(row(kind: .external, currentId: now).currentIdOrRow == now)
    }

    // A resume by another ID starts a second job, so an owned row continues only with the ID of
    // its job, and with no ID until Bifrost knows it.
    @Test func anOwnedRowContinuesOnlyWithItsResumeId() {
        #expect(row(kind: .owned, currentId: now, resumeId: job).continueId == SessionID(job))
        #expect(row(kind: .owned, currentId: now).continueId == nil)
        #expect(row(kind: .owned).continueId == nil)
    }

    @Test func anInteractiveRowContinuesWithItsCurrentId() {
        #expect(row(kind: .external, currentId: now, resumeId: job).continueId == SessionID(now))
        #expect(row(kind: .external, resumeId: job).continueId == SessionID(rowId))
    }

    // The ID goes into a claude argument, so a text that is not a session ID gives none.
    @Test(arguments: ["", "row", "-x", "\(job) ", "\(job)\n--print"])
    func aTextThatIsNotASessionIdGivesNoContinueId(text: String) {
        #expect(row(kind: .owned, resumeId: text).continueId == nil)
        #expect(row(kind: .external, sessionId: text).continueId == nil)
        #expect(row(kind: .external, currentId: text).continueId == nil)
    }

    @Test func aRowWithNoResumeIdHasItsOwnText() {
        let text =
            "Bifrost doesn't know which ID resumes this session yet. Try again in 30 seconds."
        #expect(ActionRefusal.noResumeId.message == text)
    }
}
