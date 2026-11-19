import BifrostTestSupport
import Foundation
import Testing

// The guard of the tests that start real processes or write real files (TestSandbox in
// BifrostTestSupport). scripts/check.sh runs each test in the test sandbox.
@Suite("the test sandbox guard")
struct TestSandboxTests {
    @Test func theTestsRunInTheTestSandbox() {
        #expect(TestSandbox.isActive())
    }

    @Test func aRunWithNoProfileRecordsAnIssueAndThrows() {
        withKnownIssue {
            #expect(throws: TestSandbox.Refusal.notInSandbox) { try TestSandbox.require([:]) }
        }
    }

    @Test func aProfilePathWithNoFileIsNotTheSandbox() {
        #expect(!TestSandbox.isActive([TestSandbox.variable: ""]))
        #expect(!TestSandbox.isActive([TestSandbox.variable: "/nonexistent-bifrost/profile.sb"]))
    }
}
