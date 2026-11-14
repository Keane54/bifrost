// The voice level of a session. It gives one level event for each 1/30 s of audio.
import AVFoundation

final class LevelMeter {
  private let chunkFrames: Int
  private var sum: Float = 0
  private var count = 0

  init(sampleRate: Double) {
    chunkFrames = max(1, Int(sampleRate / 30))
  }

  // Add one buffer. It runs on the audio thread. It uses the first channel only.
  func feed(_ buffer: AVAudioPCMBuffer) {
    guard let data = buffer.floatChannelData?[0] else { return }
    for index in 0..<Int(buffer.frameLength) {
      let sample = data[index]
      sum += sample * sample
      count += 1
      if count >= chunkFrames {
        let rms = (sum / Float(count)).squareRoot()
        let db = 20 * log10(max(Double(rms), 1e-9))
        // -55 dB (a quiet room) gives 0. -10 dB (a loud voice) gives 1.
        Out.level((db + 55) / 45)
        sum = 0
        count = 0
      }
    }
  }
}
