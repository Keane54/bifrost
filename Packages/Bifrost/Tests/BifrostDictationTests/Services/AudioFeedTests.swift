// The path of the microphone frames from the audio thread to the session: the ring that the
// audio thread writes, and the feed that reads it off the audio thread. A fake audio source in
// the test writes the frames, as the sink node of the microphone does. No test opens the
// microphone or uses an audio device.
import AVFoundation
import BifrostTestSupport
import Synchronization
import Testing

@testable import BifrostDictation

// A fake audio source: it makes the buffers that the audio thread gives to the sink node.
private struct FakeSource {
    let format: AVAudioFormat
    // The value of the next sample of each channel. Channel c counts up from c * 1,000,000.
    private var next = 0

    init(sampleRate: Double = 48_000, channels: AVAudioChannelCount = 2) throws {
        format = try #require(
            AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels))
    }

    static func value(channel: Int, frame: Int) -> Float {
        Float(channel * 1_000_000 + frame)
    }

    // The next frames of the source, written into the ring as the audio thread writes them.
    mutating func play(_ frames: Int, into ring: AudioRing) throws {
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        let channels = try #require(buffer.floatChannelData)
        for channel in 0..<Int(format.channelCount) {
            for frame in 0..<frames {
                channels[channel][frame] = Self.value(channel: channel, frame: next + frame)
            }
        }
        next += frames
        ring.write(buffer.audioBufferList, frames: frames)
    }
}

// The samples of each channel of the buffers, in order.
private func samples(_ buffers: [AVAudioPCMBuffer]) -> [[Float]] {
    guard let first = buffers.first else { return [] }
    return (0..<Int(first.format.channelCount)).map { channel in
        buffers.flatMap { buffer in
            let data = buffer.floatChannelData![channel]
            return (0..<Int(buffer.frameLength)).map { data[$0] }
        }
    }
}

// The samples that the source gave for the frames in the range, for each channel.
private func expected(_ frames: Range<Int>, channels: Int = 2) -> [[Float]] {
    (0..<channels).map { channel in frames.map { FakeSource.value(channel: channel, frame: $0) } }
}

@Suite("audio ring", .timeLimit(.minutes(1)))
struct AudioRingTests {
    @Test func theRingGivesTheFramesOfEachChannelInOrder() throws {
        var source = try FakeSource()
        let ring = AudioRing(format: source.format)
        for _ in 0..<3 { try source.play(512, into: ring) }
        let buffer = try #require(ring.take())
        #expect(buffer.format == source.format)
        #expect(samples([buffer]) == expected(0..<1536))
        #expect(ring.take() == nil)
    }

    // The ring is one second of audio when no capacity is given.
    @Test func theRingHoldsOneSecondOfAudio() throws {
        let source = try FakeSource(sampleRate: 44_100, channels: 1)
        #expect(AudioRing(format: source.format).capacity == 44_100)
    }

    // The frames pass the end of the storage and the end of a block of samples many times.
    @Test func theRingWrapsAroundItsEnd() throws {
        var source = try FakeSource()
        let ring = AudioRing(format: source.format, capacity: 5_000)
        var got: [AVAudioPCMBuffer] = []
        for _ in 0..<12 {
            try source.play(1_700, into: ring)
            got.append(try #require(ring.take()))
        }
        #expect(samples(got) == expected(0..<20_400))
    }

    // The audio thread never waits for the reader. When the ring is full, the new frames go and
    // the frames that wait stay.
    @Test func aFullRingDropsTheNewFrames() throws {
        var source = try FakeSource()
        let ring = AudioRing(format: source.format, capacity: 1_000)
        try source.play(600, into: ring)
        try source.play(600, into: ring)
        #expect(samples([try #require(ring.take())]) == expected(0..<1_000))
        try source.play(300, into: ring)
        #expect(samples([try #require(ring.take())]) == expected(1_200..<1_500))
    }

    // The audio thread writes while a reader takes on another thread. The reader gets each frame
    // one time, in order, and no frame changes.
    @Test func aReaderOnAnotherThreadGetsEachFrameInOrder() async throws {
        var source = try FakeSource()
        let ring = AudioRing(format: source.format, capacity: 2_048)
        let cycles = 400
        let reader = Task.detached {
            var got: [AVAudioPCMBuffer] = []
            var frames = 0
            while frames < cycles * 256 {
                if let buffer = ring.take() {
                    frames += Int(buffer.frameLength)
                    got.append(buffer)
                } else {
                    await Task.yield()
                }
            }
            return samples(got)
        }
        for _ in 0..<cycles {
            // The writer waits for room, so the test drops no frame.
            while ring.capacity - ring.waiting < 256 { await Task.yield() }
            try source.play(256, into: ring)
        }
        #expect(await reader.value == expected(0..<(cycles * 256)))
    }
}

@Suite("audio feed", .timeLimit(.minutes(1)))
@MainActor
struct AudioFeedTests {
    // The samples of each buffer that the receiver of the feed got, for each channel.
    private final class Receiver: Sendable {
        private let got = Mutex<[[[Float]]]>([])

        var buffers: [[[Float]]] { got.withLock { $0 } }
        // The samples of all buffers, for each channel.
        var joined: [[Float]] {
            let buffers = buffers
            guard let first = buffers.first else { return [] }
            return first.indices.map { channel in buffers.flatMap { $0[channel] } }
        }

        func take(_ buffer: sending AVAudioPCMBuffer) {
            let got = samples([buffer])
            self.got.withLock { $0.append(got) }
        }
    }

    // The feed reads the ring at each step of its clock and gives the frames to the receiver.
    @Test func theFeedGivesTheFramesAtEachDrainStep() async throws {
        let clock = ManualClock()
        let receiver = Receiver()
        let feed = AudioFeed(clock: clock) { receiver.take($0) }
        defer { feed.close() }
        var source = try FakeSource()
        let ring = AudioRing(format: source.format)
        feed.use(ring)
        await clock.waitForSleepers(1)
        try source.play(512, into: ring)
        #expect(receiver.buffers.isEmpty)
        clock.advance(by: AudioFeed.drainStep)
        // The feed sleeps again after its drain.
        await clock.waitForSleepers(1)
        #expect(receiver.joined == expected(0..<512))
        // A step with no frames gives nothing.
        clock.advance(by: AudioFeed.drainStep)
        await clock.waitForSleepers(1)
        #expect(receiver.buffers.count == 1)
        try source.play(480, into: ring)
        try source.play(480, into: ring)
        clock.advance(by: AudioFeed.drainStep)
        await clock.waitForSleepers(1)
        #expect(receiver.joined == expected(0..<1_472))
    }

    // After close, the receiver gets nothing more, and the drain task ends.
    @Test func theFeedGivesNothingAfterItsClose() async throws {
        let clock = ManualClock()
        let receiver = Receiver()
        let feed = AudioFeed(clock: clock) { receiver.take($0) }
        var source = try FakeSource()
        let ring = AudioRing(format: source.format)
        feed.use(ring)
        await clock.waitForSleepers(1)
        try source.play(512, into: ring)
        feed.close()
        feed.drain()
        clock.advance(by: AudioFeed.drainStep)
        await waitUntil { clock.sleeperCount == 0 }
        #expect(receiver.buffers.isEmpty)
    }

    // A change of the audio device gives a new ring. The frames of the old ring come first.
    @Test func theFramesOfTheOldRingComeBeforeANewRing() async throws {
        let clock = ManualClock()
        let receiver = Receiver()
        let feed = AudioFeed(clock: clock) { receiver.take($0) }
        defer { feed.close() }
        var old = try FakeSource()
        let oldRing = AudioRing(format: old.format)
        feed.use(oldRing)
        try old.play(300, into: oldRing)
        var new = try FakeSource(sampleRate: 44_100, channels: 1)
        let newRing = AudioRing(format: new.format)
        feed.use(newRing)
        try new.play(200, into: newRing)
        feed.drain()
        #expect(receiver.buffers == [expected(0..<300), expected(0..<200, channels: 1)])
    }
}
