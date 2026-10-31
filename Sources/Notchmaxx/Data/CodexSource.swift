import Foundation

/// Codex limits come from two places: the same usage endpoint `/status` calls, using the login
/// in a CODEX_HOME, and the rate-limit snapshots Codex writes into every session log. Logs also
/// cover accounts that only exist inside other apps, such as a second ChatGPT login in T3 Code.
enum CodexSource {
    struct Auth: Sendable {
        var home: String
        var accountID: String
        var accessToken: String
        var email: String?
        var plan: String?
        var expiresAt: Date?
    }

    struct Live: Sendable {
        var accountID: String
        var windows: [LimitWindow]
        var plan: String?
        var resetCount: Int?
        var resetCredits: [ResetCredit]
        var creditsLine: String?
        var limitReached: Bool
        var fetchedAt: Date
    }

    private static let base = "https://chatgpt.com/backend-api"

    static func readAuth(home: String) throws -> Auth? {
        guard let json = JSONValue.readFile(home + "/auth.json") else { return nil }
        if let mode = json["auth_mode"] as? String, mode.lowercased().contains("api") {
            throw SourceError.apiKeyMode
        }
        guard let tokens = json["tokens"] as? [String: Any],
              let access = tokens["access_token"] as? String else { return nil }
        var accountID = tokens["account_id"] as? String
        var email: String?
        var plan: String?
        if let idToken = tokens["id_token"] as? String, let claims = JWT.claims(idToken) {
            email = claims["email"] as? String
            let auth = claims["https://api.openai.com/auth"] as? [String: Any]
            plan = auth?["chatgpt_plan_type"] as? String
            accountID = accountID ?? (auth?["chatgpt_account_id"] as? String)
            if email == nil, let profile = claims["https://api.openai.com/profile"] as? [String: Any] {
                email = profile["email"] as? String
            }
        }
        guard let accountID else { return nil }
        return Auth(home: home, accountID: accountID, accessToken: access, email: email, plan: plan,
                    expiresAt: JWT.expiry(access))
    }

    static func fetchLive(_ auth: Auth) async throws -> Live {
        if let expires = auth.expiresAt, expires < Date().addingTimeInterval(60) {
            throw SourceError.tokenExpired
        }
        let headers = [
            "Authorization": "Bearer \(auth.accessToken)",
            "ChatGPT-Account-Id": auth.accountID,
            "User-Agent": "Notchmaxx/1.0",
        ]
        let body = try await HTTP.json(URL(string: base + "/wham/usage")!, headers: headers)
        var windows: [LimitWindow] = []
        var limitReached = false
        if let limit = body["rate_limit"] as? [String: Any] {
            limitReached = JSONValue.bool(limit["limit_reached"]) ?? false
            for key in ["primary_window", "secondary_window"] {
                if let w = limit[key] as? [String: Any], let window = window(fromAPI: w, idPrefix: "") {
                    windows.append(window)
                }
            }
        }
        for extra in (body["additional_rate_limits"] as? [[String: Any]]) ?? [] {
            let name = (extra["limit_name"] as? String) ?? (extra["metered_feature"] as? String) ?? "Extra"
            guard let limit = extra["rate_limit"] as? [String: Any] else { continue }
            for key in ["primary_window", "secondary_window"] {
                guard let w = limit[key] as? [String: Any], var window = window(fromAPI: w, idPrefix: name + ":") else { continue }
                window.title = "\(window.title) · \(name)"
                window.shortTitle = name
                window.isPrimary = false
                windows.append(window)
            }
        }
        let resetCount = JSONValue.int((body["rate_limit_reset_credits"] as? [String: Any])?["available_count"])
        var credits: [ResetCredit] = []
        if let resetCount, resetCount > 0 {
            credits = (try? await fetchResetCredits(headers: headers)) ?? []
        }
        return Live(
            accountID: auth.accountID,
            windows: windows,
            plan: body["plan_type"] as? String,
            resetCount: resetCount,
            resetCredits: credits,
            creditsLine: creditsLine(body["credits"] as? [String: Any]),
            limitReached: limitReached,
            fetchedAt: Date()
        )
    }

    /// Lists available manual resets. This only reads; redeeming one stays in Codex.
    private static func fetchResetCredits(headers: [String: String]) async throws -> [ResetCredit] {
        let body = try await HTTP.json(URL(string: base + "/wham/rate-limit-reset-credits")!, headers: headers)
        let credits = (body["credits"] as? [[String: Any]]) ?? []
        return credits.compactMap { credit in
            let status = ((credit["status"] as? String) ?? "available").lowercased()
            guard status == "available" || status == "active" || status == "granted" else { return nil }
            let type = (credit["reset_type"] as? String) ?? "reset"
            let title = (credit["title"] as? String)
                ?? (type == "full" ? "Full reset" : type.replacingOccurrences(of: "_", with: " ").capitalized + " reset")
            return ResetCredit(title: title, expiresAt: DateParse.iso(credit["expires_at"]))
        }
    }

    private static func window(fromAPI w: [String: Any], idPrefix: String) -> LimitWindow? {
        guard let used = JSONValue.double(w["used_percent"]) else { return nil }
        let seconds = JSONValue.double(w["limit_window_seconds"])
        var resets = JSONValue.double(w["reset_at"]).map { Date(timeIntervalSince1970: $0) }
        if resets == nil, let after = JSONValue.double(w["reset_after_seconds"]) {
            resets = Date().addingTimeInterval(after)
        }
        return makeWindow(used: used, minutes: seconds.map { Int($0 / 60) }, resetsAt: resets, idPrefix: idPrefix)
    }

    static func windows(fromLog log: CodexRateLimitLog, now: Date = .now) -> [LimitWindow] {
        [log.primary, log.secondary].compactMap { w in
            guard let w else { return nil }
            return makeWindow(used: w.usedPercent, minutes: w.windowMinutes, resetsAt: w.resetsAt, idPrefix: "")
                .normalized(now: now)
        }
    }

    private static func makeWindow(used: Double, minutes: Int?, resetsAt: Date?, idPrefix: String) -> LimitWindow {
        let length = minutes.map { TimeInterval($0 * 60) }
        let (id, title, short): (String, String, String)
        switch minutes {
        case 300: (id, title, short) = ("session", "5-hour", "5h")
        case 10_080: (id, title, short) = ("weekly", "Weekly", "Week")
        case let m? where m % 1440 == 0: (id, title, short) = ("d\(m)", "\(m / 1440)-day", "\(m / 1440)d")
        case let m? where m % 60 == 0: (id, title, short) = ("h\(m)", "\(m / 60)-hour", "\(m / 60)h")
        case let m?: (id, title, short) = ("m\(m)", "\(m)-minute", "\(m)m")
        case nil: (id, title, short) = ("window", "Usage", "Use")
        }
        return LimitWindow(id: idPrefix + id, title: title, shortTitle: short, usedPercent: used,
                           resetsAt: resetsAt, length: length, isPrimary: idPrefix.isEmpty)
    }

    static func creditsLine(_ credits: [String: Any]?) -> String? {
        guard let credits, JSONValue.bool(credits["has_credits"]) == true else { return nil }
        if JSONValue.bool(credits["unlimited"]) == true { return "Unlimited credits" }
        guard let balance = JSONValue.double(credits["balance"]), balance > 0 else { return nil }
        return "\(Int(balance.rounded())) credits left"
    }

    static func planLabel(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        switch raw.lowercased() {
        case "promax": return "ChatGPT Pro Max"
        case "pro": return "ChatGPT Pro"
        case "prolite": return "ChatGPT Pro Lite"
        case "plus": return "ChatGPT Plus"
        case "go": return "ChatGPT Go"
        case "free": return "ChatGPT Free"
        case "team": return "ChatGPT Team"
        case "business", "self_serve_business_usage_based", "self_serve_business_prolite": return "ChatGPT Business"
        case "enterprise", "ent26", "enterprise_cbp_usage_based", "enterprise_cbp_automation": return "ChatGPT Enterprise"
        case "edu", "education", "edu_plus", "edu_pro", "k12": return "ChatGPT Edu"
        default: return "ChatGPT " + raw.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    static func isWorkspacePlan(_ raw: String?) -> Bool {
        guard let raw = raw?.lowercased() else { return false }
        return raw == "team" || raw.contains("business") || raw.contains("enterprise") || raw.hasPrefix("ent")
            || raw.hasPrefix("edu") || raw == "k12"
    }
}
