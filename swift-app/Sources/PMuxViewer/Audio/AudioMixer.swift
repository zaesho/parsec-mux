/// AudioMixer — Multi-session audio engine with per-session volume and mix modes.
/// Uses AVAudioEngine with one AVAudioSourceNode per connected session.
/// All graph mutations (add/remove session) pause and restart the engine for safety.

import AVFoundation
import Foundation

enum AudioMixMode: String, CaseIterable, Identifiable {
    case afv     = "AfV"
    case grid    = "Grid"
    case manual  = "Manual"
    case all     = "All"

    var id: String { rawValue }
}

@Observable
final class AudioMixer {
    var isRunning: Bool = false
    var mixMode: AudioMixMode = .afv
    var masterVolume: Float = 1.0 {
        didSet { engine.mainMixerNode.outputVolume = masterVolume }
    }
    var sessionVolumes: [String: Float] = [:]

    private let engine = AVAudioEngine()
    private let outputFormat: AVAudioFormat
    private var sourceNodes: [String: AVAudioSourceNode] = [:]
    private var mixerNodes: [String: AVAudioMixerNode] = [:]
    private(set) var ringBuffers: [String: AudioRingBuffer] = [:]

    init() {
        outputFormat = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
    }

    // MARK: - Engine Lifecycle

    func start() {
        guard !isRunning else { return }
        do {
            // Engine needs at least one connection to start cleanly.
            // Defer actual start to when the first session is added.
            // Just mark intent here.
            isRunning = true
            print("[audio] Engine ready (will start on first session)")
        } catch {
            print("[audio] Engine start failed: \(error)")
        }
    }

    private func ensureEngineRunning() {
        guard isRunning && !engine.isRunning else { return }
        do {
            try engine.start()
            print("[audio] Engine started")
        } catch {
            print("[audio] Engine start failed: \(error)")
        }
    }

    func stop() {
        guard isRunning else { return }
        if engine.isRunning { engine.stop() }
        // Reset all ring buffers to avoid stale audio on restart
        for (_, rb) in ringBuffers { rb.reset() }
        isRunning = false
        print("[audio] Engine stopped")
    }

    // MARK: - Session Management

    func addSession(peerID: String) -> AudioRingBuffer {
        if let existing = ringBuffers[peerID] {
            return existing
        }

        let ringBuffer = AudioRingBuffer(capacityFrames: 9600, maxLatencyFrames: 3600)
        ringBuffers[peerID] = ringBuffer

        let sourceNode = AVAudioSourceNode(format: outputFormat) {
            [weak ringBuffer] _, _, frameCount, bufferList -> OSStatus in
            guard let rb = ringBuffer else { return noErr }
            let ablPointer = UnsafeMutableAudioBufferListPointer(bufferList)
            let frames = Int(frameCount)
            guard ablPointer.count >= 2,
                  let leftBuf = ablPointer[0].mData?.assumingMemoryBound(to: Float.self),
                  let rightBuf = ablPointer[1].mData?.assumingMemoryBound(to: Float.self) else {
                return noErr
            }
            let read = rb.read(left: leftBuf, right: rightBuf, frameCount: frames)
            if read < frames {
                memset(leftBuf.advanced(by: read), 0, (frames - read) * MemoryLayout<Float>.size)
                memset(rightBuf.advanced(by: read), 0, (frames - read) * MemoryLayout<Float>.size)
            }
            return noErr
        }

        let mixerNode = AVAudioMixerNode()

        // Pause engine for safe graph mutation
        let engineWasRunning = engine.isRunning
        if engineWasRunning { engine.pause() }

        engine.attach(sourceNode)
        engine.attach(mixerNode)
        engine.connect(sourceNode, to: mixerNode, format: outputFormat)
        engine.connect(mixerNode, to: engine.mainMixerNode, format: outputFormat)

        if engineWasRunning {
            try? engine.start()
        } else {
            // First session — start the engine now that we have nodes
            ensureEngineRunning()
        }

        sourceNodes[peerID] = sourceNode
        mixerNodes[peerID] = mixerNode

        if sessionVolumes[peerID] == nil {
            sessionVolumes[peerID] = 1.0
        }

        print("[audio] Added session: \(peerID.prefix(8))")
        return ringBuffer
    }

    func removeSession(peerID: String) {
        // Pause engine for safe graph mutation
        let wasRunning = isRunning
        if wasRunning { engine.pause() }

        if let sourceNode = sourceNodes.removeValue(forKey: peerID) {
            engine.disconnectNodeOutput(sourceNode)
            engine.detach(sourceNode)
        }
        if let mixerNode = mixerNodes.removeValue(forKey: peerID) {
            engine.disconnectNodeOutput(mixerNode)
            engine.detach(mixerNode)
        }

        if wasRunning {
            try? engine.start()
        }

        ringBuffers.removeValue(forKey: peerID)
        sessionVolumes.removeValue(forKey: peerID)
        print("[audio] Removed session: \(peerID.prefix(8))")
    }

    func ringBuffer(for peerID: String) -> AudioRingBuffer? {
        ringBuffers[peerID]
    }

    // MARK: - Volume / Mix Mode

    func updateVolumes(activeSessionID: String?, gridSessionIDs: Set<String>,
                        allSessions: [SessionModel]) {
        for session in allSessions {
            let peerID = session.id
            guard let mixer = mixerNodes[peerID] else { continue }

            let targetVolume: Float
            switch mixMode {
            case .afv:   targetVolume = (peerID == activeSessionID) ? 1.0 : 0.0
            case .grid:  targetVolume = gridSessionIDs.contains(peerID) ? 1.0 : 0.0
            case .manual: targetVolume = sessionVolumes[peerID] ?? 1.0
            case .all:   targetVolume = 1.0
            }

            mixer.outputVolume = targetVolume
        }
    }

    func setSessionVolume(peerID: String, volume: Float) {
        sessionVolumes[peerID] = volume
        if mixMode == .manual, let mixer = mixerNodes[peerID] {
            mixer.outputVolume = volume
        }
    }
}
