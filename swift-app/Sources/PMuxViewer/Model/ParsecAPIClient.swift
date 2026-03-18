/// ParsecAPIClient — Swift HTTP client for the Parsec Kessel REST API.
/// Fetches available hosts and validates sessions.

import Foundation

// MARK: - API Response Types

struct ParsecHost: Identifiable {
    let peerID: String
    let name: String
    let online: Bool
    let players: Int
    let maxPlayers: Int
    let userName: String
    let userID: Int
    let build: String

    var id: String { peerID }
}

// MARK: - API Client

final class ParsecAPIClient {
    static let baseURL = "https://kessel-api.parsec.app"
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.httpAdditionalHeaders = [
            "Content-Type": "application/json",
            "User-Agent": "pmux-viewer/2.0"
        ]
        session = URLSession(configuration: config)
    }

    /// Fetch all available hosts for the authenticated user.
    func fetchHosts(sessionToken: String) async throws -> [ParsecHost] {
        var components = URLComponents(string: "\(Self.baseURL)/v2/hosts")!
        components.queryItems = [
            URLQueryItem(name: "mode", value: "desktop"),
            URLQueryItem(name: "public", value: "false")
        ]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ParsecAPIError.invalidResponse
        }
        guard httpResponse.statusCode == 200 else {
            throw ParsecAPIError.httpError(statusCode: httpResponse.statusCode)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hostArray = json["data"] as? [[String: Any]] else {
            throw ParsecAPIError.parseError
        }

        return hostArray.compactMap { h -> ParsecHost? in
            guard let peerID = h["peer_id"] as? String else { return nil }
            let user = h["user"] as? [String: Any] ?? [:]
            return ParsecHost(
                peerID: peerID,
                name: h["name"] as? String ?? "Unknown",
                online: h["online"] as? Bool ?? false,
                players: h["players"] as? Int ?? 0,
                maxPlayers: h["max_players"] as? Int ?? 1,
                userName: user["name"] as? String ?? "",
                userID: user["id"] as? Int ?? 0,
                build: h["build"] as? String ?? ""
            )
        }
    }

    /// Validate that a session token is still active.
    func validateSession(sessionToken: String) async -> Bool {
        var request = URLRequest(url: URL(string: "\(Self.baseURL)/me")!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")

        do {
            let (_, response) = try await session.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }
}

enum ParsecAPIError: Error, LocalizedError {
    case invalidResponse
    case httpError(statusCode: Int)
    case parseError

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Invalid API response"
        case .httpError(let code): return "API error (HTTP \(code))"
        case .parseError: return "Failed to parse API response"
        }
    }
}
