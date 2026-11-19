// Hand over (docs/behaviour/actions.md, "Hand over"): Bifrost asks the old session for a
// hand-over note, waits for the end of the turn, reads the note from the transcript, saves the
// note and starts a new session that continues from it. If a step fails, the old session stays
// as it is and no new session starts. A note that is saved stays on disk.
import BifrostFoundation
import Foundation
import Observation

// Why a hand-over did not end with a new session. message is the text for the user.
package enum HandOverFailure: Error, Sendable, Equatable {
    // The rules file is not there, cannot be read or is empty.
    case noRules
    // No transcript of the session, or its size cannot be read.
    case noTranscript
    // No note within HandOver.limit.
    case timedOut
    // The row parked or left the list, the transcript became unreadable, or the wait was
    // cancelled.
    case stopped
    // The reply cannot give a note, with the reason.
    case readFailed(String)
    // The note file cannot be written, with the reason.
    case saveFailed(String)
    // The note is saved at the path, but the new session did not start, with the reason.
    case startFailed(notePath: String, String)
    // The session input did not send the request.
    case input(InputRefusal)

    package var message: String {
        switch self {
        case .noRules: "Bifrost can't read its hand-over rules, so nothing changed."
        case .noTranscript:
            "Bifrost can't find the transcript of this session, so nothing changed."
        case .timedOut:
            "The session didn't finish the hand-over note within 5 minutes, so Bifrost didn't "
                + "start a new session."
        case .stopped: "The session stopped before it finished the hand-over note."
        case .readFailed(let reason):
            "Bifrost couldn't read the hand-over note, so it didn't start a new session. "
                + "(\(reason))"
        case .saveFailed(let reason):
            "Bifrost couldn't save the hand-over note, so it didn't start a new session. \(reason)"
        case .startFailed(let notePath, let reason):
            "The note is saved at \(notePath), but the new session didn't start. \(reason)"
        case .input(let refusal): refusal.message
        }
    }
}

// The result of a good hand-over: the name and the row ID of the new session, the path of the
// note file, and the transcript of the old session with the end of the lines that the wait read.
// The check before the park reads the lines after that end (HandOver.checkPark).
package struct HandOverDone: Sendable, Equatable {
    package var name: String
    package var notePath: String
    package var sessionId: String
    package var transcript: URL
    package var readEnd: Int

    package init(name: String, notePath: String, sessionId: String, transcript: URL, readEnd: Int) {
        self.name = name
        self.notePath = notePath
        self.sessionId = sessionId
        self.transcript = transcript
        self.readEnd = readEnd
    }
}

// Why the old session does not park after a good hand-over. The old session keeps running, or
// it is already gone. message is the text for the user.
package enum ParkRefusal: Error, Sendable, Equatable {
    // The fresh session list did not come, or the registry stopped.
    case unchecked
    // The row is not in the list any more.
    case gone
    // The row is parked already.
    case parked
    // The row is not a session that Bifrost started.
    case notOwned
    // The row has a red box of a prompt.
    case prompt
    // The row is not idle.
    case busy
    // The transcript has a new message or a new reply after the note.
    case newMessage
    // The transcript cannot be read.
    case unread

    package var message: String {
        let started = "The new session started, but"
        return switch self {
        case .unchecked: "\(started) Bifrost couldn't check the old one, so it left it running."
        case .gone: "\(started) the old one isn't in the list any more, so Bifrost didn't park it."
        case .parked: "\(started) the old one has already stopped, so Bifrost didn't park it."
        case .notOwned:
            "\(started) the old one now runs in another terminal, so Bifrost left it running."
        case .prompt: "\(started) the old one is waiting on a prompt, so Bifrost left it running."
        case .busy: "\(started) the old one is busy again, so Bifrost left it running."
        case .newMessage: "\(started) the old one has a new message, so Bifrost left it running."
        case .unread:
            "\(started) Bifrost couldn't read the old one's transcript, so it left it running."
        }
    }
}

// The shell makes the hand-over after it makes the session input, and the action runner runs it
// while the session counts as running, so no other action runs on the session during the wait.
//
// The wait for the note follows two kinds of event: each change of the row of the session in
// the registry (Observations) and each change event of the transcript file
// (TranscriptReader.changes). At each event, the wait reads the full lines after the baseline.
// It ends when the reply has the note and the row is idle. A short turn can show no working
// state in the samples of the registry, so the event of the file is what wakes the wait then.
// The time limit runs on the injected clock, and it is a fail-safe only.
@MainActor
package final class HandOver {
    // The time limit of the wait for the note.
    package static let limit = Duration.seconds(300)
    // The reason of a continue prompt that is too long for a new session.
    package static let noteTooLong = "The note is too long to start a new session with it."

    private let input: SessionInput
    private let registry: RegistryService
    private let projects: URL
    private let notes: URL
    private let rules: URL
    private let timeline: Timeline
    private let now: () -> Date
    #if DEBUG
    // The reply of the last read of the wait. A test waits for it.
    package private(set) var lastReply: HandOverReply?
    #endif

    // projects: the projects folder of Claude Code, which the hand-over only reads. notes: the
    // folder of the note files. rules: the rules file of the bifrost-hand-over skill. now gives
    // the time in the name of the note file.
    package init(
        input: SessionInput, registry: RegistryService, projects: URL, notes: URL, rules: URL,
        clock: any Clock<Duration>, now: @escaping () -> Date
    ) {
        self.input = input
        self.registry = registry
        self.projects = projects
        self.notes = notes
        self.rules = rules
        timeline = Timeline(clock)
        self.now = now
    }

    // Hand the work of the row over to a new session. start is the New session of the runner,
    // which gives the row ID of the new session. The steps:
    // 1. The rules and the transcript with its size are read before the send, so an older note
    //    in the transcript never counts.
    // 2. The request prompt goes through the session input.
    // 3. The wait for the note.
    // 4. The NUL characters of the note go, then the token mask hides each secret. The note is
    //    saved before the start, so a failed start keeps it.
    // 5. The new session starts in the old folder with the next free name, the model of the
    //    reply (else of the usage line of the row), the mode of the request
    //    (RequestMode.newSessionMode) and the continue prompt. Then it takes the priority and the
    //    watchlist place of the old session.
    package func run(
        _ row: SessionRow, start: (NewSessionSpec) async throws(ActionRefusal) -> String
    ) async throws(HandOverFailure) -> HandOverDone {
        guard let rulesText = await Self.read(rules), !rulesText.trimmed().isEmpty else {
            throw .noRules
        }
        guard let file = await TranscriptReader.transcript(of: row, projects: projects),
            let baseline = await TranscriptReader.size(of: file)
        else { throw .noTranscript }
        let requestID = String(UUID().uuidString.lowercased().prefix(8))
        do throws(InputRefusal) {
            try await input.send(
                row.sessionId, HandOverText.prompt(rules: rulesText, requestID: requestID))
        } catch {
            throw .input(error)
        }
        let reply = try await waitForNote(
            row.sessionId, file: file, baseline: baseline, requestID: requestID)
        // A command argument cannot hold a NUL. The NUL characters go before the mask, so a NUL
        // inside a token cannot hide the token from the mask.
        let scalars = reply.note.unicodeScalars.filter { $0 != "\0" }
        let note = TokenMask.mask(String(String.UnicodeScalarView(scalars)), token: nil)
        let notePath: String
        do throws(NoteFileError) {
            let name = HandOverText.noteFileName(row.name, at: now(), calendar: Self.calendar)
            notePath = try await NoteFile.write(note, named: name, in: notes)
                .path(percentEncoded: false)
        } catch {
            throw .saveFailed(error.message)
        }
        let rows = registry.rows
        let current = rows.first { $0.sessionId == row.sessionId } ?? row
        let taken = Set(rows.flatMap { [$0.name, $0.claudeName] })
        let name = HandOverText.newName(row.name, taken: taken)
        let model =
            reply.model.flatMap(ModelChoice.init(modelID:))
            ?? current.usage?.model.flatMap(ModelChoice.init(modelID:)) ?? .standard
        let mode = reply.mode.newSessionMode(row: current.usage?.permissionMode)
        let checked = NewSessionSpec.check(
            cwd: row.cwd, name: name, model: model, permissionMode: mode,
            prompt: HandOverText.continuePrompt(note: note, notePath: notePath), worktree: false)
        let spec: NewSessionSpec
        switch checked {
        case .success(let value): spec = value
        case .failure(.promptTooLong): throw .startFailed(notePath: notePath, Self.noteTooLong)
        case .failure(let refusal): throw .startFailed(notePath: notePath, refusal.message)
        }
        let sessionId: String
        do throws(ActionRefusal) {
            sessionId = try await start(spec)
        } catch {
            throw .startFailed(notePath: notePath, error.message)
        }
        _ = registry.carryOver(from: row.sessionId, to: sessionId)
        return HandOverDone(
            name: name, notePath: notePath, sessionId: sessionId, transcript: file,
            readEnd: reply.end)
    }

    // Confirm the real state of the old session just before the park, because the start of the
    // new session can take some seconds. The registry polls the active list now. Then the row
    // must still be an owned session that is not parked, has no red box of a prompt and is idle,
    // and a new read of its transcript must show no new message and no new reply after the lines
    // that the wait read. Each failed check throws its reason, and then the caller must not park.
    package func checkPark(_ sessionId: String, after done: HandOverDone)
        async throws(ParkRefusal)
    {
        guard case .applied = await registry.checkActive() else { throw .unchecked }
        guard let row = registry.rows.first(where: { $0.sessionId == sessionId }) else {
            throw .gone
        }
        if row.state == .parked { throw .parked }
        if row.kind != .owned { throw .notOwned }
        if row.alert.blocksPrompt { throw .prompt }
        if row.status != .idle || row.state == .working { throw .busy }
        let tail: TranscriptTail
        do throws(TailFailure) {
            tail = try await TranscriptReader.tail(of: done.transcript, after: done.readEnd)
        } catch {
            throw .unread
        }
        if HandOverReply.startsNewTurn(tail.text) { throw .newMessage }
    }

    // MARK: - The wait

    // The parts of a reply that is done, and the end of the lines that the wait read.
    private struct Note {
        var note: String
        var model: String?
        var mode: HandOverReply.RequestMode
        var end: Int
    }

    // Wait for the note of the reply to the request. Three tasks wake the wait: a change of the
    // row, a change event of the file, and the end of the time limit. Wakes that come during a
    // read become one wake. The wait ends at the first check that gives a result, and then each
    // task of the wait ends. A cancel of the caller ends the wait as stopped.
    private func waitForNote(
        _ sessionId: String, file: URL, baseline: Int, requestID: String
    ) async throws(HandOverFailure) -> Note {
        let deadline = timeline.now() + Self.limit
        let (wakes, wake) = AsyncStream.makeStream(
            of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let registry = self.registry
        let rowChanges = Observations { registry.rows.first { $0.sessionId == sessionId } }
        let fileChanges = TranscriptReader.changes(of: file)
        let timeline = self.timeline
        let result = await withTaskGroup(of: Void.self) { group -> Result<Note, HandOverFailure> in
            // Each change of the row of the session. A change of another row is no wake.
            group.addTask {
                var last: SessionRow??
                for await row in rowChanges where last != .some(row) {
                    last = row
                    wake.yield()
                }
            }
            group.addTask {
                for await _ in fileChanges { wake.yield() }
            }
            group.addTask {
                do {
                    try await timeline.sleep(until: deadline)
                    wake.yield()
                } catch {
                    // The wait ended first.
                }
            }
            defer { group.cancelAll() }
            for await _ in wakes {
                if let result = await check(
                    sessionId, file: file, baseline: baseline, requestID: requestID,
                    deadline: deadline)
                {
                    return result
                }
            }
            return .failure(.stopped)
        }
        return try result.get()
    }

    // One check of the wait: nil when the wait goes on. A parked or missing row is stopped. A
    // file error of the read means that the session stopped for Bifrost, and the text of the
    // error holds the transcript path, so the user does not see it.
    private func check(
        _ sessionId: String, file: URL, baseline: Int, requestID: String, deadline: Duration
    ) async -> Result<Note, HandOverFailure>? {
        guard let row = registry.rows.first(where: { $0.sessionId == sessionId }),
            row.state != .parked
        else { return .failure(.stopped) }
        let tail: TranscriptTail
        do throws(TailFailure) {
            tail = try await TranscriptReader.tail(of: file, after: baseline)
        } catch .file {
            return .failure(.stopped)
        } catch {
            return .failure(.readFailed(error.reason))
        }
        let reply = HandOverReply.read(tail.text, requestID: requestID)
        #if DEBUG
        lastReply = reply
        #endif
        switch reply {
        case .failed(let reason):
            return .failure(.readFailed(reason))
        case .done(let note, let model, let mode)
        where registry.rows.first(where: { $0.sessionId == sessionId })?.status == .idle:
            return .success(Note(note: note, model: model, mode: mode, end: tail.end))
        case .done, .waiting:
            break
        }
        return timeline.now() >= deadline ? .failure(.timedOut) : nil
    }

    // MARK: - Helpers

    // The calendar of the time in the name of the note file: Gregorian, in the time zone of the
    // Mac.
    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        return calendar
    }

    // The text of the file, or nil when the read fails. The read runs off the actor of the
    // caller.
    @concurrent private static func read(_ file: URL) async -> String? {
        try? String(contentsOf: file, encoding: .utf8)
    }
}
