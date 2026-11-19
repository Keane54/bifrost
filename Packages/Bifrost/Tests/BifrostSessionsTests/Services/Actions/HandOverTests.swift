// The Hand over run (docs/behaviour/actions.md, "Hand over"): the send of the request, the wait
// for the note, the save of the note and the start of the new session. The registry is real, on
// fake session lists and a manual clock (FakeActionDeps). The session input types into the chat
// attach of a fake PTY (FakeSpawner), so no program runs and no real session gets input. The
// transcript, the rules and the notes are in a temporary folder. The time limit of the wait runs
// on a manual clock of its own.
import BifrostFoundation
import BifrostTestSupport
import Darwin
import Foundation
import Testing

@testable import BifrostSessions

private let s1 = "f3a9c2d1-4b5e-4c6d-8e7f-0a1b2c3d4e5f"
private let newId = "4cb23c30-7283-4d9e-bfa0-2b3c4d5e6f70"
private let short1: ShortID = "f3a9c2d1"
private let at = Date(timeIntervalSince1970: 1_795_000_000)
private let size = TerminalSize(cols: 97, rows: 41)

// The terminal model of a hidden attach. It gives no reply.
@MainActor
private final class QuietTerminal: HiddenTerminal {
    func feed(_ bytes: [UInt8]) -> [UInt8] { [] }
}

@MainActor
private final class HandOverHarness {
    let deps: FakeActionDeps
    let spawner = FakeSpawner()
    // The clock of the session input, and the clock of the time limit of the wait.
    let inputClock = ManualClock()
    let limitClock = ManualClock()
    let ptys: PTYManager
    let input: SessionInput
    let folder: TemporaryFolder
    let handOver: HandOver
    // Each spec that the start got, in order, and the answer of each start.
    private(set) var starts: [NewSessionSpec] = []
    var startAnswer: Result<String, ActionRefusal> = .success(newId)
    // True: the start shows the row of the new session in the registry first.
    var showsNewRow = false
    private var attaches: [PTYAttach] = []

    // rules: the text of the rules file, or nil for no file. The transcript of the session
    // starts with a user message and the note of an earlier hand-over.
    init(rules: String? = "The rules.\n") async throws {
        folder = try TemporaryFolder()
        deps = FakeActionDeps(active: [Entry.running(s1)])
        ptys = PTYManager(
            claude: ClaudeRunner(path: "/bin/claude", baseEnvironment: [:], runner: NoRunner()),
            spawner: spawner)
        let registry = deps.registry
        input = SessionInput(
            ptys: ptys, sizes: SessionSizeReader(inspector: FakeProcessInspector(size: size)),
            rows: { registry.rows }, makeTerminal: { _ in QuietTerminal() }, clock: inputClock,
            log: Recorder<SessionsLogEvent>())
        try FileManager.default.createDirectory(
            atPath: folder.appending("projects/-p"), withIntermediateDirectories: true)
        let earlier = HandOverLines.userMessage + HandOverLines.request("0ld0ld00")
            + HandOverLines.reply("old note") + HandOverLines.turnEnd
        try Data(earlier.utf8).write(to: URL(filePath: folder.appending("projects/-p/\(s1).jsonl")))
        if let rules { try Data(rules.utf8).write(to: URL(filePath: folder.appending("rules.md"))) }
        handOver = HandOver(
            input: input, registry: registry, projects: folder.url.appending(path: "projects"),
            notes: folder.url.appending(path: "notes"),
            rules: folder.url.appending(path: "rules.md"), clock: limitClock, now: { at })
        await deps.start()
        try await openQuietChat()
    }

    var transcript: String { folder.appending("projects/-p/\(s1).jsonl") }
    var notesFolder: String { folder.appending("notes") }

    // The names of the note files.
    var notes: [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: notesFolder))?.sorted() ?? []
    }

    // The text that the session got through its chat attach.
    var typed: String {
        spawner.fakes.flatMap(\.written).map { String(decoding: $0, as: UTF8.self) }.joined()
    }

    // Open the attach of the chat of the session as a chat does, with output 1.5 s ago: the
    // output is quiet, so a send types into it at once.
    private func openQuietChat() async throws {
        let session = try #require(SessionID(s1))
        await input.chatOpening(chat: session)
        let attach = try await ptys.open(.test(.chat(session), shortId: short1), size: size)
        attaches.append(try #require(attach))
        input.opened(chat: session, shortId: short1)
        input.output(chat: session)
        inputClock.advance(by: .milliseconds(1500))
    }

    // Start the hand-over of the row of the session as a job of its own.
    func start() throws -> Task<Result<HandOverDone, HandOverFailure>, Never> {
        let row = try #require(deps.row(s1))
        return Task {
            do throws(HandOverFailure) {
                return .success(
                    try await handOver.run(row) { spec throws(ActionRefusal) in
                        try await self.startSession(spec)
                    })
            } catch {
                return .failure(error)
            }
        }
    }

    private func startSession(_ spec: NewSessionSpec) async throws(ActionRefusal) -> String {
        starts.append(spec)
        let id = try startAnswer.get()
        if showsNewRow {
            await deps.show([Entry.running(s1), Entry.running(id)]) { rows in
                rows.contains { $0.sessionId == id }
            }
        }
        return id
    }

    // Wait until the request is typed into the chat, and give its request ID.
    func typedRequest(sourceLocation: SourceLocation = #_sourceLocation) async -> String? {
        await HandOverLines.typedRequest(
            { typed }, inputClock: inputClock, sourceLocation: sourceLocation)
    }

    // Run a hand-over to its end with a reply in the mode, and give its result.
    func handOver(mode: JSONValue? = "plan", sourceLocation: SourceLocation = #_sourceLocation)
        async throws -> HandOverDone
    {
        let job = try start()
        let id = try #require(await typedRequest(sourceLocation: sourceLocation))
        try append(
            HandOverLines.request(id, mode: mode) + HandOverLines.reply("n")
                + HandOverLines.turnEnd)
        return try await result(of: job, sourceLocation: sourceLocation).get()
    }

    // Give the session a usage line with the permission mode, as a line of Live details does.
    func usage(mode: String) async {
        deps.registry.pushLive(
            .usage(sessionId: s1, at: 1_800_000_000_000, LiveUsage(permissionMode: mode)))
        await waitUntil { deps.row(s1)?.usage?.permissionMode == mode }
    }

    // The park check of the old session after the hand-over, with the session list of now.
    func checkPark(_ done: HandOverDone, active: [AgentEntry]) async -> ParkRefusal? {
        deps.lists.active = active
        do throws(ParkRefusal) {
            try await handOver.checkPark(s1, after: done)
            return nil
        } catch {
            return error
        }
    }

    // Add the text at the end of the transcript, as Claude Code does.
    func append(_ text: String) throws {
        let handle = try FileHandle(forWritingTo: URL(filePath: transcript))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    }

    // The result of the job, within a limit on the real clock. At the limit the wait records an
    // issue and cancels the job.
    func result(
        of job: Task<Result<HandOverDone, HandOverFailure>, Never>,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async -> Result<HandOverDone, HandOverFailure> {
        let ended = TaskEnd(job)
        if !(await waitUntil(sourceLocation: sourceLocation) { ended.ended })
        {
            job.cancel()
        }
        return await job.value
    }

    func close() {
        ptys.closeAll()
        folder.remove()
    }
}

// The number of open files of this process at the real path.
private func openFiles(at path: String) -> Int {
    var count = 0
    for fd in 0..<getdtablesize() {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd, F_GETPATH, &buffer) == 0 else { continue }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        if String(decoding: bytes, as: UTF8.self) == path { count += 1 }
    }
    return count
}

// A Gregorian calendar in the time zone of the Mac, as the hand-over uses.
private var localCalendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .autoupdatingCurrent
    return calendar
}

private func contents(_ path: String) -> String? {
    FileManager.default.contents(atPath: path).map { String(decoding: $0, as: UTF8.self) }
}

@Suite("Hand over", .serialized, .testTimeLimit)
@MainActor
struct HandOverTests {
    // The request goes through the session input, the note of the reply goes to a new file,
    // and the new session starts in the old folder with the model and the mode of the reply, a
    // new name and the continue prompt. The new session takes the priority and the watchlist
    // place of the old one. The note of the earlier hand-over before the baseline never counts.
    @Test func aHandOverSavesTheNoteAndStartsTheNewSession() async throws {
        let h = try await HandOverHarness()
        defer { h.close() }
        #expect(h.deps.registry.setPriority(s1, .p2))
        #expect(h.deps.registry.watchAdd(s1, .green))
        h.showsNewRow = true
        let job = try h.start()
        let id = try #require(await h.typedRequest())
        #expect(h.typed.hasPrefix(InputPlan.pasteStart + "Bifrost hand-over request \(id)\r"))
        #expect(h.typed.contains("\rThe rules.\r"))
        try h.append(
            HandOverLines.request(id) + HandOverLines.reply("# Note\nNext step.")
                + HandOverLines.turnEnd)
        let done = try await h.result(of: job).get()
        let file = HandOverText.noteFileName("bifrost-test-s", at: at, calendar: localCalendar)
        let path = "\(h.notesFolder)/\(file)"
        #expect(done.name == "bifrost-test-s (2)")
        #expect(done.notePath == path)
        #expect(done.sessionId == newId)
        #expect(done.transcript.path(percentEncoded: false) == h.transcript)
        let size = try FileManager.default.attributesOfItem(atPath: h.transcript)[.size] as? Int
        #expect(done.readEnd == size)
        #expect(contents(path) == "# Note\nNext step.")
        let spec = NewSessionSpec.check(
            cwd: "/p", name: "bifrost-test-s (2)", model: .opus, permissionMode: .plan,
            prompt: HandOverText.continuePrompt(note: "# Note\nNext step.", notePath: path),
            worktree: false)
        #expect(h.starts == [try spec.get()])
        #expect(h.deps.row(newId)?.priority == .p2)
        #expect(h.deps.row(s1)?.priority == nil)
        #expect(h.deps.row(newId)?.watch?.colour == .green)
        #expect(h.deps.row(s1)?.watch == nil)
    }

    // The reply with the note is in the transcript, but the session still works, so the wait
    // goes on. The next change of the row to idle ends it.
    @Test func theTranscriptIsReadOnlyWhenTheRowIsIdle() async throws {
        let h = try await HandOverHarness()
        defer { h.close() }
        let job = try h.start()
        let id = try #require(await h.typedRequest())
        await h.deps.show([Entry.running(s1, status: .busy)]) { $0.first?.status == .busy }
        try h.append(HandOverLines.request(id) + HandOverLines.reply("n") + HandOverLines.turnEnd)
        await waitUntil {
            h.handOver.lastReply
                == .done(note: "n", model: HandOverLines.model, mode: .known(.plan))
        }
        #expect(h.starts.isEmpty)
        #expect(h.notes.isEmpty)
        await h.deps.show([Entry.running(s1)])
        #expect(try await h.result(of: job).get().sessionId == newId)
        #expect(h.starts.count == 1)
    }

    // A short turn can show no working state in the samples of the registry. The wait read the
    // transcript once before the reply, and the registry reads no list here, so only the change
    // event of the transcript file wakes the wait.
    @Test func aShortTurnWithNoWorkingStateEndsOnTheFileEvent() async throws {
        let h = try await HandOverHarness()
        defer { h.close() }
        let job = try h.start()
        let id = try #require(await h.typedRequest())
        await waitUntil { h.handOver.lastReply == .waiting }
        let lists = h.deps.lists.activeCalls
        try h.append(HandOverLines.request(id) + HandOverLines.reply("n") + HandOverLines.turnEnd)
        #expect(try await h.result(of: job).get().sessionId == newId)
        #expect(h.deps.lists.activeCalls == lists)
    }

    // The session parks or leaves the list during the wait: nothing starts and no note is saved.
    // A session that Bifrost started parks when it leaves the list.
    @Test(arguments: [false, true])
    func aStoppedSessionStartsNothing(parks: Bool) async throws {
        let h = try await HandOverHarness()
        defer { h.close() }
        if parks { h.deps.registry.markStarted(s1) }
        let job = try h.start()
        _ = try #require(await h.typedRequest())
        await h.deps.show([]) { rows in
            parks ? rows.first?.state == .parked : rows.isEmpty
        }
        #expect(await h.result(of: job) == .failure(.stopped))
        #expect(h.starts.isEmpty)
        #expect(h.notes.isEmpty)
    }

    // The quit cancels the job of the hand-over: the wait ends as stopped, each task of the wait
    // ends, and the watch of the transcript closes its file.
    @Test func aCancelAtTheQuitEndsTheWait() async throws {
        let h = try await HandOverHarness()
        defer { h.close() }
        let job = try h.start()
        _ = try #require(await h.typedRequest())
        await waitUntil { h.handOver.lastReply == .waiting }
        let transcript = "\(h.folder.realPath)/projects/-p/\(s1).jsonl"
        #expect(openFiles(at: transcript) >= 1)
        // The limit of the wait runs in its own task, so its sleep can start after the first read.
        await h.limitClock.waitForSleepers(exactly: 1)
        job.cancel()
        #expect(await h.result(of: job) == .failure(.stopped))
        #expect(h.limitClock.sleeperCount == 0)
        await waitUntil { openFiles(at: transcript) == 0 }
        #expect(h.starts.isEmpty)
        #expect(h.notes.isEmpty)
    }

    // The new session gets the mode of the request. A default request stays default, also with
    // a usage line in another mode, and bypassPermissions never gives a mode. Only a request
    // with no mode takes the mode of the usage line of the row.
    @Test func theModeOfTheRowCountsOnlyWhenTheRequestHasNone() async throws {
        let cases: [(request: JSONValue?, usage: String, started: PermissionMode?)] = [
            ("default", "acceptEdits", nil), ("bypassPermissions", "bypassPermissions", nil),
            ("bypassPermissions", "acceptEdits", nil), ("plan", "acceptEdits", .plan),
            (nil, "plan", .plan), (nil, "bypassPermissions", nil),
        ]
        for (request, usage, started) in cases {
            let h = try await HandOverHarness()
            defer { h.close() }
            await h.usage(mode: usage)
            _ = try await h.handOver(mode: request)
            #expect(h.starts.map(\.permissionMode) == [started])
        }
    }

    // Each check of the old session before the park: with no change, the park can go on, also
    // after metadata lines. Each changed state gives its reason.
    @Test func theParkCheckPassesWhenNothingChanged() async throws {
        let h = try await HandOverHarness()
        defer { h.close() }
        let done = try await h.handOver()
        #expect(await h.checkPark(done, active: [Entry.running(s1)]) == nil)
        try h.append(HandOverLines.line(["type": "file-history-snapshot", "messageId": "m2"]))
        #expect(await h.checkPark(done, active: [Entry.running(s1)]) == nil)
    }

    // A session list cannot turn an owned row into an external one (the row leaves the list),
    // so the check of the kind is a guard that no case here can reach.
    @Test func theParkCheckRefusesAChangedRow() async throws {
        let prompt = AgentEntry(
            sessionId: s1, cwd: "/p", isBackground: true, startedAt: 1, name: "bifrost-test-s",
            status: .waiting, pid: 4242, id: short1, waitingFor: "permission")
        let cases: [(active: [AgentEntry], refusal: ParkRefusal)] = [
            ([Entry.running(s1, status: .busy)], .busy), ([prompt], .prompt),
            ([Entry.interactive(s1)], .gone), ([], .gone),
        ]
        for (active, refusal) in cases {
            let h = try await HandOverHarness()
            defer { h.close() }
            let done = try await h.handOver()
            let result = await h.checkPark(done, active: active)
            #expect(result == refusal)
        }
    }

    @Test func theParkCheckRefusesAParkedRowAndAFailedList() async throws {
        let h = try await HandOverHarness()
        defer { h.close() }
        let done = try await h.handOver()
        h.deps.lists.activeFailure = .commandFailed(detail: "boom")
        #expect(await h.checkPark(done, active: [Entry.running(s1)]) == .unchecked)
        h.deps.lists.activeFailure = nil
        h.deps.registry.markStarted(s1)
        #expect(await h.checkPark(done, active: []) == .parked)
    }

    // A new message or a new reply after the note means that the old session is busy again. A
    // transcript that cannot be read is no proof that it is quiet.
    @Test func theParkCheckRefusesANewMessageAndAnUnreadTranscript() async throws {
        let assistant = HandOverLines.reply("Another reply.")
        for text in [HandOverLines.userMessage, assistant] {
            let h = try await HandOverHarness()
            defer { h.close() }
            let done = try await h.handOver()
            try h.append(text)
            #expect(await h.checkPark(done, active: [Entry.running(s1)]) == .newMessage)
        }
        let h = try await HandOverHarness()
        defer { h.close() }
        let done = try await h.handOver()
        try FileManager.default.removeItem(atPath: h.transcript)
        #expect(await h.checkPark(done, active: [Entry.running(s1)]) == .unread)
    }

    @Test func theParkRefusalsHaveTheirTexts() {
        let lead = "The new session started, but"
        let texts: [(ParkRefusal, String)] = [
            (.unchecked, "\(lead) Bifrost couldn't check the old one, so it left it running."),
            (.gone, "\(lead) the old one isn't in the list any more, so Bifrost didn't park it."),
            (.parked, "\(lead) the old one has already stopped, so Bifrost didn't park it."),
            (
                .notOwned,
                "\(lead) the old one now runs in another terminal, so Bifrost left it running."
            ),
            (.prompt, "\(lead) the old one is waiting on a prompt, so Bifrost left it running."),
            (.busy, "\(lead) the old one is busy again, so Bifrost left it running."),
            (.newMessage, "\(lead) the old one has a new message, so Bifrost left it running."),
            (
                .unread,
                "\(lead) Bifrost couldn't read the old one's transcript, so it left it running."
            ),
        ]
        for (refusal, text) in texts { #expect(refusal.message == text) }
    }

    // A new message from the user during the hand-over fails the wait at once.
    @Test func aNewUserMessageStartsNothing() async throws {
        let h = try await HandOverHarness()
        defer { h.close() }
        let job = try h.start()
        let id = try #require(await h.typedRequest())
        try h.append(HandOverLines.request(id) + HandOverLines.userMessage)
        #expect(
            await h.result(of: job)
                == .failure(.readFailed("a new message came in during the hand-over")))
        #expect(h.starts.isEmpty)
        #expect(h.notes.isEmpty)
    }

    @Test func afterFiveMinutesNothingStarts() async throws {
        #expect(HandOver.limit == .seconds(300))
        let h = try await HandOverHarness()
        defer { h.close() }
        let job = try h.start()
        let id = try #require(await h.typedRequest())
        try h.append(HandOverLines.request(id))
        await h.limitClock.waitForSleepers(1)
        h.limitClock.advance(by: .seconds(299))
        #expect(h.limitClock.sleeperCount == 1)
        h.limitClock.advance(by: .seconds(1))
        #expect(await h.result(of: job) == .failure(.timedOut))
        #expect(h.starts.isEmpty)
        #expect(h.notes.isEmpty)
    }

    // The note is saved before the start, so a failed start keeps it, and the text says where.
    @Test func aFailedStartKeepsTheNoteAndSaysWhere() async throws {
        let h = try await HandOverHarness()
        defer { h.close() }
        h.startAnswer = .failure(.dirMissing)
        let job = try h.start()
        let id = try #require(await h.typedRequest())
        try h.append(HandOverLines.request(id) + HandOverLines.reply("n") + HandOverLines.turnEnd)
        let result = await h.result(of: job)
        let file = HandOverText.noteFileName("bifrost-test-s", at: at, calendar: localCalendar)
        let path = "\(h.notesFolder)/\(file)"
        #expect(result == .failure(.startFailed(notePath: path, ActionRefusal.dirMissing.message)))
        #expect(contents(path) == "n")
        #expect(h.starts.count == 1)
    }

    // The NUL characters go before the mask, so a NUL in a token cannot hide the token. The
    // saved note and the continue prompt have neither.
    @Test func theNoteHasNoTokenAndNoNul() async throws {
        let h = try await HandOverHarness()
        defer { h.close() }
        let job = try h.start()
        let id = try #require(await h.typedRequest())
        let token = "ghp_" + String(repeating: "A1b2", count: 6)
        let split = token.prefix(10) + "\0" + token.dropFirst(10)
        try h.append(
            HandOverLines.request(id) + HandOverLines.reply("Use \(split) for a\0b.")
                + HandOverLines.turnEnd)
        let done = try await h.result(of: job).get()
        #expect(contents(done.notePath) == "Use *** for ab.")
        #expect(h.starts.first?.prompt.hasSuffix("\n\nUse *** for ab.") == true)
    }

    // No rules file, or an empty one: nothing is typed and no note is saved.
    @Test func aMissingRulesFileChangesNothing() async throws {
        for rules in [nil, " \n"] as [String?] {
            let h = try await HandOverHarness(rules: rules)
            defer { h.close() }
            #expect(await h.result(of: try h.start()) == .failure(.noRules))
            #expect(h.typed.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: h.notesFolder))
        }
    }

    @Test func aSessionWithNoTranscriptChangesNothing() async throws {
        let h = try await HandOverHarness()
        defer { h.close() }
        try FileManager.default.removeItem(atPath: h.transcript)
        #expect(await h.result(of: try h.start()) == .failure(.noTranscript))
        #expect(h.typed.isEmpty)
    }

    @Test func theFailuresHaveTheirTexts() {
        let texts: [(HandOverFailure, String)] = [
            (.noRules, "Bifrost can't read its hand-over rules, so nothing changed."),
            (
                .noTranscript,
                "Bifrost can't find the transcript of this session, so nothing changed."
            ),
            (
                .timedOut,
                "The session didn't finish the hand-over note within 5 minutes, so Bifrost "
                    + "didn't start a new session."
            ),
            (.stopped, "The session stopped before it finished the hand-over note."),
            (
                .readFailed("the note is empty"),
                "Bifrost couldn't read the hand-over note, so it didn't start a new session. "
                    + "(the note is empty)"
            ),
            (
                .saveFailed("Cannot save /h/n.md: Permission denied."),
                "Bifrost couldn't save the hand-over note, so it didn't start a new session. "
                    + "Cannot save /h/n.md: Permission denied."
            ),
            (
                .startFailed(notePath: "/h/n.md", "This folder doesn't exist."),
                "The note is saved at /h/n.md, but the new session didn't start. This folder "
                    + "doesn't exist."
            ),
            (.input(.prompt), InputRefusal.prompt.message),
        ]
        for (failure, text) in texts { #expect(failure.message == text) }
    }
}
