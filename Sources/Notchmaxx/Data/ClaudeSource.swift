import CryptoKit
import Foundation

/// Claude Code keeps the latest `/usage` response in its state file, so most refreshes need
/// no network call. The live endpoint is only used when that cache is stale.
enum ClaudeSource {
    struct Profile: Sendable {
        var email: String?
        var displayName: String?
        var organization: String?
        var plan: String?
        var isTeam: Bool
    }

    struct Usage: Sendable {
        var windows: [LimitWindow]
        var spendLine: String?
        var fetchedAt: Date
    }

    static let defaultDir = "~/.claude".expandingTilde

    static func stateFile(for dir: String) -> String {
        dir == defaultDir ? "~/.claude.json".expandingTilde : dir + "/.claude.json"
    }

    /// Claude Code namespaces the keychain item by config directory when CLAUDE_CONFIG_DIR is set.
    static func keychainService(for dir: String) -> String {
        guard dir != defaultDir else { return "Claude Code-credentials" }
        let digest = SHA256.hash(data: Data(dir.utf8)).map { String(format: "%02x", $0) }.joined()
        return "Claude Code-credentials-" + digest.prefix(8)
    }

    /// `.claude.json` can run to several megabytes and is read on every rebuild, so the parsed
    /// state is kept until the file changes.
    private static let stateCache = StateCache()

    static func readState(dir: String) -> (profile: Profile?, cached: Usage?) {
        let path = stateFile(for: dir)
        let modified = Paths.modificationDate(path)
        if let modified, let hit = stateCache.value(for: path, modified: modified) { return hit }
        let state = parseState(path)
        if let modified { stateCache.store(state, for: path, modified: modified) }
        return state
    }

    private static func parseState(_ path: String) -> (profile: Profile?, cached: Usage?) {
        guard let state = JSONValue.readFile(path) else { return (nil, nil) }
        var profile: Profile?
        if let account = state["oauthAccount"] as? [String: Any] {
            profile = Self.profile(account)
        }
        var cached: Usage?
        if let cache = state["cachedUsageUtilization"] as? [String: Any],
           let utilization = cache["utilization"] as? [String: Any] {
            let fetched = DateParse.iso(cache["fetchedAtMs"]) ?? .distantPast
            cached = usage(from: utilization, fetchedAt: fetched)
        }
        return (profile, cached)
    }

    static func fetchLive(dir: String) async throws -> Usage {
        let service = keychainService(for: dir)
        guard let raw = SecretCache.shared.value(for: service, load: { Keychain.genericPassword(service: service) }),
              let data = raw.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String else {
            SecretCache.shared.invalidate(service)
            throw SourceError.notSignedIn
        }
        if let expires = DateParse.iso(oauth["expiresAt"]), expires < Date().addingTimeInterval(60) {
            // Refreshing would rotate Claude Code's token, so wait for Claude Code to do it and
            // read the keychain again next time.
            SecretCache.shared.invalidate(service)
            throw SourceError.tokenExpired
        }
        do {
            let body = try await HTTP.json(
                URL(string: "https://api.anthropic.com/api/oauth/usage")!,
                headers: [
                    "Authorization": "Bearer \(token)",
                    "anthropic-beta": "oauth-2025-04-20",
                    "User-Agent": "Notchmaxx/1.0",
                ]
            )
            return usage(from: body, fetchedAt: Date())
        } catch HTTPError.status(let code) where code == 401 || code == 403 {
            SecretCache.shared.invalidate(service)
            throw HTTPError.status(code)
        }
    }

    static func profile(_ account: [String: Any]) -> Profile {
        let orgType = (account["organizationType"] as? String) ?? ""
        let tier = ((account["userRateLimitTier"] as? String) ?? (account["organizationRateLimitTier"] as? String) ?? "").lowercased()
        var plan: String
        switch orgType {
        case "claude_max": plan = "Claude Max"
        case "claude_pro": plan = "Claude Pro"
        case "claude_team": plan = "Claude Team"
        case "claude_enterprise": plan = "Claude Enterprise"
        default: plan = orgType.isEmpty ? "Claude" : orgType.replacingOccurrences(of: "_", with: " ").capitalized
        }
        if tier.contains("20x") {
            plan += " · Max 20x"
        } else if tier.contains("5x") {
            plan += orgType == "claude_max" ? " 5x" : " · Max 5x"
        }
        let isTeam = orgType == "claude_team" || orgType == "claude_enterprise"
        return Profile(
            email: account["emailAddress"] as? String,
            displayName: account["displayName"] as? String,
            organization: account["organizationName"] as? String,
            plan: plan.replacingOccurrences(of: "Claude Max · Max", with: "Claude Max"),
            isTeam: isTeam
        )
    }

    static func usage(from u: [String: Any], fetchedAt: Date) -> Usage {
        var windows: [LimitWindow] = []
        if let limits = u["limits"] as? [[String: Any]], !limits.isEmpty {
            for limit in limits {
                let kind = (limit["kind"] as? String) ?? ""
                let group = (limit["group"] as? String) ?? ""
                let percent = JSONValue.double(limit["percent"]) ?? 0
                let resets = DateParse.iso(limit["resets_at"])
                let scope = limit["scope"] as? [String: Any]
                let scopeName = ((scope?["model"] as? [String: Any])?["display_name"] as? String)
                    ?? ((scope?["surface"] as? [String: Any])?["display_name"] as? String)
                    ?? (scope?["surface"] as? String)
                switch kind {
                case "session":
                    windows.append(LimitWindow(id: "session", title: "5-hour", shortTitle: "5h",
                                               usedPercent: percent, resetsAt: resets, length: 5 * 3600))
                case "weekly_all":
                    windows.append(LimitWindow(id: "weekly", title: "Weekly", shortTitle: "Week",
                                               usedPercent: percent, resetsAt: resets, length: 7 * 86_400))
                default:
                    let name = scopeName ?? kind.replacingOccurrences(of: "_", with: " ").capitalized
                    let isWeekly = group == "weekly" || kind.hasPrefix("weekly")
                    windows.append(LimitWindow(
                        id: "\(kind):\(name)",
                        title: isWeekly ? "Weekly · \(name)" : name,
                        shortTitle: name,
                        usedPercent: percent,
                        resetsAt: resets,
                        length: isWeekly ? 7 * 86_400 : (group == "session" ? 5 * 3600 : nil),
                        isPrimary: false))
                }
            }
        } else {
            let legacy: [(String, String, String, TimeInterval, Bool)] = [
                ("five_hour", "5-hour", "5h", 5 * 3600, true),
                ("seven_day", "Weekly", "Week", 7 * 86_400, true),
                ("seven_day_opus", "Weekly · Opus", "Opus", 7 * 86_400, false),
                ("seven_day_sonnet", "Weekly · Sonnet", "Sonnet", 7 * 86_400, false),
            ]
            for (key, title, short, length, primary) in legacy {
                guard let w = u[key] as? [String: Any], let pct = JSONValue.double(w["utilization"]) else { continue }
                windows.append(LimitWindow(id: key, title: title, shortTitle: short, usedPercent: pct,
                                           resetsAt: DateParse.iso(w["resets_at"]), length: length, isPrimary: primary))
            }
        }

        var spendLine: String?
        if let spend = u["spend"] as? [String: Any], JSONValue.bool(spend["enabled"]) != false,
           let used = money(spend["used"]), let limit = money(spend["limit"]), limit.amount > 0 {
            spendLine = "\(format(used.amount, used.currency)) of \(format(limit.amount, limit.currency)) credits used"
        } else if let extra = u["extra_usage"] as? [String: Any], JSONValue.bool(extra["is_enabled"]) == true,
                  let limitMinor = JSONValue.double(extra["monthly_limit"]), limitMinor > 0 {
            let places = Double(JSONValue.int(extra["decimal_places"]) ?? 2)
            let scale = pow(10, places)
            let used = (JSONValue.double(extra["used_credits"]) ?? 0) / scale
            let currency = (extra["currency"] as? String) ?? "USD"
            spendLine = "\(format(used, currency)) of \(format(limitMinor / scale, currency)) credits used"
        }
        return Usage(windows: windows, spendLine: spendLine, fetchedAt: fetchedAt)
    }

    private static func money(_ value: Any?) -> (amount: Double, currency: String)? {
        guard let m = value as? [String: Any], let minor = JSONValue.double(m["amount_minor"]) else { return nil }
        let exponent = Double(JSONValue.int(m["exponent"]) ?? 2)
        return (minor / pow(10, exponent), (m["currency"] as? String) ?? "USD")
    }

    static func format(_ amount: Double, _ currency: String) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = currency
        f.maximumFractionDigits = amount.rounded() == amount ? 0 : 2
        return f.string(from: NSNumber(value: amount)) ?? String(format: "$%.2f", amount)
    }
}

enum SourceError: LocalizedError {
    case notSignedIn
    case tokenExpired
    case apiKeyMode

    var errorDescription: String? {
        switch self {
        case .notSignedIn: "Not signed in"
        case .tokenExpired: "Sign-in needs a refresh, open the tool once"
        case .apiKeyMode: "Signed in with an API key, which has no plan limits"
        }
    }
}

private final class StateCache: @unchecked Sendable {
    private var entries: [String: (modified: Date, state: (profile: ClaudeSource.Profile?, cached: ClaudeSource.Usage?))] = [:]
    private let lock = NSLock()

    func value(for path: String, modified: Date) -> (profile: ClaudeSource.Profile?, cached: ClaudeSource.Usage?)? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[path], entry.modified == modified else { return nil }
        return entry.state
    }

    func store(_ state: (profile: ClaudeSource.Profile?, cached: ClaudeSource.Usage?), for path: String, modified: Date) {
        lock.lock()
        entries[path] = (modified, state)
        lock.unlock()
    }
}
