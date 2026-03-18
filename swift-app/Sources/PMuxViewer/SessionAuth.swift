/// SessionAuth — Extracts Parsec session token using the same backend as pmux.
/// Priority: 1) cached session.json  2) Parsec WebKit cache  3) PARSEC_SESSION_ID env

import Foundation
import SQLite3

enum SessionAuth {
    private static let configDir = NSHomeDirectory() + "/.parsec-mux"
    private static let sessionFile = configDir + "/session.json"
    private static let parsecCacheDB = NSHomeDirectory() + "/Library/Caches/tv.parsec.www/Cache.db"

    /// Get a session token, trying all sources in order.
    static func getSessionToken() -> String? {
        // 1. Our cached session (written by `pmux` Python CLI)
        if let token = loadCachedSession() {
            print("[pmux] Session loaded from session.json")
            return token
        }

        // 2. Extract from Parsec's WebKit cache DB
        if let token = extractFromWebKitCache() {
            print("[pmux] Session extracted from Parsec WebKit cache")
            // Save it for next time
            saveCachedSession(token)
            return token
        }

        // 3. Environment variable fallback
        if let token = ProcessInfo.processInfo.environment["PARSEC_SESSION_ID"],
           !token.isEmpty {
            print("[pmux] Session loaded from PARSEC_SESSION_ID env")
            return token
        }

        return nil
    }

    // MARK: - Cached session.json

    private static func loadCachedSession() -> String? {
        guard let data = FileManager.default.contents(atPath: sessionFile),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sessionID = json["session_id"] as? String,
              !sessionID.isEmpty else {
            return nil
        }
        return sessionID
    }

    private static func saveCachedSession(_ token: String) {
        let json: [String: Any] = ["session_id": token]
        guard let data = try? JSONSerialization.data(withJSONObject: json) else { return }

        // Ensure config dir exists
        try? FileManager.default.createDirectory(
            atPath: configDir, withIntermediateDirectories: true)

        FileManager.default.createFile(atPath: sessionFile, contents: data,
                                       attributes: [.posixPermissions: 0o600])
    }

    // MARK: - WebKit Cache Extraction

    /// Replicates parsec_mux/auth.py:extract_parsec_session()
    /// Queries Parsec's WebKit cache SQLite DB for the Bearer token.
    private static func extractFromWebKitCache() -> String? {
        guard FileManager.default.fileExists(atPath: parsecCacheDB) else {
            print("[pmux] Parsec cache DB not found at \(parsecCacheDB)")
            return nil
        }

        // Open SQLite read-only
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
        let uri = "file:\(parsecCacheDB)?mode=ro"
        guard sqlite3_open_v2(uri, &db, flags, nil) == SQLITE_OK else {
            print("[pmux] Cannot open Parsec cache DB")
            return nil
        }
        defer { sqlite3_close(db) }

        // Query for the /me endpoint request blob
        let sql = """
            SELECT request_object FROM cfurl_cache_blob_data b
            JOIN cfurl_cache_response r ON b.entry_ID = r.entry_ID
            WHERE r.request_key LIKE '%kessel-api.parsec.app/me'
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            print("[pmux] SQL prepare failed")
            return nil
        }
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_step(stmt) == SQLITE_ROW else {
            print("[pmux] No /me request found in Parsec cache")
            return nil
        }

        guard let blobPtr = sqlite3_column_blob(stmt, 0) else { return nil }
        let blobLen = sqlite3_column_bytes(stmt, 0)
        let blobData = Data(bytes: blobPtr, count: Int(blobLen))

        // Convert binary plist to XML via plutil (same approach as Python)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/plutil")
        process.arguments = ["-convert", "xml1", "-o", "-", "-"]

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            inputPipe.fileHandleForWriting.write(blobData)
            inputPipe.fileHandleForWriting.closeFile()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else { return nil }

            let xmlData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let xmlText = String(data: xmlData, encoding: .utf8) ?? ""

            // Extract Bearer token (40+ hex chars)
            let pattern = "Bearer\\s+([a-f0-9]{40,})"
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: xmlText,
                                            range: NSRange(xmlText.startIndex..., in: xmlText)),
               let tokenRange = Range(match.range(at: 1), in: xmlText) {
                return String(xmlText[tokenRange])
            }
        } catch {
            print("[pmux] plutil failed: \(error)")
        }

        return nil
    }
}
