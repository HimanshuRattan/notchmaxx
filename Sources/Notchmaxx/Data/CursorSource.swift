import Foundation
import SQLite3

/// Cursor bills by included spend per billing cycle rather than 5-hour and weekly windows.
/// It has no public usage API, so this reads the endpoints its own dashboard uses and fails
/// soft if they change.
enum CursorSource {
    struct Live: Sendable {
        var email: String?
        var plan: String?
        var windows: [LimitWindow]
        var footnote: String?
        var fetchedAt: Date
    }

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: "/Applications/Cursor.app")
            || FileManager.default.fileExists(atPath: "~/Applications/Cursor.app".expandingTilde)
            || FileManager.default.fileExists(atPath: "~/.cursor/cli-config.json".expandingTilde)
    }

    static func readToken() -> String? {
        SecretCache.shared.value(for: "cursor") {
            // The IDE's own store needs no keychain prompt, so prefer it while its token is valid.
            if let token = ideToken(), (JWT.expiry(token) ?? .distantFuture) > Date().addingTimeInterval(60) { return token }
            return Keychain.genericPassword(service: "cursor-access-token", account: "cursor-user") ?? ideToken()
        }
    }

    private static func ideToken() -> String? {
        let path = "~/Library/Application Support/Cursor/User/globalStorage/state.vscdb".expandingTilde
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2("file:\(path)?mode=ro", &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        let sql = "SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken' LIMIT 1"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { return nil }
        let token = String(cString: text).trimmingCharacters(in: CharacterSet(charactersIn: "\" \n"))
        return token.isEmpty ? nil : token
    }

    static func fetch() async throws -> Live {
        guard let token = readToken() else {
            SecretCache.shared.invalidate("cursor")
            throw SourceError.notSignedIn
        }
        if let expires = JWT.expiry(token), expires < Date().addingTimeInterval(60) {
            SecretCache.shared.invalidate("cursor")
            throw SourceError.tokenExpired
        }
        guard let sub = JWT.claims(token)?["sub"] as? String else { throw SourceError.notSignedIn }
        let userID = sub.split(separator: "|").last.map(String.init) ?? sub
        let headers = [
            "Cookie": "WorkosCursorSessionToken=\(userID)%3A%3A\(token)",
            "Origin": "https://cursor.com",
            "User-Agent": "Notchmaxx/1.0",
        ]
        let summary: [String: Any]
        do {
            summary = try await HTTP.json(URL(string: "https://cursor.com/api/usage-summary")!, headers: headers)
        } catch HTTPError.status(let code) where code == 401 || code == 403 {
            SecretCache.shared.invalidate("cursor")
            throw HTTPError.status(code)
        }
        let me = try? await HTTP.json(URL(string: "https://cursor.com/api/auth/me")!, headers: headers)

        let start = DateParse.iso(summary["billingCycleStart"])
        let end = DateParse.iso(summary["billingCycleEnd"])
        let length = (start != nil && end != nil) ? end!.timeIntervalSince(start!) : nil
        let individual = summary["individualUsage"] as? [String: Any]
        var windows: [LimitWindow] = []
        var footnote: String?

        if let plan = (individual?["plan"] as? [String: Any]) ?? (individual?["overall"] as? [String: Any]) {
            let used = JSONValue.double(plan["used"]) ?? 0
            let limit = JSONValue.double(plan["limit"]) ?? 0
            var percent = JSONValue.double(plan["totalPercentUsed"])
            if percent == nil, limit > 0 { percent = used / limit * 100 }
            if let percent {
                windows.append(LimitWindow(
                    id: "included", title: "Included usage", shortTitle: "Plan",
                    usedPercent: percent, resetsAt: end, length: length,
                    detail: limit > 0 ? "\(dollars(used)) of \(dollars(limit))" : nil))
            }
            let auto = JSONValue.double(plan["autoPercentUsed"])
            let api = JSONValue.double(plan["apiPercentUsed"])
            if auto != nil || api != nil {
                footnote = [auto.map { "Auto \(Int($0.rounded()))%" }, api.map { "API \(Int($0.rounded()))%" }]
                    .compactMap { $0 }.joined(separator: " · ")
            }
        }
        let onDemand = (individual?["onDemand"] as? [String: Any])
            ?? ((summary["teamUsage"] as? [String: Any])?["onDemand"] as? [String: Any])
        if let onDemand, JSONValue.bool(onDemand["enabled"]) == true,
           let limit = JSONValue.double(onDemand["limit"]), limit > 0 {
            let used = JSONValue.double(onDemand["used"]) ?? 0
            windows.append(LimitWindow(
                id: "ondemand", title: "On-demand", shortTitle: "Extra",
                usedPercent: used / limit * 100, resetsAt: end, length: length,
                detail: "\(dollars(used)) of \(dollars(limit))", isPrimary: windows.isEmpty))
        }
        if windows.isEmpty, JSONValue.bool(summary["isUnlimited"]) == true {
            footnote = "Unlimited plan"
        }
        return Live(
            email: me?["email"] as? String,
            plan: planLabel(summary["membershipType"] as? String),
            windows: windows,
            footnote: footnote,
            fetchedAt: Date()
        )
    }

    private static func dollars(_ cents: Double) -> String {
        ClaudeSource.format(cents / 100, "USD")
    }

    static func planLabel(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "Cursor" }
        switch raw.lowercased() {
        case "free", "hobby": return "Cursor Hobby"
        case "pro": return "Cursor Pro"
        case "pro_plus", "pro+": return "Cursor Pro+"
        case "ultra": return "Cursor Ultra"
        case "team", "business", "teams": return "Cursor Teams"
        case "enterprise": return "Cursor Enterprise"
        default: return "Cursor " + raw.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}
