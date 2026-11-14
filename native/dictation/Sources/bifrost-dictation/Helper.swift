// The sessions of the helper. The command loop calls boot() one time, then each command in order.
// So a start and a stop never run at the same time: a stop that comes during a start runs after
// the microphone is open. A model download runs in its own task, so the commands do not wait.
import AVFoundation

@MainActor
final class Helper {
  // The time that a stop waits for the final text. After it, end has the text so far.
  private static let endLimit: TimeInterval = 1.5
  // The time between two downloading events: at most two each second.
  private static let progressStep: UInt64 = 500_000_000

  private let microphone = Microphone()
  // Set when the helper is ready.
  private var recognizer: Recognizer?
  // The error that stopped the boot. Each start gives it again.
  private var bootError: HelperError?
  // The progress of the model download, 0 to 1. Nil when no download runs.
  private var progress: Double?
  private var current: Running?

  private struct Running {
    let session: RecognizerSession
    let events: SessionEvents
  }

  // Load the speech model and give ready, or start the download, or give the error.
  func boot() async {
    microphone.warm()
    let recognizer: Recognizer
    let download: ModelDownload?
    do {
      recognizer = try await pickRecognizer()
    } catch {
      failBoot(HelperError.from(error))
      return
    }
    do {
      download = try await recognizer.modelDownload()
    } catch {
      Out.note("The model download did not start: \(error.localizedDescription)")
      failBoot(Self.downloadFailed)
      return
    }
    if let download {
      startDownload(download, for: recognizer)
    } else {
      await becomeReady(recognizer)
    }
  }

  func handle(_ command: String) async {
    switch command {
    case "start": await start()
    case "stop": await stop()
    default: Out.note("Unknown command: \(command.prefix(40))")
    }
  }

  // Close the microphone at quit or at the end of stdin.
  func close() {
    guard let current else { return }
    self.current = nil
    microphone.close()
    current.events.close()
    current.session.cancel()
  }

  private static let downloadFailed = HelperError(
    code: .noModel,
    message: "Bifrost couldn't download the speech model. Check your connection and try again.")

  private func failBoot(_ error: HelperError) {
    progress = nil
    bootError = error
    Out.error(error)
  }

  private func becomeReady(_ recognizer: Recognizer) async {
    do {
      try await recognizer.prepare()
    } catch {
      failBoot(HelperError.from(error))
      return
    }
    progress = nil
    self.recognizer = recognizer
    Out.ready(language: recognizer.language, fallback: recognizer.fallback)
  }

  // Download the model from Apple one time. One downloading event at 0, then one each step.
  private func startDownload(_ download: ModelDownload, for recognizer: Recognizer) {
    progress = 0
    Out.downloading(0)
    let ticker = Task { @MainActor [weak self] in
      while true {
        try? await Task.sleep(nanoseconds: Self.progressStep)
        guard let self, !Task.isCancelled, self.progress != nil else { return }
        let value = min(1, max(0, download.fraction))
        self.progress = value
        Out.downloading(value)
      }
    }
    Task { @MainActor in
      do {
        try await download.run()
      } catch {
        ticker.cancel()
        Out.note("The model download failed: \(error.localizedDescription)")
        failBoot(Self.downloadFailed)
        return
      }
      ticker.cancel()
      progress = 1
      await becomeReady(recognizer)
    }
  }

  private func start() async {
    if current != nil {
      Out.note("A session runs already.")
      return
    }
    // During the download, a start opens no microphone.
    if let progress {
      Out.downloading(progress)
      return
    }
    guard let recognizer else {
      Out.error(bootError ?? HelperError(code: .failed, message: "The helper did not start."))
      return
    }
    do {
      try checkPermissions(recognizer)
      let format = try microphone.inputFormat()
      let events = SessionEvents()
      // The events are the identity of the session. ObjectIdentifier can go to another task.
      let id = ObjectIdentifier(events)
      events.whenFailed { [weak self] in
        Task { @MainActor in self?.sessionFailed(id) }
      }
      let session = try await recognizer.begin(events)
      let meter = LevelMeter(sampleRate: format.sampleRate)
      do {
        try microphone.open(format: format) { buffer in
          meter.feed(buffer)
          session.feed(buffer)
        }
      } catch {
        // The session did not start, so its text does not go to Bifrost.
        events.close()
        session.cancel()
        await prepareNext(recognizer)
        throw error
      }
      current = Running(session: session, events: events)
      // The session can fail during begin. Then sessionFailed ran while current was nil, so it
      // closed nothing. Close the microphone and the session now.
      if !events.isOpen { sessionFailed(id) }
    } catch {
      Out.error(HelperError.from(error))
    }
  }

  // Ask for each permission that has no answer yet, together, so the user sees all prompts at the
  // first hold. Never wait for the answers.
  private func checkPermissions(_ recognizer: Recognizer) throws {
    let mic = microphone.permission()
    let speech = recognizer.permission()
    if mic == .undetermined { microphone.ask() }
    if speech == .undetermined { recognizer.ask() }
    switch (mic, speech) {
    case (.denied, _):
      throw HelperError(
        code: .micDenied, message: "The microphone is off for Bifrost in System Settings.")
    case (.undetermined, _):
      throw HelperError(
        code: .micAsked,
        message: "macOS asks for the microphone. Answer the prompt, then hold the key again.")
    case (_, .denied):
      throw HelperError(
        code: .speechDenied, message: "Speech Recognition is off for Bifrost in System Settings.")
    case (_, .undetermined):
      throw HelperError(
        code: .speechAsked,
        message: "macOS asks for Speech Recognition. Answer the prompt, then hold the key again.")
    default:
      return
    }
  }

  // A session failed, and its events gave the error. Close the microphone and the session at
  // once. A later stop then gives an empty end. The next start prepares a new analyzer.
  private func sessionFailed(_ id: ObjectIdentifier) {
    guard let running = current, ObjectIdentifier(running.events) == id else { return }
    current = nil
    microphone.close()
    running.session.cancel()
  }

  // Each stop gives one end event. A stop with no session gives an empty text.
  private func stop() async {
    guard let current, let recognizer else {
      Out.end(final: "")
      return
    }
    self.current = nil
    microphone.close()
    let final = await finalText(of: current)
    current.events.close()
    Out.end(final: final)
    await prepareNext(recognizer)
  }

  // The final text of the session. When it does not come within the limit, stop the session and
  // give the text so far.
  private func finalText(of running: Running) async -> String {
    await withCheckedContinuation { (waiter: CheckedContinuation<String, Never>) in
      let once = Once()
      Task {
        let text = await running.session.end()
        if once.claim() { waiter.resume(returning: text) }
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + Self.endLimit) {
        guard once.claim() else { return }
        Out.note("The final text did not come in time.")
        let text = running.events.close()
        running.session.cancel()
        waiter.resume(returning: text)
      }
    }
  }

  // Load the analyzer of the next session now, so the next start is quick.
  private func prepareNext(_ recognizer: Recognizer) async {
    do {
      try await recognizer.prepare()
    } catch {
      Out.note("The next session is not ready: \(error.localizedDescription)")
    }
  }
}

// True for the first claim only.
private final class Once: @unchecked Sendable {
  private let lock = NSLock()
  private var claimed = false

  func claim() -> Bool {
    lock.guarded {
      if claimed { return false }
      claimed = true
      return true
    }
  }
}
