/// AppState — @Observable application state.
/// Single source of truth for all UI-facing state.

import Foundation
import SwiftUI

// MARK: - Enums

enum ViewMode: Equatable { case single, grid }

enum HealthState: Int {
    case ok = 0, degraded, bad, lost
    var icon: String {
        switch self { case .ok: return "●"; case .degraded: return "◐"; case .bad: return "!"; case .lost: return "○" }
    }
    var color: Color {
        switch self {
        case .ok:       return PMuxColors.Status.ok
        case .degraded: return PMuxColors.Status.degraded
        case .bad:      return PMuxColors.Status.bad
        case .lost:     return PMuxColors.Status.lost
        }
    }
    var dotState: StatusDot.StatusDotState {
        switch self {
        case .ok:       return .ok
        case .degraded: return .degraded
        case .bad:      return .bad
        case .lost:     return .lost
        }
    }
}

enum QualityField: Int, CaseIterable { case resolution = 0, codec, color, decoder }

let resPresets: [(w: Int32, h: Int32, label: String)] = [
    (0, 0, "Native"), (1280, 720, "720p"), (1920, 1080, "1080p"),
    (2560, 1440, "1440p"), (3840, 2160, "4K"),
]

// MARK: - Session Model

@Observable
final class SessionModel: Identifiable {
    let id: String  // peerID
    var nickname: String
    var slot: Int
    var isConnected: Bool = false
    var isConnecting: Bool = false
    var health: HealthState = .ok
    var latency: Float = 0
    var bitrate: Float = 0
    var encodeLatency: Float = 0
    var decodeLatency: Float = 0
    var queuedFrames: UInt32 = 0
    var netFailCount: Int = 0
    var lostAt: CFAbsoluteTime = 0
    var retries: Int = 0
    var isReconnecting: Bool = false
    var quality: ParsecClient.Quality

    var isFavorite: Bool = true
    weak var client: ParsecClient?
    var clientIndex: Int = 0

    init(peerID: String, nickname: String, slot: Int, quality: ParsecClient.Quality = .init()) {
        self.id = peerID
        self.nickname = nickname
        self.slot = slot
        self.quality = quality
    }
}

// MARK: - App State

@Observable
final class AppState {
    var sessions: [SessionModel] = []
    var activeSessionIndex: Int = 0
    var viewMode: ViewMode = .single
    var gridIndices: [Int] = []

    var showDebug: Bool = false
    var sidebarVisible: Bool = true
    var showQualityPicker: Bool = false
    var showSettings: Bool = false
    var qualityEditField: QualityField = .resolution
    var qualityEditValue: ParsecClient.Quality = .init()

    var isBootstrapped: Bool = false

    // Settings
    var autoConnectOnLaunch: Bool = true
    var autoReconnect: Bool = true
    var defaultH265: Bool = false
    var defaultColor444: Bool = false
    var defaultHWDecode: Bool = true
    var audioEnabled: Bool = false
    var showAudioMixer: Bool = false

    // Host browser
    var allHosts: [ParsecHost] = []
    var isLoadingHosts: Bool = false
    var hostLoadError: String? = nil
    var favorites: [String: FavoriteEntry] = [:]
    var sidebarSearch: String = ""

    var activeSession: SessionModel? {
        guard activeSessionIndex >= 0 && activeSessionIndex < sessions.count else { return nil }
        return sessions[activeSessionIndex]
    }

    var connectedSessions: [SessionModel] {
        sessions.filter { $0.isConnected }
    }

    var gridSessions: [SessionModel] {
        gridIndices.compactMap { idx in
            guard idx >= 0 && idx < sessions.count else { return nil }
            return sessions[idx]
        }
    }

    /// Favorite sessions sorted by slot
    var favoriteSessions: [SessionModel] {
        sessions.filter(\.isFavorite).sorted { $0.slot < $1.slot }
    }

    /// Hosts from API that are NOT in favorites, online first
    var availableHosts: [ParsecHost] {
        let favPeerIDs = Set(favorites.keys)
        let filtered = allHosts.filter { !favPeerIDs.contains($0.peerID) }
        if sidebarSearch.isEmpty {
            return filtered.sorted { $0.online && !$1.online }
        }
        let query = sidebarSearch.lowercased()
        return filtered
            .filter { $0.name.lowercased().contains(query) || $0.userName.lowercased().contains(query) }
            .sorted { $0.online && !$1.online }
    }

    /// Filtered favorite sessions for sidebar search
    var filteredFavorites: [SessionModel] {
        if sidebarSearch.isEmpty { return favoriteSessions }
        let query = sidebarSearch.lowercased()
        return favoriteSessions.filter { $0.nickname.lowercased().contains(query) }
    }
}
