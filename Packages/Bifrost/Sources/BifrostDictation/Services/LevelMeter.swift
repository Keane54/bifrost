// The voice level of a session. It gives one level for each 1/30 s of audio. A session feeds it
// on the drain task of the microphone, off the real-time audio thread.
import AVFoundation
import Accelerate

struct LevelMeter: Sendable {
    private let chunkFrames: Int
    // The sum of the squares of the samples of the chunk so far, and their number.
    private var sum: Float = 0
    private var count = 0

    init(sampleRate: Double) {
        chunkFrames = max(1, Int(sampleRate / 30))
    }

    // Add one buffer, and give the level of each chunk that it ends. It uses the first channel
    // only.
    mutating func feed(_ buffer: AVAudioPCMBuffer) -> [Double] {
        guard let data = buffer.floatChannelData?[0] else { return [] }
        let frames = Int(buffer.frameLength)
        var levels: [Double] = []
        var index = 0
        while index < frames {
            let run = min(frames - index, chunkFrames - count)
            sum += vDSP.sumOfSquares(UnsafeBufferPointer(start: data + index, count: run))
            count += run
            index += run
            if count >= chunkFrames {
                levels.append(Self.level(rms: (sum / Float(count)).squareRoot()))
                sum = 0
                count = 0
            }
        }
        return levels
    }

    // -55 dB (a quiet room) gives 0. -10 dB (a loud voice) gives 1.
    static func level(rms: Float) -> Double {
        let db = 20 * log10(max(Double(rms), 1e-9))
        return min(1, max(0, (db + 55) / 45))
    }
}
