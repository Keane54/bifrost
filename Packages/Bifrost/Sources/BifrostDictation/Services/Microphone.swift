// The microphone of the speech engine. The engine keeps one AVAudioEngine and its input node
// until its release, so a session starts quickly. Only open() opens the microphone, and close()
// closes it. The state is in a Mutex. The real-time audio thread never takes this lock: its sink
// block only copies the frames into a ring that open() or a restart makes before the start, and a
// drain task gives the frames to the session off the audio thread (AudioFeed.swift). The change
// of an audio device comes on a private serial queue, never on the main thread. A release takes
// the audio engine out of the state at once and stops it off the caller, so a later open uses a
// new audio engine.
//
// A release also starts a new epoch. A begin reads the epoch at its start, and the format read
// and the open check it in the lock. So a release during a begin makes no new audio engine and
// opens no microphone for that begin.
import AVFoundation
import Synchronization

final class Microphone: Sendable {
    private struct State {
        // Made at the first use, so an engine that never dictates makes no audio engine.
        var engine: AVAudioEngine?
        var observer: (any NSObjectProtocol)?
        var askedForAccess = false
        // The open session: its sink node and the feed that gives its frames to the session.
        var sink: AVAudioSinkNode?
        var feed: AudioFeed?
        // True after a change of the audio device while the microphone is closed. The next
        // session then uses a new engine.
        var stale = false
        // The restarts of the open session after a change of the audio device.
        var restarts = 0
        var opens = 0
        var closes = 0
        // The number of releases.
        var epoch = 0
    }

    // The parts of an audio engine that a release stops off the caller.
    private struct Parts {
        var engine: AVAudioEngine
        var sink: AVAudioSinkNode?
        var observer: (any NSObjectProtocol)?
    }

    private static let maxRestarts = 3

    private let state = Mutex(State())
    // The queue of the change notices of the audio device.
    private let notices: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "Bifrost microphone"
        return queue
    }()

    var opens: Int { state.withLock { $0.opens } }
    var closes: Int { state.withLock { $0.closes } }
    // The epoch now. A begin gives it to inputFormat and open.
    var epoch: Int { state.withLock { $0.epoch } }

    // Make the input node before the first session, so the first start is quick. This does not
    // open the microphone. But the input node waits for the permission check of macOS, and that
    // check can show a prompt and wait for minutes. So do it only when the permission is given.
    func warm() {
        let authorized = permission() == .granted
        state.withLock { s in
            let engine = engine(&s)
            if authorized { _ = engine.inputNode }
        }
    }

    // The answer of macOS. It never shows a prompt.
    func permission() -> SpeechPermission {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .granted
        case .notDetermined: .undetermined
        default: .denied
        }
    }

    // Show the prompt one time. Do not wait for the answer, because a prompt can stay open for
    // minutes.
    func ask() {
        let first = state.withLock { s in
            defer { s.askedForAccess = true }
            return !s.askedForAccess
        }
        guard first else { return }
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
    }

    // The format of the input. It fails when the Mac has no microphone, and after a release in
    // a later epoch than the epoch of the begin.
    func inputFormat(epoch: Int) throws(SpeechError) -> AVAudioFormat {
        try state.withLock { s throws(SpeechError) in
            guard s.epoch == epoch else { throw .code(.failed) }
            if s.stale { renew(&s) }
            return try Self.format(of: engine(&s))
        }
    }

    // Open the microphone. onBuffer gets the frames at each drain step (about 10 ms), on the
    // drain task of the feed, never on the audio thread. After a change of the audio device, the
    // buffers can come in a new format. After a release in a later epoch than the epoch of the
    // begin, the open fails and makes no audio engine.
    func open(
        format: AVAudioFormat, epoch: Int,
        onBuffer: @escaping @Sendable (sending AVAudioPCMBuffer) -> Void
    ) throws(SpeechError) {
        try state.withLock { s throws(SpeechError) in
            guard s.epoch == epoch else { throw .code(.failed) }
            // One session at a time: the feed of an older open gets no more frames.
            s.feed?.close()
            s.feed = AudioFeed(clock: ContinuousClock(), receiver: onBuffer)
            s.restarts = 0
            do {
                try connect(&s, format: format)
            } catch {
                s.engine?.stop()
                disconnect(&s)
                s.feed?.close()
                s.feed = nil
                s.stale = true
                throw .code(.failed)
            }
            s.opens += 1
        }
    }

    // Close the microphone. It stops the audio engine, then gives the frames that wait in the
    // ring to onBuffer, so the session gets the audio up to the release of the key. After this,
    // onBuffer gets no more buffers. A microphone that is not open stays closed. It stops the
    // audio engine on the thread of the caller: the end of a session calls it off the main
    // actor, and only the cancel of a window close or a quit calls it on the main actor.
    func close() {
        state.withLock { s in
            guard let feed = s.feed else { return }
            s.engine?.stop()
            feed.drain()
            feed.close()
            disconnect(&s)
            s.feed = nil
            s.closes += 1
        }
    }

    // The idle rule and a release: the microphone closes, and the audio engine goes. The state
    // changes at once. The audio engine stops off the caller, so the main actor does not wait.
    func release() {
        let parts = state.withLock { s -> Parts? in
            s.epoch += 1
            if let feed = s.feed {
                feed.close()
                s.closes += 1
            }
            s.feed = nil
            s.stale = false
            guard let engine = s.engine else { return nil }
            let parts = Parts(engine: engine, sink: s.sink, observer: s.observer)
            s.engine = nil
            s.sink = nil
            s.observer = nil
            return parts
        }
        guard let parts else { return }
        Task.detached {
            if let observer = parts.observer {
                NotificationCenter.default.removeObserver(observer)
            }
            parts.engine.stop()
            if let sink = parts.sink {
                parts.engine.disconnectNodeInput(sink)
                parts.engine.detach(sink)
            }
        }
    }

    // MARK: - Private

    private func engine(_ s: inout State) -> AVAudioEngine {
        if let engine = s.engine { return engine }
        let engine = AVAudioEngine()
        s.engine = engine
        watch(&s, engine)
        return engine
    }

    private static func format(of engine: AVAudioEngine) throws(SpeechError) -> AVAudioFormat {
        let format = engine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw .code(.failed) }
        return format
    }

    // A sink node gives the frames of each I/O cycle (about 10 ms). A tap of the input node
    // gives bursts of 100 ms or more, so the levels and the text would come later and less
    // evenly. The sink block runs on the real-time audio thread, so it only writes the frames
    // into the ring of this format, which this call makes before the start.
    private func connect(_ s: inout State, format: AVAudioFormat) throws {
        guard let feed = s.feed else { return }
        let engine = engine(&s)
        let ring = AudioRing(format: format)
        let sink = AVAudioSinkNode { _, frames, list -> OSStatus in
            ring.write(list, frames: Int(frames))
            return noErr
        }
        engine.attach(sink)
        s.sink = sink
        engine.connect(engine.inputNode, to: sink, format: format)
        feed.use(ring)
        engine.prepare()
        try engine.start()
    }

    private func disconnect(_ s: inout State) {
        guard let sink = s.sink, let engine = s.engine else { return }
        engine.disconnectNodeInput(sink)
        engine.detach(sink)
        s.sink = nil
    }

    // After a change of the audio device, the engine stops and its formats can change. An open
    // session starts again with the new format. A closed microphone gets a new engine later.
    private func watch(_ s: inout State, _ engine: AVAudioEngine) {
        s.observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: notices
        ) { [weak self] _ in
            self?.deviceChanged()
        }
    }

    private func deviceChanged() {
        state.withLock { s in
            guard s.sink != nil else {
                s.stale = true
                return
            }
            s.engine?.stop()
            disconnect(&s)
            // The audio device changed too often. The session gets no more audio.
            guard s.restarts < Self.maxRestarts, let engine = s.engine else { return }
            s.restarts += 1
            do {
                try connect(&s, format: try Self.format(of: engine))
            } catch {
                // The microphone did not open again. The session gets no more audio.
                disconnect(&s)
            }
        }
    }

    private func renew(_ s: inout State) {
        if let observer = s.observer { NotificationCenter.default.removeObserver(observer) }
        s.observer = nil
        s.engine = nil
        let engine = engine(&s)
        _ = engine.inputNode
        s.stale = false
    }
}
