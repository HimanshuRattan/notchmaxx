import SwiftUI

enum Theme {
    static let primary = Color.white
    static let secondary = Color.white.opacity(0.56)
    static let tertiary = Color.white.opacity(0.34)
    static let hairline = Color.white.opacity(0.08)
    static let fill = Color.white.opacity(0.055)
    static let track = Color.white.opacity(0.09)

    static let good = Color(red: 0.30, green: 0.85, blue: 0.50)
    static let warn = Color(red: 1.00, green: 0.73, blue: 0.30)
    static let bad = Color(red: 1.00, green: 0.40, blue: 0.36)

    static func accent(_ provider: Provider) -> Color {
        switch provider {
        case .claude: Color(red: 0.85, green: 0.47, blue: 0.34)
        case .codex: Color(red: 0.36, green: 0.86, blue: 0.66)
        case .cursor: Color(red: 0.66, green: 0.71, blue: 1.00)
        }
    }

    static func color(_ severity: Severity) -> Color {
        switch severity {
        case .normal: good
        case .warning: warn
        case .critical: bad
        }
    }

    static func barColor(_ window: LimitWindow, provider: Provider) -> Color {
        if window.usedPercent >= 90 { return bad }
        return accent(provider)
    }
}

enum Format {
    static func tokens(_ n: Int) -> String {
        let v = Double(n)
        // Switch units just below each boundary, so 999,999 reads "1M" rather than "1000K".
        switch v {
        case 999.5e6...: return trim(v / 1e9) + "B"
        case 999.5e3...: return trim(v / 1e6) + "M"
        case 1e3...: return trim(v / 1e3) + "K"
        default: return "\(n)"
        }
    }

    private static func trim(_ v: Double) -> String {
        v >= 100 ? String(format: "%.0f", v) : String(format: "%.1f", v).replacingOccurrences(of: ".0", with: "")
    }

    static func percent(_ v: Double) -> String {
        "\(Int(v.rounded()))%"
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let s = max(Int(seconds), 0)
        let d = s / 86_400, h = (s % 86_400) / 3600, m = (s % 3600) / 60
        if d > 0 { return h > 0 ? "\(d)d \(h)h" : "\(d)d" }
        if h > 0 { return m > 0 ? "\(h)h \(m)m" : "\(h)h" }
        return m > 0 ? "\(m)m" : "<1m"
    }

    private static func formatter(_ template: String) -> DateFormatter {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate(template)
        return f
    }

    private static let weekdayTime = formatter("EEEjmm")
    private static let monthDayFormatter = formatter("MMMd")
    private static let monthDayTime = formatter("MMMdjmm")

    /// "2h 31m", "Sun 14:30" or "Nov 1".
    static func resetShort(_ date: Date, now: Date = .now) -> String {
        let delta = date.timeIntervalSince(now)
        if delta <= 60 { return "now" }
        if delta < 86_400 { return duration(delta) }
        if delta < 6 * 86_400 { return weekdayTime.string(from: date) }
        return monthDayFormatter.string(from: date)
    }

    static func resetPhrase(_ date: Date, now: Date = .now) -> String {
        let delta = date.timeIntervalSince(now)
        if delta <= 60 { return "Resetting now" }
        if delta < 86_400 { return "Resets in \(duration(delta))" }
        if delta < 6 * 86_400 { return "Resets \(weekdayTime.string(from: date))" }
        return "Resets \(monthDayTime.string(from: date))"
    }

    static func expiry(_ date: Date) -> String {
        "expires \(monthDayFormatter.string(from: date))"
    }

    static func relative(_ date: Date?, now: Date = .now) -> String {
        guard let date else { return "never" }
        let delta = now.timeIntervalSince(date)
        if delta < 45 { return "just now" }
        return duration(delta) + " ago"
    }

    static func monthDay(_ date: Date) -> String { monthDayFormatter.string(from: date) }

    static func paceLabel(_ pace: Pace, now: Date = .now) -> String {
        switch pace {
        case .onTrack: "On track"
        case .ahead: "Ahead of pace"
        case .runsOut(let date):
            date.timeIntervalSince(now) < 86_400 ? "Out in \(duration(date.timeIntervalSince(now)))" : "Out by \(weekdayTime.string(from: date))"
        case .reached: "Limit reached"
        case .fresh: "Ready"
        }
    }
}

/// Local view state. Stands in for `@State`, which this SDK implements as a macro whose plugin
/// ships only with full Xcode, so the app also builds with the Command Line Tools.
final class Box<Value>: ObservableObject {
    @Published var value: Value
    init(_ value: Value) { self.value = value }
}
