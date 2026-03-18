/// SessionManager — Orchestrates session connections, switching, health, and input.
/// Owns dynamic ParsecClient pool and mutates AppState.

import AppKit
import SwiftUI
import CParsecBridge

private let MAX_SESSIONS = 9
private let GRID_MAX = 4
private let RECONNECT_DELAY_BASE: TimeInterval = 3.0
private let STAGGER_DELAY: TimeInterval = 2.5
private let HOST_REFRESH_INTERVAL: TimeInterval = 30.0

@Observable
final class SessionManager: InputViewDelegate {
    let appState: AppState
    private(set) var metalContext: MetalContext?

    // Dynamic client pool (up to 9, allocated on demand)
    private var clientPool: [Int: ParsecClient] = [:]  // portOffset -> client
    private var usedPorts: Set<Int> = []

    // Clipboard
    private var lastPasteboardCount: Int = 0

    private var sessionToken = ""
    private var sdkPath: String = ""
    private let apiClient = ParsecAPIClient()
    private let favoritesManager = FavoritesManager()

    // Audio
    private(set) var audioMixer: AudioMixer?

    private var eventTimer: Timer?
    private var audioQueue: DispatchQueue?
    private var audioPolling = false
    private var healthTimer: Timer?
    private var staggerTimer: Timer?
    private var refreshTimer: Timer?
    private var staggerIndex: Int = 0

    var activeInputView: ParsecInputView? {
        didSet {
            if let view = activeInputView {
                view.window?.makeFirstResponder(view)
            }
        }
    }

    init(appState: AppState) {
        self.appState = appState
    }

    // MARK: - Bootstrap

    func bootstrap() {
        findSDK()
        loadAuth()

        do {
            metalContext = try MetalContext()
            print("[metal] Pipelines created (NV12 GPU decode)")
        } catch {
            print("[metal] MetalContext init failed: \(error)")
        }

        // Load favorites and create sessions
        let favs = favoritesManager.load()
        appState.favorites = favs

        for (peerID, entry) in favs.sorted(by: { $0.value.slot < $1.value.slot }) {
            guard let (client, portOffset) = try? allocateClient() else { continue }
            var quality = ParsecClient.Quality()
            if let h265 = entry.settings["h265"] as? Bool { quality.h265 = h265 }
            if let c444 = entry.settings["color_444"] as? Bool { quality.color444 = c444 }

            let session = SessionModel(peerID: peerID, nickname: entry.nickname,
                                       slot: entry.slot, quality: quality)
            session.client = client
            session.clientIndex = portOffset
            session.isFavorite = true
            appState.sessions.append(session)
        }

        // Clipboard: snapshot current pasteboard count so we don't echo on startup
        lastPasteboardCount = NSPasteboard.general.changeCount

        // Audio mixer
        audioMixer = AudioMixer()
        if appState.audioEnabled {
            audioMixer?.start()
            print("[pmux] Audio enabled")
        } else {
            print("[pmux] Audio disabled (enable in Settings)")
        }

        appState.isBootstrapped = true
        print("[pmux] Viewer running")

        // Fetch hosts async
        Task { await fetchHosts() }
        startHostRefresh()
    }

    func startConnections() {
        guard !appState.sessions.isEmpty && !sessionToken.isEmpty else { return }

        // Invalidate existing timers before creating new ones
        eventTimer?.invalidate()
        audioPolling = false
        healthTimer?.invalidate()
        staggerTimer?.invalidate()

        if appState.sessions.count > 0 {
            appState.activeSessionIndex = 0
        }
        startStaggeredConnect()

        eventTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.pollEventsSafe()
        }

        // Audio polling at 100Hz (10ms) — needs to be faster than event polling
        // to keep the ring buffer fed without underruns
        audioQueue = DispatchQueue(label: "com.pmux.audio-poll", qos: .userInteractive)
        audioPolling = true
        audioQueue?.async { [weak self] in self?.audioPollingLoop() }

        // Health monitoring — poll metrics every second
        healthTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.checkAllHealth()
        }
    }

    private func audioPollingLoop() {
        while audioPolling {
            pollAudioForAllSessions()
            Thread.sleep(forTimeInterval: 0.01) // 100Hz
        }
    }

    // MARK: - Health Monitoring

    private func checkAllHealth() {
        for (i, session) in appState.sessions.enumerated() {
            guard session.isConnected, let client = session.client else { continue }

            let (code, status) = client.getStatus()

            if code < 0 {
                // Connection lost
                session.isConnected = false
                session.health = .lost
                session.lostAt = CFAbsoluteTimeGetCurrent()
                print("[pmux] Lost \(session.nickname) (\(code))")
                continue
            }

            let metrics = status.`self`.metrics.0
            session.latency = metrics.networkLatency
            session.bitrate = metrics.bitrate
            session.encodeLatency = metrics.encodeLatency
            session.decodeLatency = metrics.decodeLatency
            session.queuedFrames = metrics.queuedFrames

            if status.networkFailure {
                session.netFailCount += 1
            } else {
                session.netFailCount = 0
            }

            if session.netFailCount >= 5 {
                session.health = .lost
                client.disconnect()
                session.isConnected = false
                session.lostAt = CFAbsoluteTimeGetCurrent()
                session.netFailCount = 0
            } else if session.latency > 150 || session.queuedFrames > 10 {
                session.health = .bad
            } else if session.latency > 60 || session.queuedFrames > 3 {
                session.health = .degraded
            } else {
                session.health = .ok
            }
        }
    }

    func shutdown() {
        eventTimer?.invalidate()
        audioPolling = false
        healthTimer?.invalidate()
        staggerTimer?.invalidate()
        refreshTimer?.invalidate()
        for session in appState.sessions {
            if session.isConnected, let client = session.client { client.disconnect() }
            audioMixer?.removeSession(peerID: session.id)
        }
        audioMixer?.stop()
        clientPool.removeAll()
        usedPorts.removeAll()
        print("[pmux] Shutdown complete")
    }

    // MARK: - Dynamic Client Pool

    private func allocateClient() throws -> (ParsecClient, Int) {
        for portOffset in 0..<MAX_SESSIONS {
            if !usedPorts.contains(portOffset) {
                let port = UInt16(13000 + portOffset)
                let client = try ParsecClient(sdkPath: sdkPath, clientPort: port)

                client.setLogCallback({ level, msg, _ in
                    guard let msg = msg else { return }
                    let s = String(cString: msg)
                    if s.contains("signal_") || s.contains("bud_") || s.contains("nat_read") { return }
                    let tag = level.rawValue == 0x0069 ? "I" : "D"
                    print("[\(tag)] \(s)")
                })

                clientPool[portOffset] = client
                usedPorts.insert(portOffset)
                print("[pmux] Allocated client on port \(port)")
                return (client, portOffset)
            }
        }
        throw ClientPoolError.noFreePorts
    }

    private func releaseClient(portOffset: Int) {
        if let client = clientPool[portOffset] {
            client.disconnect()
        }
        clientPool.removeValue(forKey: portOffset)
        usedPorts.remove(portOffset)
        // Find and remove any session using this port from audio
        for session in appState.sessions where session.clientIndex == portOffset {
            audioMixer?.removeSession(peerID: session.id)
        }
        print("[pmux] Released client on port \(13000 + portOffset)")
    }

    enum ClientPoolError: Error, LocalizedError {
        case noFreePorts
        var errorDescription: String? { "All 9 session slots are in use" }
    }

    // MARK: - Host Fetching

    func fetchHosts() async {
        guard !sessionToken.isEmpty else { return }
        await MainActor.run {
            appState.isLoadingHosts = true
            appState.hostLoadError = nil
        }

        do {
            let hosts = try await apiClient.fetchHosts(sessionToken: sessionToken)
            await MainActor.run {
                appState.allHosts = hosts

                // Update online status for existing favorite sessions
                let hostMap = Dictionary(hosts.map { ($0.peerID, $0) }, uniquingKeysWith: { a, _ in a })
                for session in appState.sessions {
                    if let host = hostMap[session.id] {
                        // Update name from API if different
                        if session.nickname == session.id {
                            session.nickname = host.name
                        }
                    }
                }

                print("[pmux] Fetched \(hosts.count) hosts (\(hosts.filter(\.online).count) online)")
            }
        } catch {
            await MainActor.run {
                appState.hostLoadError = error.localizedDescription
                print("[pmux] Host fetch failed: \(error)")
            }
        }

        await MainActor.run {
            appState.isLoadingHosts = false
        }
    }

    private func startHostRefresh() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: HOST_REFRESH_INTERVAL, repeats: true) { [weak self] _ in
            Task { await self?.fetchHosts() }
        }
    }

    // MARK: - Favorites CRUD

    func addToFavorites(host: ParsecHost) {
        guard appState.favorites[host.peerID] == nil else { return }
        guard let slot = favoritesManager.nextAvailableSlot(favorites: appState.favorites) else {
            print("[pmux] No free slots (max 9)")
            return
        }

        // Save to disk
        favoritesManager.addFavorite(favorites: &appState.favorites,
                                      peerID: host.peerID, nickname: host.name, slot: slot)

        // Check if already a session (ad-hoc connection)
        if let existingIdx = appState.sessions.firstIndex(where: { $0.id == host.peerID }) {
            appState.sessions[existingIdx].isFavorite = true
            appState.sessions[existingIdx].slot = slot
            appState.sessions[existingIdx].nickname = host.name
            print("[pmux] Promoted ad-hoc session to favorite: \(host.name) [F\(slot)]")
            return
        }

        // Create new session
        guard let (client, portOffset) = try? allocateClient() else {
            print("[pmux] Failed to allocate client for favorite")
            return
        }

        let session = SessionModel(peerID: host.peerID, nickname: host.name,
                                   slot: slot, quality: .init())
        session.client = client
        session.clientIndex = portOffset
        session.isFavorite = true
        appState.sessions.append(session)

        print("[pmux] Added favorite: \(host.name) [F\(slot)]")
    }

    func removeFromFavorites(peerID: String) {
        // Remove from disk
        favoritesManager.removeFavorite(favorites: &appState.favorites, peerID: peerID)

        // Find session
        guard let idx = appState.sessions.firstIndex(where: { $0.id == peerID }) else { return }
        let session = appState.sessions[idx]

        if session.isConnected {
            // Keep as ad-hoc (connected but not favorite)
            session.isFavorite = false
            session.slot = 0
            print("[pmux] Unfavorited \(session.nickname) (still connected)")
        } else {
            // Remove entirely
            releaseClient(portOffset: session.clientIndex)
            appState.sessions.remove(at: idx)

            // Fix activeSessionIndex
            if appState.activeSessionIndex >= appState.sessions.count {
                appState.activeSessionIndex = max(0, appState.sessions.count - 1)
            }
            print("[pmux] Removed favorite: \(session.nickname)")
        }
    }

    func assignSlot(peerID: String, newSlot: Int) {
        // Clear any existing session using this slot
        for session in appState.sessions where session.slot == newSlot && session.id != peerID {
            session.slot = 0
            favoritesManager.updateSlot(favorites: &appState.favorites,
                                         peerID: session.id, newSlot: 0)
        }

        // Assign to target
        if let session = appState.sessions.first(where: { $0.id == peerID }) {
            session.slot = newSlot
        }
        favoritesManager.updateSlot(favorites: &appState.favorites,
                                     peerID: peerID, newSlot: newSlot)
        print("[pmux] Assigned F\(newSlot) to \(peerID.prefix(8))")
    }

    // MARK: - Connect Any Host

    func connectHost(peerID: String) {
        // Already a session?
        if let idx = appState.sessions.firstIndex(where: { $0.id == peerID }) {
            switchToSession(index: idx)
            return
        }

        // Find host info
        guard let host = appState.allHosts.first(where: { $0.peerID == peerID }) else {
            print("[pmux] Host not found: \(peerID.prefix(12))")
            return
        }

        guard host.online else {
            print("[pmux] Host is offline: \(host.name)")
            return
        }

        // Allocate client and create ad-hoc session
        guard let (client, portOffset) = try? allocateClient() else {
            print("[pmux] No free client slots")
            return
        }

        let session = SessionModel(peerID: host.peerID, nickname: host.name,
                                   slot: 0, quality: .init())
        session.client = client
        session.clientIndex = portOffset
        session.isFavorite = false
        appState.sessions.append(session)

        let idx = appState.sessions.count - 1
        switchToSession(index: idx)
    }

    // MARK: - SDK / Auth

    private func findSDK() {
        if let fw = Bundle.main.privateFrameworksPath,
           FileManager.default.fileExists(atPath: fw + "/libparsec.dylib") {
            sdkPath = fw + "/libparsec.dylib"
        } else {
            let execDir = Bundle.main.executableURL?.deletingLastPathComponent().path ?? "."
            let candidates = [
                execDir + "/../Frameworks/libparsec.dylib",
                "Sources/CParsecBridge/include/libparsec-x86_64.dylib",
                "Sources/CParsecBridge/include/libparsec.dylib",
                NSHomeDirectory() + "/parsec-mux/swift-app/Sources/CParsecBridge/include/libparsec.dylib"
            ]
            sdkPath = candidates.first { FileManager.default.fileExists(atPath: $0) }
                ?? "Sources/CParsecBridge/include/libparsec.dylib"
        }
        print("[pmux] SDK path: \(sdkPath)")
    }

    private func loadAuth() {
        if let token = SessionAuth.getSessionToken() {
            sessionToken = token
            print("[pmux] Session token loaded")
        } else {
            print("[pmux] No session token found!")
            let alert = NSAlert()
            alert.messageText = "No Session"
            alert.informativeText = "Could not find a Parsec session.\n\n" +
                "Either:\n- Run 'pmux' first\n- Log into the Parsec app\n- Set PARSEC_SESSION_ID env var"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    // MARK: - Staggered Connect

    private func startStaggeredConnect() {
        staggerIndex = 0
        connectNextSession()
    }

    private func connectNextSession() {
        guard staggerIndex < appState.sessions.count else { return }
        let idx = staggerIndex
        staggerIndex += 1

        if appState.sessions[idx].slot > 0 {
            connectSession(index: idx)
        }

        staggerTimer = Timer.scheduledTimer(withTimeInterval: STAGGER_DELAY, repeats: false) { [weak self] _ in
            self?.connectNextSession()
        }
    }

    // MARK: - Connection

    func connectSession(index: Int) {
        guard index < appState.sessions.count else { return }
        let session = appState.sessions[index]
        guard let client = session.client else { return }

        if session.isConnected || session.isConnecting { return }

        session.isConnecting = true
        print("[pmux] Connecting to \(session.nickname) (\(session.id.prefix(12))...)...")

        do {
            try client.connect(sessionID: sessionToken, peerID: session.id,
                               quality: session.quality)
            session.isConnected = true
            session.isConnecting = false
            session.health = .ok
            session.netFailCount = 0
            session.retries = 0
            session.isReconnecting = false

            client.enableStream(1, enable: true)

            // Add to audio mixer (only if audio is enabled and running)
            if let mixer = audioMixer, appState.audioEnabled {
                // Flush stale SDK audio before hooking up
                for _ in 0..<50 {
                    let s = pmux_poll_audio(client.dsoHandle, { _, _, _ in }, 0, nil)
                    if s != 0 { break }
                }
                let _ = mixer.addSession(peerID: session.id)
                updateAudioVolumes()
            }

            print("[pmux] Connected to \(session.nickname)")
        } catch {
            print("[pmux] Connect failed for \(session.nickname): \(error)")
            session.isConnecting = false
        }
    }

    func disconnectSession(index: Int) {
        guard index < appState.sessions.count else { return }
        let session = appState.sessions[index]
        guard session.isConnected, let client = session.client else { return }

        client.disconnect()
        session.isConnected = false
        session.health = .ok
        session.netFailCount = 0
        session.lostAt = 0
        session.retries = 0
        session.isReconnecting = false

        // Remove from audio mixer
        audioMixer?.removeSession(peerID: session.id)

        print("[pmux] Disconnected \(session.nickname)")

        // If ad-hoc (not favorite), remove the session entirely
        if !session.isFavorite {
            releaseClient(portOffset: session.clientIndex)
            appState.sessions.remove(at: index)
            appState.gridIndices = appState.gridIndices.compactMap { gi in
                if gi == index { return nil }
                return gi > index ? gi - 1 : gi
            }
            if appState.activeSessionIndex >= appState.sessions.count {
                appState.activeSessionIndex = max(0, appState.sessions.count - 1)
            }
        }
    }

    // MARK: - Session Switching

    func switchToSession(index: Int) {
        guard index >= 0 && index < appState.sessions.count else { return }
        if index == appState.activeSessionIndex && appState.sessions[index].isConnected { return }

        appState.activeSessionIndex = index

        if !appState.sessions[index].isConnected && !appState.sessions[index].isConnecting {
            connectSession(index: index)
        }

        print("[pmux] Focus -> \(appState.sessions[index].nickname)")
        restoreFocus()
        updateAudioVolumes()
    }

    // MARK: - Mode Switching

    func enterGridMode() {
        appState.viewMode = .grid
        // If grid is empty, populate with all connected sessions
        if appState.gridIndices.isEmpty {
            appState.gridIndices = appState.sessions.enumerated()
                .filter { $0.element.isConnected }
                .map { $0.offset }
        }
        print("[pmux] Grid mode: \(appState.gridIndices.count) panes")
        updateAudioVolumes()
    }

    func enterSingleMode() {
        guard appState.viewMode != .single else { return }
        appState.viewMode = .single
        print("[pmux] Single mode: \(appState.activeSession?.nickname ?? "none")")
        updateAudioVolumes()
    }

    func toggleGrid() {
        if appState.viewMode == .single { enterGridMode() } else { enterSingleMode() }
    }

    /// Add a session to the grid by index. Auto-enters grid mode if needed.
    func addToGrid(sessionIndex: Int) {
        guard sessionIndex >= 0 && sessionIndex < appState.sessions.count else { return }
        // If in single mode, also add the current active session so we get 2 panes immediately
        if appState.viewMode == .single {
            let active = appState.activeSessionIndex
            if active >= 0 && active < appState.sessions.count && active != sessionIndex {
                if !appState.gridIndices.contains(active) {
                    appState.gridIndices.append(active)
                }
            }
            appState.viewMode = .grid
        }
        if !appState.gridIndices.contains(sessionIndex) {
            appState.gridIndices.append(sessionIndex)
        }
        // Connect if not already
        if !appState.sessions[sessionIndex].isConnected && !appState.sessions[sessionIndex].isConnecting {
            connectSession(index: sessionIndex)
        }
        print("[pmux] Added to grid: \(appState.sessions[sessionIndex].nickname) (\(appState.gridIndices.count) panes)")
        updateAudioVolumes()
    }

    /// Add a host to the grid by peerID — connects if needed, creates session if needed.
    func addHostToGrid(peerID: String) {
        if let idx = appState.sessions.firstIndex(where: { $0.id == peerID }) {
            addToGrid(sessionIndex: idx)
        } else {
            // Connect ad-hoc, then add to grid
            connectHost(peerID: peerID)
            if let idx = appState.sessions.firstIndex(where: { $0.id == peerID }) {
                addToGrid(sessionIndex: idx)
            }
        }
    }

    /// Remove a session from the grid (doesn't disconnect).
    func removeFromGrid(sessionIndex: Int) {
        appState.gridIndices.removeAll { $0 == sessionIndex }
        // If grid is now empty or 1, go to single mode
        if appState.gridIndices.count <= 1 {
            if let remaining = appState.gridIndices.first {
                appState.activeSessionIndex = remaining
            }
            appState.gridIndices = []
            appState.viewMode = .single
        }
        updateAudioVolumes()
    }

    // MARK: - Grid Arrow Navigation

    private func handleGridArrow(_ direction: ArrowDirection) {
        let gridIndices = appState.gridIndices
        let cols = appState.gridMode.layout(for: gridIndices.count).cols
        guard let fgi = gridIndices.firstIndex(of: appState.activeSessionIndex) else { return }

        let col = fgi % cols, row = fgi / cols
        var ngi = -1

        switch direction {
        case .left:  if col > 0 { ngi = row * cols + (col - 1) }
        case .right: if (row * cols + col + 1) < gridIndices.count { ngi = row * cols + (col + 1) }
        case .up:    if row > 0 { ngi = (row - 1) * cols + col }
        case .down:  if ((row + 1) * cols + col) < gridIndices.count { ngi = (row + 1) * cols + col }
        }

        if ngi >= 0 && ngi < gridIndices.count {
            appState.activeSessionIndex = gridIndices[ngi]
            print("[pmux] Grid -> \(appState.sessions[appState.activeSessionIndex].nickname)")
            restoreFocus()
        }
    }

    // MARK: - Quality

    func applyQuality(sessionIndex: Int, quality: ParsecClient.Quality) {
        guard sessionIndex >= 0 && sessionIndex < appState.sessions.count else { return }
        appState.sessions[sessionIndex].quality = quality
        print("[pmux] Quality applied: \(quality.h265 ? "H.265" : "H.264") \(quality.color444 ? "4:4:4" : "4:2:0") \(quality.decoderIndex == 1 ? "HW" : "SW")")

        let peerID = appState.sessions[sessionIndex].id
        disconnectSession(index: sessionIndex)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, let idx = self.appState.sessions.firstIndex(where: { $0.id == peerID }) else { return }
            self.connectSession(index: idx)
        }
    }

    // MARK: - Quality Picker Keyboard Handling

    private func handleQualityPickerKey(keyCode: UInt16, characters: String?) {
        switch keyCode {
        case 0x35: appState.activeOverlay = .none
        case 0x7E:
            if let raw = QualityField(rawValue: appState.qualityEditField.rawValue - 1) {
                appState.qualityEditField = raw
            }
        case 0x7D:
            if let raw = QualityField(rawValue: appState.qualityEditField.rawValue + 1) {
                appState.qualityEditField = raw
            }
        case 0x7B, 0x7C:
            let dir: Int = keyCode == 0x7C ? 1 : -1
            switch appState.qualityEditField {
            case .resolution:
                var ci = 0
                for (i, p) in resPresets.enumerated() {
                    if p.w == appState.qualityEditValue.resX && p.h == appState.qualityEditValue.resY { ci = i; break }
                }
                ci = (ci + dir + resPresets.count) % resPresets.count
                appState.qualityEditValue.resX = resPresets[ci].w
                appState.qualityEditValue.resY = resPresets[ci].h
            case .codec: appState.qualityEditValue.h265.toggle()
            case .color: appState.qualityEditValue.color444.toggle()
            case .decoder: appState.qualityEditValue.decoderIndex = appState.qualityEditValue.decoderIndex == 1 ? 0 : 1
            }
        case 0x24, 0x4C:
            let a = appState.activeSessionIndex
            if a >= 0 && a < appState.sessions.count {
                applyQuality(sessionIndex: a, quality: appState.qualityEditValue)
            }
            appState.activeOverlay = .none
        default: break
        }
    }

    // MARK: - Event Polling

    func pollEventsSafe() {
        for (i, session) in appState.sessions.enumerated() {
            guard session.isConnected, let client = session.client else { continue }

            while let event = client.pollEvents() {
                if i == appState.activeSessionIndex {
                    switch event.type {
                    case CLIENT_EVENT_CURSOR:
                        let cursor = event.cursor.cursor
                        let wantRelative = cursor.relative
                        print("[cursor] session=\(session.nickname) relative=\(wantRelative) activeInput=\(activeInputView != nil)")
                        // Store on session model so new InputViews inherit it
                        session.isRelativeMode = wantRelative
                        if let inputView = activeInputView {
                            if wantRelative && !inputView.isRelativeMode {
                                inputView.isRelativeMode = true
                                NSCursor.hide()
                                CGAssociateMouseAndMouseCursorPosition(0)
                            } else if !wantRelative && inputView.isRelativeMode {
                                inputView.isRelativeMode = false
                                CGAssociateMouseAndMouseCursorPosition(1)
                                NSCursor.unhide()
                            }
                        }

                    case CLIENT_EVENT_USER_DATA:
                        // Clipboard from remote (user data id 7)
                        // NOTE: getBuffer/freeBuffer can crash due to malloc zone
                        // mismatch (SDK dylib vs Swift runtime). Copy data immediately
                        // and skip freeBuffer — small leak is preferable to crash.
                        if event.userData.id == 7 {
                            if let buf = client.getBuffer(key: event.userData.key) {
                                let text = String(cString: buf.assumingMemoryBound(to: CChar.self))
                                if !text.isEmpty {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(text, forType: .string)
                                    lastPasteboardCount = NSPasteboard.general.changeCount
                                    print("[pmux] Clipboard received from remote (\(text.count) chars)")
                                }
                                // Skip freeBuffer — crashes under Rosetta and some ARM64
                                // SDK builds due to malloc zone mismatch.
                                // client.freeBuffer(buf)
                            }
                        }

                    default:
                        break
                    }
                }
            }
        }

        // Local→Remote clipboard: check if pasteboard changed
        pollLocalClipboard()
    }

    /// Monitor local pasteboard and send changes to the active remote session.
    private func pollLocalClipboard() {
        let currentCount = NSPasteboard.general.changeCount
        guard currentCount != lastPasteboardCount else { return }
        lastPasteboardCount = currentCount

        // Only send if we have an active connected session
        let idx = appState.activeSessionIndex
        guard idx >= 0 && idx < appState.sessions.count,
              appState.sessions[idx].isConnected,
              let client = appState.sessions[idx].client else { return }

        if let text = NSPasteboard.general.string(forType: .string), !text.isEmpty {
            client.sendClipboard(text)
            print("[pmux] Clipboard sent to remote (\(text.count) chars)")
        }
    }

    // MARK: - Audio

    private func pollAudioForAllSessions() {
        guard let mixer = audioMixer, mixer.isRunning else { return }
        for session in appState.sessions {
            guard session.isConnected, let client = session.client else { continue }
            guard let ringBuffer = mixer.ringBuffer(for: session.id) else { continue }

            let bufPtr = Unmanaged.passUnretained(ringBuffer).toOpaque()
            // Drain ALL buffered audio packets (not just one)
            var maxPolls = 20  // safety limit
            while maxPolls > 0 {
                let status = pmux_poll_audio(client.dsoHandle, { pcm, frames, opaque in
                    guard let pcm = pcm, let opaque = opaque else { return }
                    let rb = Unmanaged<AudioRingBuffer>.fromOpaque(opaque).takeUnretainedValue()
                    rb.write(pcm: pcm, frameCount: Int(frames))
                }, 0, bufPtr)
                if status != 0 { break }  // no more audio
                maxPolls -= 1
            }
        }
    }

    func updateAudioVolumes() {
        guard let mixer = audioMixer else { return }
        let activeID = appState.activeSession?.id
        let gridIDs = Set(appState.gridIndices.compactMap { idx -> String? in
            guard idx >= 0 && idx < appState.sessions.count else { return nil }
            return appState.sessions[idx].id
        })
        mixer.updateVolumes(activeSessionID: activeID, gridSessionIDs: gridIDs,
                             allSessions: appState.sessions)
    }

    func toggleAudio(enabled: Bool) {
        appState.audioEnabled = enabled
        if enabled {
            audioMixer?.start()
            // Add existing connected sessions
            for session in appState.sessions where session.isConnected {
                let _ = audioMixer?.addSession(peerID: session.id)
            }
            updateAudioVolumes()
            print("[pmux] Audio enabled")
        } else {
            audioMixer?.stop()
            print("[pmux] Audio disabled")
        }
    }

    // MARK: - Focus Management

    func restoreFocus() {
        if let view = activeInputView {
            view.window?.makeFirstResponder(view)
        }
    }

    // MARK: - InputViewDelegate

    func inputView(_ view: ParsecInputView, didRequestSwitchToSlot slot: Int) {
        guard let idx = appState.sessions.firstIndex(where: { $0.slot == slot }) else {
            print("[pmux] No session assigned to slot F\(slot)")
            return
        }
        if idx == appState.activeSessionIndex && appState.sessions[idx].isConnected {
            return
        }
        print("[pmux] Switching to F\(slot): \(appState.sessions[idx].nickname)")
        switchToSession(index: idx)
    }

    func inputView(_ view: ParsecInputView, didFireCombo action: ComboAction) {
        switch action {
        case .toggleGrid: toggleGrid()
        case .toggleDebug:
            appState.showDebug.toggle()
            print("[pmux] Debug overlay: \(appState.showDebug ? "ON" : "OFF")")
        case .toggleSidebar:
            withAnimation(.easeInOut(duration: 0.2)) {
                appState.sidebarVisible.toggle()
            }
            print("[pmux] Sidebar: \(appState.sidebarVisible ? "ON" : "OFF")")
        case .openQualityPicker:
            if let session = appState.activeSession {
                appState.qualityEditValue = session.quality
                appState.qualityEditField = .resolution
                appState.activeOverlay = .qualityPicker
            }
        case .prevSession:
            guard !appState.sessions.isEmpty else { return }
            switchToSession(index: (appState.activeSessionIndex - 1 + appState.sessions.count) % appState.sessions.count)
        case .nextSession:
            guard !appState.sessions.isEmpty else { return }
            switchToSession(index: (appState.activeSessionIndex + 1) % appState.sessions.count)
        case .disconnect:
            if appState.activeSessionIndex >= 0 && appState.activeSessionIndex < appState.sessions.count {
                disconnectSession(index: appState.activeSessionIndex)
            }
        case .reconnect:
            let i = appState.activeSessionIndex
            if i >= 0 && i < appState.sessions.count && !appState.sessions[i].isConnected {
                connectSession(index: i)
            }
        case .forceSingleMode:
            if appState.viewMode == .grid { enterSingleMode() }
        case .gridArrow(let direction):
            if appState.viewMode == .grid && appState.gridIndices.count > 1 {
                handleGridArrow(direction)
            }
        }
    }

    func inputViewShouldConsumeKeyForOverlay(_ view: ParsecInputView, keyCode: UInt16, isDown: Bool, characters: String?) -> Bool {
        if appState.activeOverlay == .qualityPicker {
            if isDown { handleQualityPickerKey(keyCode: keyCode, characters: characters) }
            return true
        }
        return false
    }
}
