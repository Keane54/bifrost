// The microphone. The helper keeps one AVAudioEngine and its input node for its life, so a session
// starts quickly. Only open() opens the microphone. close() closes it.
import AVFoundation

final class Microphone {
  private var engine = AVAudioEngine()
  private var observer: NSObjectProtocol?
  private var askedForAccess = false
  // The open session: its sink node and the receiver of its buffers.
  private var sink: AVAudioSinkNode?
  private var onBuffer: ((AVAudioPCMBuffer) -> Void)?
  // True after a change of the audio device while the microphone is closed. The next session then
  // uses a new engine.
  private var stale = false
  // The restarts of the open session after a change of the audio device.
  private var restarts = 0
  private let maxRestarts = 3

  // Make the input node before the first session, so the first start is quick. This does not open
  // the microphone. But the input node waits for the permission check of macOS, and that check can
  // show a prompt and wait for minutes. So do it only when the permission is given.
  func warm() {
    watch(engine)
    if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized { _ = engine.inputNode }
  }

  // The answer of macOS. macOS checks Bifrost, the app that started the helper.
  func permission() -> Permission {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized: return .granted
    case .notDetermined: return .undetermined
    default: return .denied
    }
  }

  // Show the prompt one time. Do not wait for the answer, because a prompt can stay open for
  // minutes.
  func ask() {
    guard !askedForAccess else { return }
    askedForAccess = true
    AVCaptureDevice.requestAccess(for: .audio) { _ in }
  }

  // The format of the input. Throw when the Mac has no microphone.
  func inputFormat() throws -> AVAudioFormat {
    if stale { renew() }
    return try currentFormat()
  }

  // Open the microphone. onBuffer runs on the audio thread for each cycle (about 10 ms). After a
  // change of the audio device, the buffers can come in a new format.
  func open(format: AVAudioFormat, onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws {
    self.onBuffer = onBuffer
    restarts = 0
    do {
      try connect(format: format)
    } catch {
      close()
      stale = true
      throw HelperError(
        code: .failed, message: "The microphone did not open: \(error.localizedDescription)")
    }
  }

  // Close the microphone. After this, onBuffer gets no more buffers.
  func close() {
    engine.stop()
    disconnect()
    onBuffer = nil
  }

  private func currentFormat() throws -> AVAudioFormat {
    let format = engine.inputNode.outputFormat(forBus: 0)
    guard format.sampleRate > 0, format.channelCount > 0 else {
      throw HelperError(code: .failed, message: "The Mac has no microphone.")
    }
    return format
  }

  // A sink node gives even buffers. A tap gives bursts of 100 ms.
  private func connect(format: AVAudioFormat) throws {
    guard let onBuffer else { return }
    let sink = AVAudioSinkNode { _, frames, list -> OSStatus in
      guard
        let view = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: list, deallocator: nil),
        let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
        let source = view.floatChannelData, let target = copy.floatChannelData
      else { return noErr }
      copy.frameLength = frames
      for channel in 0..<Int(format.channelCount) {
        target[channel].update(from: source[channel], count: Int(frames))
      }
      onBuffer(copy)
      return noErr
    }
    engine.attach(sink)
    self.sink = sink
    engine.connect(engine.inputNode, to: sink, format: format)
    engine.prepare()
    try engine.start()
  }

  private func disconnect() {
    guard let sink else { return }
    engine.disconnectNodeInput(sink)
    engine.detach(sink)
    self.sink = nil
  }

  // After a change of the audio device, the engine stops and its formats can change. An open
  // session starts again with the new format. A closed microphone gets a new engine later.
  private func watch(_ engine: AVAudioEngine) {
    observer = NotificationCenter.default.addObserver(
      forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
    ) { [weak self] _ in
      self?.deviceChanged()
    }
  }

  private func deviceChanged() {
    guard sink != nil else {
      stale = true
      return
    }
    engine.stop()
    disconnect()
    guard restarts < maxRestarts else {
      Out.note("The audio device changed too often. The session gets no more audio.")
      return
    }
    restarts += 1
    do {
      try connect(format: try currentFormat())
    } catch {
      disconnect()
      Out.note("The microphone did not open again: \(error.localizedDescription)")
    }
  }

  private func renew() {
    if let observer { NotificationCenter.default.removeObserver(observer) }
    engine = AVAudioEngine()
    _ = engine.inputNode
    watch(engine)
    stale = false
  }
}
