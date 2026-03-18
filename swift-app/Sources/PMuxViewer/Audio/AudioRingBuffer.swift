/// AudioRingBuffer — Lock-free SPSC ring buffer for int16 PCM audio.
/// Writer: pollAudio callback (main thread). Reader: AVAudioSourceNode render (audio thread).
/// Keeps latency low by dropping old data when the buffer gets too full.

import Foundation

final class AudioRingBuffer: @unchecked Sendable {
    private let capacity: Int          // in frames (stereo pairs)
    private let maxLatencyFrames: Int  // drop threshold
    private let buffer: UnsafeMutablePointer<Int16>
    private let _writeIndex: UnsafeMutablePointer<Int>
    private let _readIndex: UnsafeMutablePointer<Int>

    /// Create ring buffer.
    /// - capacityFrames: total buffer size in frames
    /// - maxLatencyFrames: if available data exceeds this, reader skips ahead
    init(capacityFrames: Int = 9600, maxLatencyFrames: Int = 3600) {
        // 9600 = 200ms at 48kHz, maxLatency 3600 = 75ms
        self.capacity = capacityFrames
        self.maxLatencyFrames = maxLatencyFrames
        self.buffer = .allocate(capacity: capacityFrames * 2)
        buffer.initialize(repeating: 0, count: capacityFrames * 2)
        _writeIndex = .allocate(capacity: 1)
        _writeIndex.initialize(to: 0)
        _readIndex = .allocate(capacity: 1)
        _readIndex.initialize(to: 0)
    }

    deinit {
        buffer.deallocate()
        _writeIndex.deallocate()
        _readIndex.deallocate()
    }

    private var writeIndex: Int {
        get { _writeIndex.pointee }
        set { _writeIndex.pointee = newValue }
    }

    private var readIndex: Int {
        get { _readIndex.pointee }
        set { _readIndex.pointee = newValue }
    }

    var availableFrames: Int {
        let w = writeIndex
        let r = readIndex
        if w >= r { return w - r }
        return capacity - r + w
    }

    /// Write int16 interleaved stereo PCM. Fast path, no locks.
    /// If buffer is getting full, old data is implicitly dropped (write overwrites).
    func write(pcm: UnsafePointer<Int16>, frameCount: Int) {
        let wi = writeIndex
        let ri = readIndex

        // Available space
        let space: Int
        if wi >= ri {
            space = capacity - wi + ri - 1
        } else {
            space = ri - wi - 1
        }
        guard space > 0 else { return }

        let toWrite = min(frameCount, space)

        let firstChunk = min(toWrite, capacity - wi)
        memcpy(buffer.advanced(by: wi * 2),
               pcm,
               firstChunk * 2 * MemoryLayout<Int16>.size)

        if toWrite > firstChunk {
            let secondChunk = toWrite - firstChunk
            memcpy(buffer,
                   pcm.advanced(by: firstChunk * 2),
                   secondChunk * 2 * MemoryLayout<Int16>.size)
        }

        OSMemoryBarrier()
        writeIndex = (wi + toWrite) % capacity
    }

    /// Read from buffer, converting int16 → float32 non-interleaved.
    /// Automatically skips ahead if too much data is buffered (keeps latency low).
    func read(left: UnsafeMutablePointer<Float>,
              right: UnsafeMutablePointer<Float>,
              frameCount: Int) -> Int {
        var avail = availableFrames

        // Skip ahead if we've accumulated too much latency
        if avail > maxLatencyFrames {
            let skip = avail - maxLatencyFrames / 2  // skip to ~37ms remaining
            readIndex = (readIndex + skip) % capacity
            avail = availableFrames
        }

        let toRead = min(frameCount, avail)
        if toRead == 0 { return 0 }

        var ri = readIndex
        for i in 0..<toRead {
            let idx = ri * 2
            left[i] = Float(buffer[idx]) / 32768.0
            right[i] = Float(buffer[idx + 1]) / 32768.0
            ri = (ri + 1) % capacity
        }

        OSMemoryBarrier()
        readIndex = ri
        return toRead
    }

    func reset() {
        writeIndex = 0
        readIndex = 0
    }
}
