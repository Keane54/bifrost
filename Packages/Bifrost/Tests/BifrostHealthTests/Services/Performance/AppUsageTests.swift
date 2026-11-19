// The use of the Claude sessions, the terminal processes with no chat window and the read of the
// sources of the app (docs/behaviour/health.md, "Performance"). Safety: the process table is a
// fake, so no test reads the real processes.
import BifrostFoundation
import BifrostSessions
import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostHealth

// A process of a fake table: its memory in MB and its CPU time in seconds.
private func process(
    _ pid: pid_t, parent: pid_t, memory: Double, cpu: Double = 0
) -> ProcessSample {
    ProcessSample(pid: pid, parent: parent, footprint: mb(memory), cpuTime: .seconds(cpu))
}

// A row of a session with the process.
private func row(_ name: String, pid: pid_t?) -> SessionRow {
    SessionRow.test(sessionId: "\(name)-id", name: name, pid: pid)
}

private struct FakeProcesses: ProcessSampling {
    let table: [ProcessSample]

    func read() async -> [ProcessSample] { table }
}

private let chatSession: SessionID = "11111111-2222-3333-4444-555555555555"

@Suite("performance app usage")
struct AppUsageTests {
    @Test func aSessionIsItsProcessWithAllItsChildProcesses() throws {
        let earlier = TableRead(at: .zero, [process(100, parent: 1, memory: 0, cpu: 10)])
        let read = TableRead(
            at: .seconds(10),
            [
                process(1, parent: 0, memory: 5),
                process(100, parent: 1, memory: 300, cpu: 12),
                process(101, parent: 100, memory: 50),
                process(102, parent: 100, memory: 20),
                process(103, parent: 102, memory: 10),
                process(200, parent: 1, memory: 100),
                process(300, parent: 1, memory: 900),
            ])
        let rows = [row("alpha", pid: 100), row("beta", pid: 200), row("gamma", pid: nil)]
        let sessions = AppUsage.sessions(rows, in: read, since: earlier, own: [])
        #expect(sessions.top.map(\.row.name) == ["alpha", "beta"])
        let alpha = try #require(sessions.top.first)
        #expect(alpha.use.memory == mb(380))
        // 2 s of CPU time in 10 s.
        #expect(abs(alpha.use.cpu - 20) < 0.000_001)
        #expect(sessions.total.memory == mb(480))
        #expect(sessions.more == SessionGroup(count: 0, use: .zero))
    }

    @Test func aSessionInsideAnotherKeepsItsOwnProcesses() {
        let read = TableRead(
            at: .seconds(10),
            [
                process(100, parent: 1, memory: 300),
                process(110, parent: 100, memory: 200),
                process(111, parent: 110, memory: 50),
            ])
        let rows = [row("outer", pid: 100), row("inner", pid: 110)]
        let sessions = AppUsage.sessions(rows, in: read, since: nil, own: [])
        #expect(sessions.top.map(\.row.name) == ["outer", "inner"])
        #expect(sessions.top.map(\.use.memory) == [mb(300), mb(250)])
        #expect(sessions.total.memory == mb(550))
    }

    @Test func bifrostsProcessesCountForNoSession() {
        let read = TableRead(
            at: .seconds(10),
            [
                process(appPID, parent: 1, memory: 400),
                process(terminalPID, parent: appPID, memory: 150),
                process(30, parent: terminalPID, memory: 10),
            ])
        // A row with the pid of a chat terminal, and a row with the pid of the app.
        let rows = [row("terminal", pid: terminalPID), row("app", pid: appPID)]
        let sessions = AppUsage.sessions(
            rows, in: read, since: nil, own: [appPID, terminalPID])
        #expect(sessions.top.isEmpty)
        #expect(sessions.total == .zero)
    }

    @Test func theFourthSessionGoesToMore() {
        let read = TableRead(
            at: .seconds(10),
            (1...5).map { process(pid_t(100 + $0), parent: 1, memory: Double($0) * 100) })
        let rows = (1...5).map { row("s\($0)", pid: pid_t(100 + $0)) }
        let sessions = AppUsage.sessions(rows, in: read, since: nil, own: [])
        #expect(sessions.top.map(\.row.name) == ["s5", "s4", "s3"])
        #expect(sessions.more == SessionGroup(count: 2, use: Use(memory: mb(300), cpu: 0)))
        #expect(sessions.total.memory == mb(1500))
    }

    @Test func aTerminalWithNoChatWindowIsAnOrphanAfter60s() {
        var watch = OrphanWatch()
        let chat = TerminalProcess(view: .chat(chatSession), pid: 40)
        let input = TerminalProcess(view: .input("row-1"), pid: 41)
        // The chat has its window: it is never an orphan.
        #expect(watch.count([chat], chatPanels: [chatSession], at: .zero) == 0)
        #expect(watch.count([chat], chatPanels: [chatSession], at: .seconds(120)) == 0)
        // The window closed, and the terminal stays.
        #expect(watch.count([chat, input], chatPanels: [], at: .seconds(130)) == 0)
        #expect(watch.count([chat, input], chatPanels: [], at: .seconds(190)) == 0)
        #expect(watch.count([chat, input], chatPanels: [], at: .seconds(191)) == 2)
        // The window opened again: only the hidden attach of the input is left.
        #expect(watch.count([chat, input], chatPanels: [chatSession], at: .seconds(200)) == 1)
        // A terminal that went counts no more, and a new one counts from its start.
        let next = TerminalProcess(view: .input("row-1"), pid: 42)
        #expect(watch.count([next], chatPanels: [], at: .seconds(210)) == 0)
        #expect(watch.count([next], chatPanels: [], at: .seconds(271)) == 1)
    }

    @MainActor
    @Test func theReadTakesTheSourcesOfTheApp() async throws {
        let table = [
            process(appPID, parent: 1, memory: 400),
            process(40, parent: appPID, memory: 150),
            process(100, parent: 1, memory: 300, cpu: 13),
        ]
        let terminals = [TerminalProcess(view: .chat(chatSession), pid: 40)]
        let rows = [row("alpha", pid: 100), row("terminal", pid: 40)]
        let usage = AppUsage(
            processes: FakeProcesses(table: table), app: appPID, terminals: { terminals },
            rows: { rows }, chatPanels: { [chatSession] })
        let earlier = TableRead(at: .seconds(5), [process(100, parent: 1, memory: 0, cpu: 12)])
        let reading = await usage.read(at: .seconds(15), since: earlier)
        #expect(reading.table.at == .seconds(15))
        #expect(reading.table.processes.count == 3)
        #expect(reading.terminals == terminals)
        #expect(reading.chatPanels == [chatSession])
        // The read gives the sessions too: a chat terminal of the app is never a session.
        let sessions = try #require(reading.sessions)
        #expect(sessions.top.map(\.row.name) == ["alpha"])
        let alpha = try #require(sessions.top.first)
        #expect(alpha.use.memory == mb(300))
        // 1 s of CPU time in 10 s.
        #expect(abs(alpha.use.cpu - 10) < 0.000_001)
        #expect(usage.app == appPID)
    }

    @MainActor
    @Test func aReadWithNoAppProcessGivesNoSessions() async {
        let usage = AppUsage(
            processes: FakeProcesses(table: []), app: appPID, terminals: { [] },
            rows: { [row("alpha", pid: 100)] }, chatPanels: { [] })
        let reading = await usage.read(at: .seconds(15), since: nil)
        #expect(reading.table.processes.isEmpty)
        #expect(reading.sessions == nil)
    }
}
