import Foundation

enum Provider: String, Codable, CaseIterable, Identifiable, Sendable {
    case claude, codex, cursor

    var id: String { rawValue }

    var name: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .cursor: "Cursor"
        }
    }
}

enum DataSource: String, Codable, Sendable {
    case live, cache, logs, none
}

/// One usage window: the 5-hour session, the weekly cap, a model-scoped weekly cap,
/// or a billing cycle for providers that meter by spend.
struct LimitWindow: Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var shortTitle: String
    var usedPercent: Double
    var resetsAt: Date?
    var length: TimeInterval?
    var detail: String?
    var isPrimary: Bool = true

    var clampedFraction: Double { min(max(usedPercent / 100, 0), 1) }

    var pace: Pace { Pace.evaluate(self) }

    /// A snapshot taken before its reset time is stale once that time passes: usage starts
    /// again from zero. Weekly and longer windows roll on a fixed schedule, so the next reset
    /// is known; shorter windows only start counting again on the next request.
    func normalized(now: Date = .now) -> LimitWindow {
        guard let reset = resetsAt, reset <= now else { return self }
        var copy = self
        copy.usedPercent = 0
        copy.detail = nil
        if let length, length >= 86_400 {
            copy.resetsAt = reset.addingTimeInterval(ceil(now.timeIntervalSince(reset) / length) * length)
        } else {
            copy.resetsAt = nil
        }
        return copy
    }
}

enum Pace: Equatable, Sendable {
    case onTrack
    case ahead
    case runsOut(Date)
    case reached
    case fresh

    static func evaluate(_ window: LimitWindow, now: Date = .now) -> Pace {
        let used = window.usedPercent
        if used >= 99.5 { return .reached }
        guard let reset = window.resetsAt, let length = window.length, length > 0 else {
            if used == 0 { return .fresh }
            return used >= 90 ? .ahead : .onTrack
        }
        if reset <= now { return .fresh }
        let remaining = reset.timeIntervalSince(now)
        let elapsed = max(length - remaining, 0)
        guard used >= 1, elapsed > 60 else { return .onTrack }
        let expected = elapsed / length * 100
        // Projecting from a few minutes of data is noisy, so only call a run-out once a
        // tenth of the window has passed or usage is already high.
        if elapsed >= length * 0.1 || used >= 50 {
            let ratePerSecond = used / elapsed
            let secondsToFull = (100 - used) / ratePerSecond
            if secondsToFull < remaining {
                return .runsOut(now.addingTimeInterval(secondsToFull))
            }
        }
        return used > expected + 10 ? .ahead : .onTrack
    }

    var severity: Severity {
        switch self {
        case .onTrack, .fresh: .normal
        case .ahead: .warning
        case .runsOut, .reached: .critical
        }
    }
}

enum Severity: Int, Comparable, Sendable {
    case normal, warning, critical
    static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rawValue < rhs.rawValue }
}

struct ResetCredit: Hashable, Sendable {
    var title: String
    var expiresAt: Date?
}

struct AccountSnapshot: Identifiable, Sendable {
    var provider: Provider
    var key: String
    var name: String
    var email: String?
    var plan: String?
    var windows: [LimitWindow] = []
    var resetCredits: [ResetCredit] = []
    var resetCreditCount: Int?
    var spendLine: String?
    var footnote: String?
    var source: DataSource = .none
    var updatedAt: Date?
    var error: String?

    var id: String { "\(provider.rawValue):\(key)" }

    var subtitle: String {
        [email, plan].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    var primaryWindows: [LimitWindow] { windows.filter(\.isPrimary) }

    var tightest: LimitWindow? { windows.max { $0.usedPercent < $1.usedPercent } }

    var severity: Severity {
        windows.map { $0.pace.severity }.max() ?? .normal
    }
}

struct LiveSession: Identifiable, Hashable, Sendable {
    var id: String
    var provider: Provider
    var accountKey: String?
    var project: String
    var startedAt: Date
    var lastActivity: Date
    var isBusy: Bool
    var tokens: Int
}

struct TokenCounts: Codable, Hashable, Sendable {
    var input = 0
    var output = 0
    var cacheRead = 0
    var cacheWrite = 0

    var total: Int { input + output + cacheRead + cacheWrite }

    mutating func add(_ other: TokenCounts) {
        input += other.input
        output += other.output
        cacheRead += other.cacheRead
        cacheWrite += other.cacheWrite
    }
}

struct UsageRecord: Hashable, Sendable {
    var day: String
    var provider: Provider
    var account: String
    var model: String
    var counts: TokenCounts
}

struct TokenStats: Sendable {
    var records: [UsageRecord] = []

    static func dayKey(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func lastDays(_ n: Int, now: Date = .now) -> [String] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        return (0..<n).reversed().compactMap { offset in
            cal.date(byAdding: .day, value: -offset, to: today).map(dayKey)
        }
    }

    func total(provider: Provider? = nil, account: String? = nil, days: Int) -> Int {
        let keys = Set(Self.lastDays(days))
        return records.reduce(0) { sum, r in
            guard keys.contains(r.day),
                  provider == nil || r.provider == provider,
                  account == nil || r.account == account else { return sum }
            return sum + r.counts.total
        }
    }

    func today(provider: Provider? = nil, account: String? = nil) -> Int {
        total(provider: provider, account: account, days: 1)
    }

    struct DayBar: Identifiable, Hashable {
        var day: String
        var date: Date
        var series: String
        var tokens: Int
        var id: String { day + series }
    }

    /// Daily totals for the last `days` days, split by provider or, when filtered to one
    /// provider, by model.
    func daily(days: Int, provider: Provider?) -> [DayBar] {
        let keys = Self.lastDays(days)
        let keySet = Set(keys)
        var buckets: [String: [String: Int]] = [:]
        for r in records where keySet.contains(r.day) && (provider == nil || r.provider == provider) {
            let series = provider == nil ? r.provider.name : Self.prettyModel(r.model)
            buckets[r.day, default: [:]][series, default: 0] += r.counts.total
        }
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd"
        // Empty days still need a bar so the axis shows every date. Give them a series that
        // already exists, so the legend gains no extra entry.
        let filler = buckets.values.flatMap(\.keys).min() ?? provider?.name ?? Provider.claude.name
        var bars: [DayBar] = []
        for key in keys {
            let date = parser.date(from: key) ?? .now
            let series = buckets[key] ?? [:]
            if series.isEmpty {
                bars.append(DayBar(day: key, date: date, series: filler, tokens: 0))
            }
            for (name, tokens) in series.sorted(by: { $0.key < $1.key }) {
                bars.append(DayBar(day: key, date: date, series: name, tokens: tokens))
            }
        }
        return bars
    }

    struct ModelRow: Identifiable, Hashable {
        var model: String
        var provider: Provider
        var counts: TokenCounts
        var id: String { provider.rawValue + model }
    }

    func models(days: Int, provider: Provider?) -> [ModelRow] {
        let keys = Set(Self.lastDays(days))
        var map: [String: ModelRow] = [:]
        for r in records where keys.contains(r.day) && (provider == nil || r.provider == provider) {
            let name = Self.prettyModel(r.model)
            let id = r.provider.rawValue + name
            map[id, default: ModelRow(model: name, provider: r.provider, counts: TokenCounts())].counts.add(r.counts)
        }
        return map.values.filter { $0.counts.total > 0 }.sorted { $0.counts.total > $1.counts.total }
    }

    static func prettyModel(_ raw: String) -> String {
        guard !raw.isEmpty else { return "Unknown" }
        var s = raw
        if s.hasPrefix("claude-") { s.removeFirst("claude-".count) }
        // Drop trailing date stamps such as -20251001.
        if let range = s.range(of: #"-\d{8}$"#, options: .regularExpression) { s.removeSubrange(range) }
        let parts = s.split(separator: "-").map(String.init)
        if raw.hasPrefix("claude-"), parts.count >= 2 {
            // Handles both "opus-4-1" and the older "3-5-sonnet" order.
            let words = parts.filter { !$0.allSatisfy(\.isNumber) }.map(\.capitalized)
            let version = parts.filter { $0.allSatisfy(\.isNumber) }.joined(separator: ".")
            return (words + [version]).filter { !$0.isEmpty }.joined(separator: " ")
        }
        if s.lowercased().hasPrefix("gpt-") {
            let rest = parts.dropFirst().map { $0.first?.isNumber == true ? $0 : $0.capitalized }
            return "GPT-" + rest.joined(separator: " ")
        }
        return s
    }
}
