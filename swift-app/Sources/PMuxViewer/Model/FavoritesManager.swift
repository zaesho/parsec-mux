/// FavoritesManager — CRUD for ~/.parsec-mux/favorites.json.
/// Same JSON format as the Python pmux CLI for interoperability.

import Foundation

struct FavoriteEntry {
    var nickname: String
    var slot: Int
    var settings: [String: Any]
}

final class FavoritesManager {
    private let configDir = NSHomeDirectory() + "/.parsec-mux"
    private let favoritesPath: String

    init() {
        favoritesPath = configDir + "/favorites.json"
    }

    // MARK: - Load

    func load() -> [String: FavoriteEntry] {
        guard let data = FileManager.default.contents(atPath: favoritesPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else {
            return [:]
        }

        var result: [String: FavoriteEntry] = [:]
        for (peerID, info) in json {
            result[peerID] = FavoriteEntry(
                nickname: info["nickname"] as? String ?? peerID,
                slot: info["slot"] as? Int ?? 0,
                settings: info["settings"] as? [String: Any] ?? [:]
            )
        }
        return result
    }

    // MARK: - Save

    func save(_ favorites: [String: FavoriteEntry]) {
        var json: [String: [String: Any]] = [:]
        for (peerID, entry) in favorites {
            json[peerID] = [
                "nickname": entry.nickname,
                "slot": entry.slot,
                "settings": entry.settings
            ]
        }

        guard let data = try? JSONSerialization.data(withJSONObject: json, options: .prettyPrinted) else {
            return
        }

        try? FileManager.default.createDirectory(atPath: configDir,
                                                   withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: favoritesPath, contents: data,
                                        attributes: [.posixPermissions: 0o600])
    }

    // MARK: - CRUD

    func addFavorite(favorites: inout [String: FavoriteEntry],
                     peerID: String, nickname: String, slot: Int,
                     settings: [String: Any] = [:]) {
        favorites[peerID] = FavoriteEntry(nickname: nickname, slot: slot, settings: settings)
        save(favorites)
    }

    func removeFavorite(favorites: inout [String: FavoriteEntry], peerID: String) {
        favorites.removeValue(forKey: peerID)
        save(favorites)
    }

    func updateSlot(favorites: inout [String: FavoriteEntry], peerID: String, newSlot: Int) {
        favorites[peerID]?.slot = newSlot
        save(favorites)
    }

    /// Find the next available F-key slot (1-9). Returns nil if all slots are taken.
    func nextAvailableSlot(favorites: [String: FavoriteEntry]) -> Int? {
        let usedSlots = Set(favorites.values.map(\.slot))
        for slot in 1...9 {
            if !usedSlots.contains(slot) { return slot }
        }
        return nil
    }
}
