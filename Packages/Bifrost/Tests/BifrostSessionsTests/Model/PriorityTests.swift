// The priorities of a session (docs/behaviour/actions.md, "Priority"): 1 to 5, and 1 is the
// highest.
import Testing

@testable import BifrostSessions

@Suite("the priority of a session")
struct PriorityValueTests {
    @Test func thePrioritiesAreOneToFiveInOrder() {
        #expect(SessionPriority.allCases.map(\.rawValue) == [1, 2, 3, 4, 5])
    }

    @Test(arguments: [0, 6, -1, 10])
    func anotherNumberIsNoPriority(value: Int) {
        #expect(SessionPriority(rawValue: value) == nil)
    }
}
