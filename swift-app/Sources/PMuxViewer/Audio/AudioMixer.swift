/// AudioMixer — Multi-session audio engine with per-session volume and mix modes.
/// Uses AVAudioEngine with one AVAudioSourceNode per connected session.

import AVFoundation
import Foundation

enum AudioMixMode: String, CaseIterable, Identifiable {
    case afv     = "AfV"
    case grid    = "Grid"
    case manual  = "Manual"
    case all     = "All"

    var id: String { rawValue }

    var description: String {
        switch self {
        case .afv:    return "Audio follows active session"
        case .grid:   return "Mix all grid sessions"
        case .manual: return "Manual per-session volume"
        case .all:    return "All sessions at full volume"
        }
    }
}

@Observable
final class AudioMixer {
    var isRunning: Bool = false
    var mixMode: AudioMixMode = .afv
    var masterVolume: Float = 1.0 {
        didSet { engine.mainMixerNode.outputVolume = masterVolume }
    }

    /// Per-session volume (peerID → 0.0-1.0). Used in manual mode.
    var sessionVolumes: [String: Float] = [:]

    private let engine = AVAudioEngine()
    private let outputFormat: AVAudioFormat

    // Per-session nodes and buffers
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
            try engine.start()
            isRunning = true
            print("[audio] Engine started")
        } catch {
            print("[audio] Engine start failed: \(error)")
        }
    }

    func stop() {
        guard isRunning else { return }
        engine.stop()
        isRunning = false
        print("[audio] Engine stopped")
    }

    // MARK: - Session Management

    /// Add a session to the audio graph. Returns the ring buffer for poll callback writing.
    func addSession(peerID: String) -> AudioRingBuffer {
        if let existing = ringBuffers[peerID] {
            return existing
        }

        let ringBuffer = AudioRingBuffer(capacityFrames: 9600, maxLatencyFrames: 3600)
        ringBuffers[peerID] = ringBuffer

        // Create source node that pulls from ring buffer
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

            // Zero-fill remaining if we didn't have enough data
            if read < frames {
                memset(leftBuf.advanced(by: read), 0, (frames - read) * MemoryLayout<Float>.size)
                memset(rightBuf.advanced(by: read), 0, (frames - read) * MemoryLayout<Float>.size)
            }

            return noErr
        }

        // Per-session mixer node for individual volume control
        let mixerNode = AVAudioMixerNode()

        engine.attach(sourceNode)
        engine.attach(mixerNode)
        engine.connect(sourceNode, to: mixerNode, format: outputFormat)
        engine.connect(mixerNode, to: engine.mainMixerNode, format: outputFormat)

        sourceNodes[peerID] = sourceNode
        mixerNodes[peerID] = mixerNode

        // Default volume
        if sessionVolumes[peerID] == nil {
            sessionVolumes[peerID] = 1.0
        }

        print("[audio] Added session: \(peerID.prefix(8))")
        return ringBuffer
    }

    /// Remove a session from the audio graph.
    func removeSession(peerID: String) {
        if let sourceNode = sourceNodes.removeValue(forKey: peerID) {
            engine.disconnectNodeOutput(sourceNode)
            engine.detach(sourceNode)
        }
        if let mixerNode = mixerNodes.removeValue(forKey: peerID) {
            engine.disconnectNodeOutput(mixerNode)
            engine.detach(mixerNode)
        }
        ringBuffers.removeValue(forKey: peerID)
        sessionVolumes.removeValue(forKey: peerID)
        print("[audio] Removed session: \(peerID.prefix(8))")
    }

    /// Get ring buffer for a session (for polling).
    func ringBuffer(for peerID: String) -> AudioRingBuffer? {
        ringBuffers[peerID]
    }

    // MARK: - Volume / Mix Mode

    /// Update per-session volumes based on current mix mode and active/grid state.
    func updateVolumes(activeSessionID: String?, gridSessionIDs: Set<String>,
                        allSessions: [SessionModel]) {
        for session in allSessions {
            let peerID = session.id
            guard let mixer = mixerNodes[peerID] else { continue }

            let targetVolume: Float
            switch mixMode {
            case .afv:
                targetVolume = (peerID == activeSessionID) ? 1.0 : 0.0

            case .grid:
                targetVolume = gridSessionIDs.contains(peerID) ? 1.0 : 0.0

            case .manual:
                targetVolume = sessionVolumes[peerID] ?? 1.0

            case .all:
                targetVolume = 1.0
            }

            // Ramp volume to avoid clicks (10ms ramp)
            mixer.outputVolume = targetVolume
        }
    }

    /// Set volume for a specific session (manual mode).
    func setSessionVolume(peerID: String, volume: Float) {
        sessionVolumes[peerID] = volume
        if mixMode == .manual, let mixer = mixerNodes[peerID] {
            mixer.outputVolume = volume
        }
    }
}
