/// AudioRingBuffer — Lock-free SPSC ring buffer for int16 PCM audio.
/// Writer: pollAudio callback (main/audio-poll thread).
/// Reader: AVAudioSourceNode render (audio thread).
/// Uses os_unfair_lock for correctness on ARM64 instead of deprecated OSMemoryBarrier.

import Foundation
import os

final class AudioRingBuffer: @unchecked Sendable {
    private let capacity: Int
    private let maxLatencyFrames: Int
    private let buffer: UnsafeMutablePointer<Int16>

    // Use a lock for cross-thread safety (reader=audio thread, writer=poll thread)
    // os_unfair_lock is the fastest available lock on Apple platforms
    private let lock = OSAllocatedUnfairLock()
    private var _writeIndex: Int = 0
    private var _readIndex: Int = 0

    init(capacityFrames: Int = 9600, maxLatencyFrames: Int = 3600) {
        self.capacity = capacityFrames
        self.maxLatencyFrames = maxLatencyFrames
        self.buffer = .allocate(capacity: capacityFrames * 2)
        buffer.initialize(repeating: 0, count: capacityFrames * 2)
    }

    deinit {
        buffer.deinitialize(count: capacity * 2)
        buffer.deallocate()
    }

    private func availableFrames(w: Int, r: Int) -> Int {
        if w >= r { return w - r }
        return capacity - r + w
    }

    /// Write int16 interleaved stereo PCM. Called from poll thread.
    func write(pcm: UnsafePointer<Int16>, frameCount: Int) {
        lock.withLock {
            let wi = _writeIndex
            let ri = _readIndex

            let space: Int
            if wi >= ri { space = capacity - wi + ri - 1 }
            else { space = ri - wi - 1 }
            guard space > 0 else { return }

            let toWrite = min(frameCount, space)
            let firstChunk = min(toWrite, capacity - wi)
            memcpy(buffer.advanced(by: wi * 2), pcm,
                   firstChunk * 2 * MemoryLayout<Int16>.size)

            if toWrite > firstChunk {
                let secondChunk = toWrite - firstChunk
                memcpy(buffer, pcm.advanced(by: firstChunk * 2),
                       secondChunk * 2 * MemoryLayout<Int16>.size)
            }

            _writeIndex = (wi + toWrite) % capacity
        }
    }

    /// Read from buffer, converting int16 → float32 non-interleaved.
    /// Auto-skips ahead if too much latency has accumulated.
    func read(left: UnsafeMutablePointer<Float>,
              right: UnsafeMutablePointer<Float>,
              frameCount: Int) -> Int {
        lock.withLock {
            var avail = availableFrames(w: _writeIndex, r: _readIndex)

            // Skip ahead if too much latency
            if avail > maxLatencyFrames {
                let skip = avail - maxLatencyFrames / 2
                _readIndex = (_readIndex + skip) % capacity
                avail = availableFrames(w: _writeIndex, r: _readIndex)
            }

            let toRead = min(frameCount, avail)
            if toRead == 0 { return 0 }

            var ri = _readIndex
            for i in 0..<toRead {
                let idx = ri * 2
                left[i] = Float(buffer[idx]) / 32768.0
                right[i] = Float(buffer[idx + 1]) / 32768.0
                ri = (ri + 1) % capacity
            }

            _readIndex = ri
            return toRead
        }
    }

    func reset() {
        lock.withLock {
            _writeIndex = 0
            _readIndex = 0
        }
    }
}
