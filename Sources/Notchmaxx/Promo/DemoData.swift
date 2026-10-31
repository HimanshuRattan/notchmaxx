import Foundation

/// Made-up accounts, sessions and token history for screenshots and the promo video, so neither
/// ever shows a real account. Times are relative to now, so reset countdowns always look fresh.
@MainActor
enum DemoData {
    static func stage(into store: UsageStore, now: Date = .now) {
        store.stage(accounts(now: now), sessions: sessions(now: now), stats: stats(now: now))
    }

    static func accounts(now: Date = .now) -> [AccountSnapshot] {
        func window(_ id: String, _ title: String, _ short: String, used: Double, resetsIn: TimeInterval, length: TimeInterval,
                    primary: Bool = true) -> LimitWindow {
            LimitWindow(id: id, title: title, shortTitle: short, usedPercent: used,
                        resetsAt: now.addingTimeInterval(resetsIn), length: length, isPrimary: primary)
        }
        let hour: TimeInterval = 3600, day: TimeInterval = 86_400
        return [
            AccountSnapshot(
                provider: .claude, key: "demo-claude", name: "Personal", plan: "Claude Max 20x",
                windows: [
                    window("session", "5-hour", "5h", used: 46, resetsIn: 2 * hour + 10 * 60, length: 5 * hour),
                    window("weekly", "Weekly", "Week", used: 23, resetsIn: 3 * day + 5 * hour, length: 7 * day),
                    window("seven_day_opus:Opus", "Weekly · Opus", "Opus", used: 12, resetsIn: 3 * day + 5 * hour,
                           length: 7 * day, primary: false),
                ],
                source: .live, updatedAt: now),
            AccountSnapshot(
                provider: .codex, key: "demo-codex-personal", name: "Personal", plan: "ChatGPT Pro",
                windows: [window("weekly", "Weekly", "Week", used: 18, resetsIn: 4 * day + 7 * hour, length: 7 * day)],
                resetCredits: [ResetCredit(title: "Full reset", expiresAt: now.addingTimeInterval(6 * day))],
                resetCreditCount: 1, source: .live, updatedAt: now),
            AccountSnapshot(
                provider: .codex, key: "demo-codex-work", name: "Work", plan: "ChatGPT Business",
                windows: [
                    window("session", "5-hour", "5h", used: 12, resetsIn: 3 * hour + 40 * 60, length: 5 * hour),
                    window("weekly", "Weekly", "Week", used: 31, resetsIn: 2 * day + 9 * hour, length: 7 * day),
                ],
                source: .live, updatedAt: now),
            AccountSnapshot(
                provider: .cursor, key: "demo-cursor", name: "Cursor", plan: "Cursor Pro",
                windows: [window("included", "Included usage", "Plan", used: 27, resetsIn: 17 * day, length: 30 * day)],
                source: .live, updatedAt: now),
        ]
    }

    static func sessions(now: Date = .now) -> [LiveSession] {
        [
            LiveSession(id: "demo-session-claude", provider: .claude, accountKey: "demo-claude", project: "notchmaxx",
                        startedAt: now.addingTimeInterval(-(2 * 3600 + 14 * 60)), lastActivity: now, isBusy: true,
                        tokens: 18_400_000),
            LiveSession(id: "demo-session-codex", provider: .codex, accountKey: "demo-codex-personal", project: "api-server",
                        startedAt: now.addingTimeInterval(-47 * 60), lastActivity: now, isBusy: true, tokens: 6_100_000),
        ]
    }

    /// Thirty days of history with a weekday rhythm, split across a few models.
    static func stats(now: Date = .now) -> TokenStats {
        let days = TokenStats.lastDays(30, now: now)
        var records: [UsageRecord] = []
        for (index, day) in days.enumerated() {
            let wave = 0.65 + 0.35 * sin(Double(index) * 0.9) + (index % 7 >= 5 ? -0.3 : 0.1)
            let claude = Int(110_000_000 * max(wave, 0.2))
            let codex = Int(32_000_000 * max(1.1 - wave * 0.5, 0.2))
            records += [
                UsageRecord(day: day, provider: .claude, account: "demo-claude", model: "claude-opus-4-1",
                            counts: TokenCounts(input: claude * 6 / 10)),
                UsageRecord(day: day, provider: .claude, account: "demo-claude", model: "claude-sonnet-4-5",
                            counts: TokenCounts(input: claude * 4 / 10)),
                UsageRecord(day: day, provider: .codex, account: index.isMultiple(of: 3) ? "demo-codex-work" : "demo-codex-personal",
                            model: "gpt-5-codex", counts: TokenCounts(input: codex)),
            ]
        }
        return TokenStats(records: records)
    }
}
