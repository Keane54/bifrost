import Testing

// SwiftUI gives one field editor to the text fields of all the windows of the process: the
// field editor of a TextField in a second window is the same object as in the first window, and
// the first window then loses it (a probe of 2026-11-17). So a SwiftUI text field that starts to
// edit in the window of one test takes the editor from a field in the window of another test, and
// that field stops editing. The app has these fields in its one main window, so only the tests
// have the conflict.
//
// A test that lets a SwiftUI text field edit in a window has this trait (on its suite or on the
// test). The trait runs each test case with the trait alone among them, one after the other, in
// the order of arrival. Each other test still runs at the same time.
package struct SharedFieldEditor: TestTrait, SuiteTrait, TestScoping {
    package var isRecursive: Bool { true }

    // The trait covers each test case, not the suite, so a test case never waits for its suite.
    package func scopeProvider(for test: Test, testCase: Test.Case?) -> Self? {
        testCase == nil ? nil : self
    }

    package func provideScope(
        for test: Test, testCase: Test.Case?,
        performing function: @concurrent @Sendable () async throws -> Void
    ) async throws {
        await FieldEditorTurns.shared.enter()
        do {
            try await function()
        } catch {
            await FieldEditorTurns.shared.leave()
            throw error
        }
        await FieldEditorTurns.shared.leave()
    }
}

extension Trait where Self == SharedFieldEditor {
    // The test lets a SwiftUI text field edit in a window (SharedFieldEditor).
    package static var sharedFieldEditor: Self { Self() }
}

// The turns of the test cases with the trait: one at a time, in the order of arrival.
private actor FieldEditorTurns {
    static let shared = FieldEditorTurns()

    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func enter() async {
        guard busy else {
            busy = true
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    // The next test case in the order of arrival gets the turn, or the turns are free.
    func leave() {
        if waiting.isEmpty {
            busy = false
        } else {
            waiting.removeFirst().resume()
        }
    }
}
