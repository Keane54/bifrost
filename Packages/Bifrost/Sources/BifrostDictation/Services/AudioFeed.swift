// The path of the microphone frames from the real-time audio thread to the session. The audio
// thread must not make an object, take a lock or wake a task: each of these can make it miss the
// time of its I/O cycle, and then Core Audio drops input frames. So the audio thread only copies
// the frames of each cycle into a ring that the microphone makes before the start (AudioRing).
// One task of the session reads the ring at each drain step and gives the frames to the session
// (AudioFeed). The convert, the level meter and the events then run on that task.
import AVFoundation
import Synchronization

// The frames of one audio format, from one writer (the audio thread) to one reader (the drain
// task). The writer copies the frames into the storage, then moves the write count with a
// release. The reader reads the write count with an acquire, copies the frames out, then moves
// the read count with a release. So each side sees the samples that the other side finished, and
// no side takes a lock. The counts only grow.
//
// The samples are atomic values in blocks of a fixed size, so the type is Sendable with no
// @unchecked Sendable and no lock. Only write() uses unsafe pointers: the buffer list that the
// sink node gives. A relaxed store or load of a sample is a plain store or load on arm64.
final class AudioRing: Sendable {
    // A block of samples. The storage is in blocks, so no init makes one large value on the
    // stack.
    private final class Block: Sendable {
        typealias Samples = InlineArray<4096, Atomic<UInt32>>
        static let size = Samples.count
        let samples: Samples

        init() {
            samples = Samples { _ in Atomic(0) }
        }
    }

    let format: AVAudioFormat
    // The frames that the ring holds for each channel.
    let capacity: Int
    private let channels: Int
    // The samples of channel c are at c * capacity + (frame % capacity).
    private let blocks: [Block]
    private let written = Atomic<Int>(0)
    private let read = Atomic<Int>(0)

    // A ring of one second of audio, or of the capacity in frames. The format is a standard
    // format: 32-bit float samples, one buffer for each channel.
    init(format: AVAudioFormat, capacity: Int? = nil) {
        self.format = format
        self.capacity = max(1, capacity ?? Int(format.sampleRate))
        channels = Int(format.channelCount)
        let samples = self.capacity * channels
        blocks = (0..<(samples + Block.size - 1) / Block.size).map { _ in Block() }
    }

    // The frames that wait for the reader.
    var waiting: Int {
        written.load(ordering: .acquiring) - read.load(ordering: .acquiring)
    }

    // Copy the frames of one I/O cycle into the ring. Only the audio thread calls it. It makes no
    // object and takes no lock. When the ring has no room, the frames that do not fit go, and the
    // frames that wait stay.
    func write(_ list: UnsafePointer<AudioBufferList>, frames: Int) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        guard buffers.count >= channels else { return }
        let start = written.load(ordering: .relaxed)
        var count = min(frames, capacity - (start - read.load(ordering: .acquiring)))
        for channel in 0..<channels {
            count = min(count, Int(buffers[channel].mDataByteSize) / MemoryLayout<Float>.size)
        }
        guard count > 0 else { return }
        for channel in 0..<channels {
            guard let data = buffers[channel].mData else { return }
            let source = UnsafePointer(data.assumingMemoryBound(to: Float.self))
            copy(channel: channel, from: start, count: count) { offset, block, index in
                block.samples[index].store(source[offset].bitPattern, ordering: .relaxed)
            }
        }
        written.store(start + count, ordering: .releasing)
    }

    // The frames that wait, in one new buffer, or nil when no frame waits. Only the reader calls
    // it. The ring keeps no reference to the buffer.
    func take() -> sending AVAudioPCMBuffer? {
        let start = read.load(ordering: .relaxed)
        let count = written.load(ordering: .acquiring) - start
        guard count > 0,
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
            let target = buffer.floatChannelData
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(count)
        for channel in 0..<channels {
            let samples = target[channel]
            copy(channel: channel, from: start, count: count) { offset, block, index in
                samples[offset] = Float(bitPattern: block.samples[index].load(ordering: .relaxed))
            }
        }
        read.store(start + count, ordering: .releasing)
        return buffer
    }

    // Visit the place of each frame from start of one channel: the offset of the frame from
    // start, its block and its index in the block. The places go round the end of the ring.
    private func copy(
        channel: Int, from start: Int, count: Int, _ visit: (Int, Block, Int) -> Void
    ) {
        var offset = 0
        while offset < count {
            let frame = (start + offset) % capacity
            let sample = channel * capacity + frame
            let block = blocks[sample / Block.size]
            let index = sample % Block.size
            // The frames up to the end of the ring and to the end of the block.
            let run = min(count - offset, capacity - frame, Block.size - index)
            for step in 0..<run { visit(offset + step, block, index + step) }
            offset += run
        }
    }
}

// The reader side of an open microphone. One task wakes at each drain step and gives the frames
// of the ring to the receiver, off the audio thread. Each buffer goes to the receiver, and the
// feed keeps no reference to it. After a change of the audio device, the
// microphone gives a new ring, and the frames of the old ring go first. After close() returns,
// the receiver gets nothing more: a drain that runs holds the lock of the reader, and close()
// waits for it.
final class AudioFeed: Sendable {
    // The time between two drains: about one I/O cycle of the audio device. So the receiver gets
    // the frames about as evenly as the audio thread gives them.
    static let drainStep = Duration.milliseconds(10)

    private struct Reader {
        var ring: AudioRing?
        var closed = false
        var task: Task<Void, Never>?
    }

    private let reader = Mutex(Reader())
    private let receiver: @Sendable (sending AVAudioPCMBuffer) -> Void

    init(
        clock: any Clock<Duration>,
        receiver: @escaping @Sendable (sending AVAudioPCMBuffer) -> Void
    ) {
        self.receiver = receiver
        let task = Task(priority: .userInitiated) { [weak self] in
            while !Task.isCancelled {
                do {
                    try await clock.sleep(for: Self.drainStep)
                } catch {
                    return
                }
                // A feed that is gone ends its task.
                guard let self else { return }
                self.drain()
            }
        }
        reader.withLock { $0.task = task }
    }

    // Read the ring from now. The frames that wait in the ring before it go first.
    func use(_ ring: AudioRing) {
        reader.withLock { r in
            guard !r.closed else { return }
            give(r.ring)
            r.ring = ring
        }
    }

    // Give the frames that wait to the receiver.
    func drain() {
        reader.withLock { r in
            guard !r.closed else { return }
            give(r.ring)
        }
    }

    // Stop the drains. The frames that wait go.
    func close() {
        let task = reader.withLock { r in
            r.closed = true
            r.ring = nil
            return r.task
        }
        task?.cancel()
    }

    private func give(_ ring: AudioRing?) {
        if let buffer = ring?.take() { receiver(buffer) }
    }
}
