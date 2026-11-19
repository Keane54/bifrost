// The dictation service with the fake speech engine and a manual clock. No test makes the real
// engine, opens the microphone, asks for a permission or downloads a speech model. A test gives
// the steps of the engine with the controls of the fake engine, and reads the events that each
// chat got from its listen stream.
import AVFoundation
import BifrostFoundation
import BifrostTestSupport
import Foundation
import Synchronization
import Testing

@testable import BifrostDictation

private let A: SessionID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
private let B: SessionID = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
private let final = FakeSpeechScript.helperText
private let ready = DictationViewEvent.ready(language: "en-US", fallback: false)
// The events of a dictation of the fake helper, before its end.
private let helperEvents: [DictationViewEvent] = [
    ready, .level(0.4), .text(final: "", volatile: "Hello from"), .level(0.7),
    .text(final: final, volatile: ""),
]

// A dictation log that records each event.
private final class DictationLogRecorder: DictationLog {
    private let recorded = Mutex<[DictationLogEvent]>([])

    var events: [DictationLogEvent] { recorded.withLock { $0 } }

    func record(_ event: DictationLogEvent) { recorded.withLock { $0.append(event) } }
}

// The service, its fake engine, its clock, and the events that the chats A and B got.
@MainActor
private final class ServiceFixture {
    let engine: FakeSpeechEngine
    let clock = ManualClock()
    let service: DictationService
    private let log = DictationLogRecorder()
    var logs: [DictationLogEvent] { log.events }
    private var got: [SessionID: [DictationViewEvent]] = [:]
    private var readers: [SessionID: Task<Void, Never>] = [:]

    init(_ script: FakeSpeechScript = .helper) {
        engine = FakeSpeechEngine(script: script)
        service = DictationService(engine: engine, clock: clock, log: log)
        listen(A)
        listen(B)
    }

    isolated deinit {
        readers[A]?.cancel()
        readers[B]?.cancel()
    }

    // Read the events of the chat from a new listen. The result is the reader of the last listen.
    @discardableResult
    func listen(_ view: SessionID) -> Task<Void, Never>? {
        let events = service.listen(for: view)
        let last = readers[view]
        readers[view] = Task { [weak self] in
            for await event in events { self?.got[view, default: []].append(event) }
        }
        return last
    }

    func of(_ view: SessionID) -> [DictationViewEvent] { got[view] ?? [] }

    // True when the microphone of the fake engine is closed after each open.
    var closed: Bool { !engine.microphoneOpen && engine.microphoneOpens == engine.microphoneCloses }

    // Start a dictation of the chat, and wait for the events of the fake helper.
    func dictate(_ view: SessionID) async throws {
        let before = of(view).count
        service.start(chat: view)
        try #require(await waitUntil { self.of(view).count >= before + helperEvents.count })
        #expect(Array(of(view).dropFirst(before)) == helperEvents)
    }

    // Stop the dictation of the chat, and wait for its end.
    func release(_ view: SessionID) async -> Bool {
        service.stop(chat: view)
        return await ended(view)
    }

    // Wait until each timer of the service that runs sleeps on the clock. A timer whose time
    // came acts on the main actor first.
    func timersSettled(sourceLocation: SourceLocation = #_sourceLocation) async {
        await waitUntil(every: .milliseconds(1), sourceLocation: sourceLocation) {
            self.service.runningTimers == self.clock.sleeperCount
        }
    }

    // Wait until the reader of the chat has each event that the service gave it until now,
    // after the work of the sessions that runs. A new listen ends the stream of the last listen
    // after its events, and the reader of that listen then ends.
    func drained(_ view: SessionID) async {
        await service.sessionWork?.value
        await listen(view)?.value
    }

    // Wait until the chat got the end with the final text and the microphone is closed. The
    // session closes the microphone before the chat gets the end, so a wait for the close alone
    // can count the events of the chat before its end came.
    func ended(_ view: SessionID) async -> Bool {
        await waitUntil { self.closed && self.of(view).last == .end(final: final) }
    }
}

@Suite("dictation service", .timeLimit(.minutes(1)))
@MainActor
struct DictationServiceTests {
    // A warm call boots the engine one time: the download step, then the load. It opens no
    // microphone. A start begins a session, the chat gets its events, and a stop gives the end
    // with the final text.
    @Test func theServiceRunsTheEngine() async throws {
        let t = ServiceFixture()
        t.service.warm()
        t.service.warm()
        await waitUntil { t.engine.prepares == 1 }
        #expect(t.engine.downloads == 1)
        #expect(t.engine.microphoneOpens == 0)
        try await t.dictate(A)
        #expect(t.engine.microphoneOpen)
        t.service.stop(chat: A)
        await waitUntil { t.of(A).last == .end(final: final) }
        #expect(t.of(A) == helperEvents + [.end(final: final)])
        #expect(t.closed)
        #expect(t.engine.downloads == 1)
        #expect(t.engine.microphoneOpens == 1)
        #expect(t.engine.overlaps == 0)
        #expect(t.of(B).isEmpty)
    }

    // The ends of the service: a release (stop), a start of another chat, the
    // 2-minute limit, an engine error and stopAll (a window close and a quit). After each one,
    // the microphone is closed. The ends in the chat windows are tests of BifrostChat
    // (DictationTests.everyEndPathClosesTheMicrophone).
    @Test func eachEndOfTheServiceClosesTheMicrophone() async throws {
        let t = ServiceFixture()
        // A release.
        try await t.dictate(A)
        #expect(await t.release(A))
        // A start of another chat ends the first session before the next begin.
        try await t.dictate(A)
        try await t.dictate(B)
        #expect(t.engine.microphoneOpens == t.engine.microphoneCloses + 1)
        await waitUntil { t.of(A).last == .end(final: final) }
        #expect(await t.release(B))
        // The 2-minute limit.
        try await t.dictate(A)
        let opens = t.engine.microphoneOpens
        t.clock.advance(by: DictationService.holdLimit)
        await waitUntil { t.closed }
        #expect(t.engine.microphoneOpens == opens)
        await waitUntil { t.of(A).last == .end(final: final) }
        // An engine error: the session closes the microphone by itself, and the chat gets the
        // error.
        try await t.dictate(A)
        t.engine.failSession(.failed)
        await waitUntil { t.of(A).last == .error(.failed) }
        #expect(t.closed)
        // stopAll: the session and the engine go at once.
        try await t.dictate(A)
        t.service.stopAll()
        #expect(t.closed)
        #expect(t.engine.releases == 1)
        #expect(t.engine.microphoneOpens == 5 + 1)
        #expect(t.engine.overlaps == 0)
    }

    // One dictation at a time, and its events go only to the chat that started it. A second
    // start of the same chat and a stop of another chat do nothing. After the stop, the level
    // and the text events go to no chat, and the chat gets one end.
    @Test func onlyTheChatThatStartedGetsTheEvents() async throws {
        let t = ServiceFixture()
        try await t.dictate(A)
        t.service.start(chat: A)
        t.service.stop(chat: B)
        t.engine.emit(.level(0.5))
        await waitUntil { t.of(A).last == .level(0.5) }
        #expect(t.engine.microphoneOpens == 1)
        t.service.stop(chat: A)
        t.engine.emit(.level(0.2))
        t.engine.emit(.text(final: "late", volatile: ""))
        await waitUntil { t.of(A).last == .end(final: final) }
        #expect(t.of(A) == helperEvents + [.level(0.5), .end(final: final)])
        #expect(t.of(B).isEmpty)
        t.service.stop(chat: A)
        await t.drained(A)
        #expect(t.of(A).count == helperEvents.count + 2)
    }

    // A new start of the same chat before the end of its stopped dictation drops that end. The
    // new session begins after the end of the old one.
    @Test func aNewStartOfTheSameChatDropsTheOldEnd() async throws {
        let t = ServiceFixture()
        try await t.dictate(A)
        t.service.stop(chat: A)
        try await t.dictate(A)
        #expect(t.of(A) == helperEvents + helperEvents)
        #expect(t.engine.microphoneOpens == 2)
        #expect(t.engine.overlaps == 0)
    }

    // A start during the boot waits for the ready, and then begins.
    @Test func aStartDuringTheBootBeginsAtTheReady() async throws {
        var script = FakeSpeechScript.helper
        script.holdsPrepare = true
        let t = ServiceFixture(script)
        t.service.start(chat: A)
        await waitUntil { t.engine.waiting(.prepare) == 1 }
        #expect(t.engine.microphoneOpens == 0)
        #expect(t.of(A).isEmpty)
        t.engine.resume(.prepare)
        await waitUntil { t.of(A) == helperEvents }
    }

    // A hold that ends before the ready begins no session, so the microphone never opens. The
    // chat gets its end at once. A failure of that boot later gives it nothing more.
    @Test(arguments: [true, false])
    func aHoldReleasedBeforeTheReadyNeverBegins(bootWorks: Bool) async throws {
        var script = FakeSpeechScript.helper
        script.holdsPrepare = true
        if !bootWorks { script.ready = .failure(.code(.noModel)) }
        let t = ServiceFixture(script)
        t.service.start(chat: A)
        await waitUntil { t.engine.waiting(.prepare) == 1 }
        t.service.stop(chat: A)
        await waitUntil { t.of(A) == [.end(final: "")] }
        t.engine.resume(.prepare)
        await waitUntil { bootWorks ? t.service.isReady : t.engine.releases == 1 }
        await t.drained(A)
        #expect(t.of(A) == [.end(final: "")])
        #expect(t.engine.microphoneOpens == 0)
        #expect(t.engine.releases == (bootWorks ? 0 : 1))
    }

    // A stop before the begin of the session runs opens no microphone. The chat gets ready and
    // an empty end.
    @Test func aStopBeforeTheBeginOpensNoMicrophone() async throws {
        let t = ServiceFixture()
        try await t.dictate(A)
        t.service.stop(chat: A)
        await waitUntil { t.closed }
        t.service.start(chat: B)
        t.service.stop(chat: B)
        await waitUntil { t.of(B) == [ready, .end(final: "")] }
        #expect(t.engine.microphoneOpens == 1)
        #expect(t.closed)
    }

    // The microphone answer comes first. With no answer, the engine asks one time and the chat
    // gets mic-asked at once. A no gives mic-denied. The microphone never opens, and the engine
    // stays.
    @Test(arguments: [
        (SpeechPermission.undetermined, DictationErrorCode.micAsked), (.denied, .micDenied),
    ])
    func aMicrophoneWithNoYesNeverOpens(permission: SpeechPermission, code: DictationErrorCode)
        async throws
    {
        var script = FakeSpeechScript.helper
        script.permission = permission
        let t = ServiceFixture(script)
        t.service.start(chat: A)
        await waitUntil { t.of(A) == [ready, .error(code)] }
        #expect(t.engine.microphoneOpens == 0)
        #expect(t.engine.asks == (permission == .undetermined ? 1 : 0))
        t.service.stop(chat: A)
        await t.drained(A)
        #expect(t.of(A) == [ready, .error(code)])
        #expect(t.engine.releases == 0)
    }

    // A failed begin gives its code, and the microphone stays closed.
    @Test func aFailedBeginGivesItsCode() async throws {
        var script = FakeSpeechScript.helper
        script.beginError = .code(.failed)
        let t = ServiceFixture(script)
        t.service.start(chat: A)
        await waitUntil { t.of(A) == [ready, .error(.failed)] }
        #expect(t.engine.microphoneOpens == 0)
    }

    // A failure of the session ends the dictation with the error in place of the end. After it,
    // the chat gets no more events of that dictation, and a stop does nothing. The engine stays,
    // and the next start dictates.
    @Test func aFailedSessionEndsTheDictation() async throws {
        let t = ServiceFixture()
        try await t.dictate(A)
        t.engine.failSession(.failed)
        await waitUntil { t.of(A).last == .error(.failed) }
        t.engine.emit(.level(0.5))
        t.service.stop(chat: A)
        await t.drained(A)
        #expect(t.of(A) == helperEvents + [.error(.failed)])
        #expect(t.engine.releases == 0)
        #expect(t.closed)
        try await t.dictate(A)
        #expect(t.engine.downloads == 1)
    }

    // The 2-minute limit stops a dictation, and the chat gets its end. A later stop does
    // nothing.
    @Test func aDictationStopsAfterTwoMinutes() async throws {
        let t = ServiceFixture()
        try await t.dictate(A)
        t.clock.advance(by: DictationService.holdLimit - .milliseconds(1))
        await t.timersSettled()
        #expect(t.engine.microphoneOpen)
        t.clock.advance(by: .milliseconds(1))
        await waitUntil { t.of(A).last == .end(final: final) }
        #expect(t.closed)
        t.service.stop(chat: A)
        await t.drained(A)
        #expect(t.of(A) == helperEvents + [.end(final: final)])
    }

    // A start during a model download opens no microphone. The chat gets the progress and
    // model-ready. A new hold after the ready opens the microphone.
    @Test func aStartDuringADownloadOpensNoMicrophone() async throws {
        var script = FakeSpeechScript.helper
        script.download = [0, 0.5, 1]
        let t = ServiceFixture(script)
        t.service.start(chat: A)
        await waitUntil { t.of(A).last == .modelReady }
        let download: [DictationViewEvent] = [
            .downloading(progress: 0), .downloading(progress: 0.5), .downloading(progress: 1),
            .modelReady,
        ]
        #expect(t.of(A) == download)
        #expect(t.engine.microphoneOpens == 0)
        t.service.stop(chat: A)
        await waitUntil { t.of(A).last == .end(final: "") }
        try await t.dictate(A)
        #expect(t.of(A) == download + [.end(final: "")] + helperEvents)
    }

    // Only the chat that dictates gets the progress and model-ready. A stopped dictation gets
    // its end and no model-ready. A start during a download gets the last progress at once.
    @Test func onlyTheChatThatDictatesGetsModelReady() async throws {
        var script = FakeSpeechScript.helper
        script.download = [0.2]
        script.holdsDownload = true
        let t = ServiceFixture(script)
        t.service.start(chat: A)
        await waitUntil { t.of(A) == [.downloading(progress: 0.2)] }
        t.service.stop(chat: A)
        t.service.start(chat: B)
        await waitUntil { t.of(B) == [.downloading(progress: 0.2)] }
        t.engine.progress(0.3)
        await waitUntil { t.of(B).last == .downloading(progress: 0.3) }
        t.engine.finishDownload()
        await waitUntil { t.of(B).last == .modelReady }
        #expect(t.of(A) == [.downloading(progress: 0.2), .end(final: "")])
        #expect(
            t.of(B) == [.downloading(progress: 0.2), .downloading(progress: 0.3), .modelReady])
        #expect(t.engine.microphoneOpens == 0)
    }

    // A boot that fails gives its code and one log line, and the engine goes. Then a warm boots
    // nothing, so each focus of a chat does not start a new model download. Only a start boots
    // the engine again.
    @Test(arguments: [DictationErrorCode.noModel, .unavailable])
    func aBootFailureGivesItsCode(code: DictationErrorCode) async throws {
        var script = FakeSpeechScript.helper
        script.ready = .failure(.code(code))
        let t = ServiceFixture(script)
        t.service.start(chat: A)
        await waitUntil { t.of(A) == [.error(code)] }
        #expect(t.logs == [.bootFailed(code)])
        #expect(t.engine.releases == 1)
        t.service.warm()
        #expect(t.engine.downloads == 1)
        t.engine.script.ready = .success(SpeechReady(language: "en-US", fallback: false))
        try await t.dictate(A)
        #expect(t.engine.downloads == 2)
    }

    // The engine fails when its boot gives no ready in the limit. A model download has no
    // limit: its progress changes only when data comes. The limit starts again at the end of the
    // download. After the failure, a warm boots the engine again.
    @Test func aBootWithNoReadyInTheLimitFails() async throws {
        var script = FakeSpeechScript.helper
        script.download = []
        script.holdsDownload = true
        script.holdsPrepare = true
        let t = ServiceFixture(script)
        t.service.start(chat: A)
        await waitUntil { t.engine.downloads == 1 }
        t.clock.advance(by: DictationService.engineLimit - .milliseconds(1))
        t.engine.progress(0)
        await waitUntil { t.of(A).last == .downloading(progress: 0) }
        // A minute with no change of the progress: the download goes on.
        t.clock.advance(by: .seconds(60))
        await t.timersSettled()
        await t.drained(A)
        #expect(t.of(A).last == .downloading(progress: 0))
        #expect(t.engine.releases == 0)
        t.engine.finishDownload()
        await waitUntil { t.engine.waiting(.prepare) == 1 }
        t.clock.advance(by: DictationService.engineLimit - .milliseconds(1))
        await t.timersSettled()
        await t.drained(A)
        #expect(t.of(A).last == .downloading(progress: 0))
        t.clock.advance(by: .milliseconds(1))
        await waitUntil { t.of(A).last == .error(.failed) }
        #expect(t.engine.releases == 1)
        #expect(t.logs == [.noReady])
        t.engine.resume(.prepare)
        t.service.warm()
        await waitUntil { t.engine.downloads == 2 }
    }

    // The engine is one object for all the boots of the service, as the real engine is. A slow
    // load of an old boot that ends after a new boot listens does nothing: a release would close
    // the session of the new boot.
    @Test func aLateLoadOfAnOldBootLeavesTheNewBootAlone() async throws {
        var script = FakeSpeechScript.helper
        script.holdsPrepare = true
        let t = ServiceFixture(script)
        t.service.start(chat: A)
        await waitUntil { t.engine.waiting(.prepare) == 1 }
        t.clock.advance(by: DictationService.engineLimit)
        await waitUntil { t.of(A) == [.error(.failed)] }
        #expect(t.engine.releases == 1)
        t.engine.script.holdsPrepare = false
        try await t.dictate(A)
        t.engine.resume(.prepare)
        await waitUntil { t.engine.waiting(.prepare) == 0 }
        await waitUntil { t.engine.preparesDone == 2 }
        #expect(t.engine.microphoneOpen)
        #expect(t.engine.releases == 1)
        #expect(await t.release(A))
        #expect(t.engine.overlaps == 0)
    }

    // A begin that gives no session in the limit fails the engine: the chat gets failed and the
    // log gets one line. The late begin fails, because a release came, and the next start boots
    // the engine again.
    @Test func aBeginWithNoSessionInTheLimitFails() async throws {
        var script = FakeSpeechScript.helper
        script.holdsBegin = true
        let t = ServiceFixture(script)
        t.service.start(chat: A)
        await waitUntil { t.engine.waiting(.begin) == 1 && t.of(A) == [ready] }
        t.clock.advance(by: DictationService.engineLimit - .milliseconds(1))
        await t.timersSettled()
        #expect(t.engine.releases == 0)
        t.clock.advance(by: .milliseconds(1))
        await waitUntil { t.of(A) == [ready, .error(.failed)] }
        #expect(t.engine.releases == 1)
        #expect(t.logs == [.noSession])
        t.engine.resume(.begin)
        await waitUntil { t.engine.beginsDone == 1 }
        #expect(t.engine.microphoneOpens == 0)
        t.engine.script.holdsBegin = false
        try await t.dictate(A)
        #expect(t.engine.downloads == 2)
        #expect(t.engine.overlaps == 0)
        #expect(t.of(A) == [ready, .error(.failed)] + helperEvents)
    }

    // A begin that hangs and ignores the cancel of its load fails at the engine limit, and the
    // engine goes. The next boot does not wait for that begin: its own begin opens the
    // microphone. The old begin that ends late opens no microphone.
    @Test func aBeginThatHangsDoesNotBlockTheNextBoot() async throws {
        var script = FakeSpeechScript.helper
        script.holdsBegin = true
        let t = ServiceFixture(script)
        t.service.start(chat: A)
        await waitUntil { t.engine.waiting(.begin) == 1 }
        t.clock.advance(by: DictationService.engineLimit)
        await waitUntil { t.of(A) == [ready, .error(.failed)] }
        t.engine.script.holdsBegin = false
        t.service.start(chat: A)
        let began = await waitUntil(within: .seconds(5)) { t.engine.microphoneOpen }
        #expect(began)
        t.engine.resume(.begin)
        await waitUntil { t.engine.beginsDone == 2 }
        #expect(t.engine.microphoneOpen)
        #expect(t.engine.microphoneOpens == 1)
        #expect(t.engine.overlaps == 0)
        t.service.stop(chat: A)
        await waitUntil { t.closed }
    }

    // The idle rule releases the engine 5 minutes after the last warm call or start. A warm
    // starts the 5 minutes again, and the next warm boots the engine again. The first dictation
    // shows that the engine is ready before the clock moves.
    @Test func theIdleRuleReleasesTheEngine() async throws {
        let t = ServiceFixture()
        try await t.dictate(A)
        t.service.stop(chat: A)
        await waitUntil { t.of(A).last == .end(final: final) }
        t.clock.advance(by: DictationService.idleLimit - .seconds(1))
        t.service.warm()
        t.clock.advance(by: DictationService.idleLimit - .seconds(1))
        await t.timersSettled()
        #expect(t.engine.releases == 0)
        t.clock.advance(by: .seconds(1))
        await waitUntil { t.engine.releases == 1 }
        t.service.warm()
        await waitUntil { t.engine.downloads == 2 }
    }

    // A model download whose progress does not change for 2 minutes ends the engine with the
    // error no-model. A new value starts the 2 minutes again, and the same value does not. Then
    // a warm starts no new download, and the next start does.
    @Test func aDownloadWithNoProgressFor2MinutesFails() async throws {
        var script = FakeSpeechScript.helper
        script.download = [0]
        script.holdsDownload = true
        let t = ServiceFixture(script)
        t.service.start(chat: A)
        await waitUntil { t.of(A) == [.downloading(progress: 0)] }
        t.service.stop(chat: A)
        // A new value at 60 s: the limit ends at 180 s.
        t.clock.advance(by: .seconds(60))
        t.engine.progress(0.4)
        await waitUntil { t.service.downloadProgress == 0.4 }
        // A hold at 170 s gets the last value, and the same value again does not move the limit.
        t.clock.advance(by: .seconds(110))
        t.service.start(chat: A)
        await waitUntil { t.of(A).last == .downloading(progress: 0.4) }
        let before = t.of(A).count
        t.engine.progress(0.4)
        await waitUntil { t.of(A).count == before + 1 }
        t.clock.advance(by: .seconds(10) - .milliseconds(1))
        await t.timersSettled()
        #expect(t.engine.releases == 0)
        t.clock.advance(by: .milliseconds(1))
        await waitUntil { t.of(A).last == .error(.noModel) }
        #expect(t.engine.releases == 1)
        #expect(t.logs == [.downloadStalled])
        t.service.warm()
        // A boot starts in the turn of the warm.
        #expect(!t.service.isBooted)
        #expect(t.engine.downloads == 1)
        t.service.start(chat: A)
        await waitUntil { t.engine.downloads == 2 }
        #expect(DictationService.downloadStall == .seconds(120))
    }

    // The idle rule never releases the engine during a model download. The first progress of
    // the chat shows that the service reads the download before the clock moves.
    @Test func theIdleRuleWaitsForADownload() async throws {
        var script = FakeSpeechScript.helper
        script.download = [0]
        script.holdsDownload = true
        let t = ServiceFixture(script)
        t.service.start(chat: A)
        await waitUntil { t.of(A) == [.downloading(progress: 0)] }
        t.service.stop(chat: A)
        // Six minutes of download, with a progress each 9 seconds. The service reads each
        // progress before the clock moves again, and each timer acts at its time.
        for step in 1...40 {
            t.clock.advance(by: .seconds(9))
            await t.timersSettled()
            t.engine.progress(Double(step) / 40)
            await waitUntil { t.service.downloadProgress == Double(step) / 40 }
        }
        #expect(t.engine.releases == 0)
        // A start during the download gets the last progress, and model-ready at the ready.
        t.service.start(chat: A)
        t.engine.finishDownload()
        await waitUntil { t.of(A).last == .modelReady }
        t.service.stop(chat: A)
        let events: [DictationViewEvent] = [
            .downloading(progress: 0), .end(final: ""), .downloading(progress: 1), .modelReady,
            .end(final: ""),
        ]
        await waitUntil { t.of(A) == events }
        t.clock.advance(by: DictationService.idleLimit)
        await waitUntil { t.engine.releases == 1 }
    }

    // A new listen for a chat ends the stream of the last listen for it. The new listen gets
    // the events, and the listens of other chats keep theirs.
    @Test func aNewListenForAChatEndsTheLastOne() async throws {
        let t = ServiceFixture()
        let first = t.listen(A)
        await first?.value
        try await t.dictate(A)
        #expect(t.of(A) == helperEvents)
        try await t.dictate(B)
        #expect(t.of(A).last == .end(final: final))
    }

    // A stop and stopAll with no engine do nothing.
    @Test func callsWithNoEngineDoNothing() async throws {
        let t = ServiceFixture()
        t.service.stopAll()
        t.service.stop(chat: A)
        #expect(t.engine.downloads == 0)
        #expect(t.engine.releases == 0)
        #expect(t.of(A).isEmpty)
    }

    // The limits of the service, and the end limit of the real engine.
    @Test func theLimits() {
        #expect(DictationService.idleLimit == .seconds(300))
        #expect(DictationService.holdLimit == .seconds(120))
        #expect(DictationService.engineLimit == .seconds(10))
        #expect(AnalyzerEngine.endLimit == .milliseconds(1500))
    }
}

// The level meter of the real engine, on buffers that the test makes. No audio device is used.
@Suite("level meter", .timeLimit(.minutes(1)))
struct LevelMeterTests {
    // A buffer of one channel at 48 kHz, with each sample at the amplitude.
    private func buffer(frames: Int, amplitude: Float) throws -> AVAudioPCMBuffer {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        let samples = try #require(buffer.floatChannelData?[0])
        for index in 0..<frames { samples[index] = amplitude }
        return buffer
    }

    // One level for each 1/30 s: 1,600 frames at 48 kHz. -55 dB gives 0 and -10 dB gives 1.
    @Test func theMeterGivesOneLevelForEach30thOfASecond() throws {
        var meter = LevelMeter(sampleRate: 48_000)
        let levels = meter.feed(try buffer(frames: 4_800, amplitude: 0.1))
        #expect(levels.count == 3)
        // 0.1 is -20 dB: (55 - 20) / 45.
        for level in levels { #expect(abs(level - 35.0 / 45) < 1e-5) }
        // A part of a chunk waits for the next buffer.
        #expect(meter.feed(try buffer(frames: 800, amplitude: 0)).isEmpty)
        #expect(meter.feed(try buffer(frames: 800, amplitude: 0)) == [0])
        #expect(LevelMeter.level(rms: 1) == 1)
        #expect(LevelMeter.level(rms: 0) == 0)
    }

    // A chunk can start in one buffer and end in a later one. Each split of the same audio gives
    // the same levels: the root mean square of the samples of each chunk.
    @Test func eachSplitOfTheAudioGivesTheSameLevels() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let audio = (0..<8_000).map { Float(sin(Double($0) / 40)) * Float($0) / 20_000 }
        var expected: [Double] = []
        for start in stride(from: 0, to: audio.count, by: 1_600) {
            let squares = audio[start..<(start + 1_600)].reduce(Float(0)) { $0 + $1 * $1 }
            expected.append(LevelMeter.level(rms: (squares / 1_600).squareRoot()))
        }
        for split in [1, 333, 1_600, 1_601, 8_000] {
            var meter = LevelMeter(sampleRate: 48_000)
            var levels: [Double] = []
            for start in stride(from: 0, to: audio.count, by: split) {
                let part = audio[start..<min(audio.count, start + split)]
                let buffer = try #require(
                    AVAudioPCMBuffer(
                        pcmFormat: format, frameCapacity: AVAudioFrameCount(part.count)))
                buffer.frameLength = AVAudioFrameCount(part.count)
                let samples = try #require(buffer.floatChannelData?[0])
                for (index, value) in part.enumerated() { samples[index] = value }
                levels += meter.feed(buffer)
            }
            #expect(levels.count == expected.count, "split \(split)")
            for (level, want) in zip(levels, expected) {
                #expect(abs(level - want) < 1e-4, "split \(split)")
            }
        }
    }
}

// The progress of a model download of the real engine, on a progress that the test moves. No
// test downloads a speech model.
@Suite("model download progress", .timeLimit(.minutes(1)))
struct DownloadProgressTests {
    // The value now comes at once. Then the last value after each change comes, at most one
    // each progress step. The report ends at its cancel.
    @Test func theProgressComesAtEachChangeAtMostTwiceASecond() async {
        let clock = ManualClock()
        let progress = Progress(totalUnitCount: 100)
        let (values, output) = AsyncStream<Double>.makeStream()
        let report = Task { await AnalyzerEngine.report(progress, to: output, clock: clock) }
        var got = values.makeAsyncIterator()
        #expect(await got.next() == 0)
        await clock.waitForSleepers(1)
        progress.completedUnitCount = 20
        progress.completedUnitCount = 30
        clock.advance(by: AnalyzerEngine.progressStep)
        #expect(await got.next() == 0.3)
        await clock.waitForSleepers(1)
        clock.advance(by: AnalyzerEngine.progressStep)
        progress.completedUnitCount = 100
        #expect(await got.next() == 1)
        report.cancel()
        await report.value
        output.finish()
        #expect(await got.next() == nil)
        #expect(AnalyzerEngine.progressStep == .milliseconds(500))
    }
}
