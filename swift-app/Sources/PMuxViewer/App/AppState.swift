/// AppState — @Observable application state.
/// Single source of truth for all UI-facing state.

import Foundation
import SwiftUI

// MARK: - Enums

enum ViewMode: Equatable { case single, grid }

enum GridMode: String, CaseIterable, Identifiable {
    case auto  = "Auto"
    case g1x2  = "1×2"
    case g2x1  = "2×1"
    case g2x2  = "2×2"
    case g1x3  = "1×3"
    case g3x1  = "3×1"
    case g2x3  = "2×3"
    case g3x3  = "3×3"

    var id: String { rawValue }

    /// Fixed cols/rows, nil for auto
    var fixedLayout: (cols: Int, rows: Int)? {
        switch self {
        case .auto: return nil
        case .g1x2: return (2, 1)
        case .g2x1: return (1, 2)
        case .g2x2: return (2, 2)
        case .g1x3: return (3, 1)
        case .g3x1: return (1, 3)
        case .g2x3: return (3, 2)
        case .g3x3: return (3, 3)
        }
    }

    var icon: String {
        switch self {
        case .auto: return "rectangle.3.group"
        case .g1x2: return "rectangle.split.2x1"
        case .g2x1: return "rectangle.split.1x2"
        case .g2x2: return "rectangle.split.2x2"
        case .g1x3: return "rectangle.split.3x1"
        case .g3x1: return "rectangle.split.1x2"
        case .g2x3: return "rectangle.split.3x3"
        case .g3x3: return "rectangle.split.3x3"
        }
    }

    /// Resolve actual cols/rows for a given session count.
    func layout(for count: Int) -> (cols: Int, rows: Int) {
        if let fixed = fixedLayout { return fixed }
        // Auto: optimize for widescreen
        switch count {
        case 0, 1: return (1, 1)
        case 2:    return (2, 1)
        case 3:    return (2, 2)
        case 4:    return (2, 2)
        case 5, 6: return (3, 2)
        case 7...9: return (3, 3)
        default:   return (3, 3)
        }
    }
}

/// Drag-and-drop transfer type for host peerIDs
struct HostTransfer: Codable, Transferable {
    let peerID: String
    let name: String

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .plainText)
    }
}

enum ActiveOverlay: Equatable {
    case none, qualityPicker, settings, audioMixer
}

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
    var isRelativeMode: Bool = false
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
    var gridMode: GridMode = .auto
    var gridIndices: [Int] = []

    var showDebug: Bool = false
    var sidebarVisible: Bool = true
    var activeOverlay: ActiveOverlay = .none
    var qualityEditField: QualityField = .resolution
    var qualityEditValue: ParsecClient.Quality = .init()

    var isBootstrapped: Bool = false

    // Settings
    var autoConnectOnLaunch: Bool = true
    var autoReconnect: Bool = true
    var defaultH265: Bool = false
    var defaultColor444: Bool = false
    var defaultHWDecode: Bool = true
    var audioEnabled: Bool = true

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
