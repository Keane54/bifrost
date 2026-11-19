// The read of the process table through libproc. Safety: the read only looks at the processes of
// the user. The test checks its own process and its parent, and starts or signals no process.
import Foundation
import Testing

@testable import BifrostHealth

@Suite("process table")
struct ProcessTableTests {
    @Test func theTableHasThisTestProcessAndItsParent() async throws {
        let table = await ProcessTable().read()
        let me = try #require(table.first { $0.pid == getpid() })
        #expect(me.parent == getppid())
        #expect(me.footprint > 0)
        #expect(me.cpuTime > .zero)
        let parent = try #require(table.first { $0.pid == getppid() })
        #expect(parent.footprint > 0)
        // Each process is in the table one time.
        #expect(Set(table.map(\.pid)).count == table.count)
    }

    @Test func theCPUTimeOfThisProcessGrows() async throws {
        let first = try #require(await ProcessTable().read().first { $0.pid == getpid() })
        // Some work of this process, so its CPU time grows.
        var total = 0
        for value in 0..<2_000_000 { total &+= value % 7 }
        #expect(total > 0)
        let second = try #require(await ProcessTable().read().first { $0.pid == getpid() })
        #expect(second.cpuTime > first.cpuTime)
    }
}
