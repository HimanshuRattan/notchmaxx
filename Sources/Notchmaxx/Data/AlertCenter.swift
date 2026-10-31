import Foundation
import UserNotifications

struct AlertItem: Identifiable, Equatable, Sendable {
    enum Kind: Sendable { case threshold, reset }

    var id = UUID()
    var kind: Kind
    var provider: Provider
    var accountName: String
    var title: String
    var message: String
    var percent: Double?
    var severity: Severity
}

/// Decides when to drop an alert from the notch: once per threshold per window cycle, and
/// once when a window that had real usage resets.
@MainActor
final class AlertCenter {
    private static let firedKey = "alerts.fired.v1"
    private var fired: [String: Date]
    private var lastSeen: [String: (used: Double, resetsAt: Date?)] = [:]
    private var primed = false

    init() {
        let stored = UserDefaults.standard.dictionary(forKey: Self.firedKey) as? [String: Date] ?? [:]
        let cutoff = Date().addingTimeInterval(-14 * 86_400)
        fired = stored.filter { $0.value > cutoff }
    }

    func evaluate(_ accounts: [AccountSnapshot], settings: AppSettings, now: Date = .now) -> [AlertItem] {
        var alerts: [AlertItem] = []
        let thresholds = settings.alertThresholds.sorted()
        for account in accounts {
            for window in account.windows {
                let seenKey = "\(account.id)|\(window.id)"
                if settings.resetAlerts, primed, let previous = lastSeen[seenKey], let reset = previous.resetsAt,
                   reset <= now, now.timeIntervalSince(reset) < 900, previous.used >= 5 {
                    let key = "reset|\(seenKey)|\(Self.bucket(reset))"
                    if fired[key] == nil {
                        fired[key] = now
                        alerts.append(AlertItem(
                            kind: .reset, provider: account.provider, accountName: account.name,
                            title: "\(window.title) limit reset",
                            message: "\(account.provider.name) · \(account.name) is clear again",
                            percent: 0, severity: .normal))
                    }
                }
                lastSeen[seenKey] = (window.usedPercent, window.resetsAt)

                let crossed = thresholds.filter { window.usedPercent >= Double($0) }
                guard let top = crossed.last else { continue }
                let cycle = window.resetsAt.map(Self.bucket) ?? 0
                let topKey = "limit|\(seenKey)|\(cycle)|\(top)"
                guard fired[topKey] == nil else { continue }
                for t in crossed { fired["limit|\(seenKey)|\(cycle)|\(t)"] = now }
                let reached = top >= 100 || window.usedPercent >= 99.5
                let reset = window.resetsAt.map { Format.resetPhrase($0, now: now) } ?? ""
                alerts.append(AlertItem(
                    kind: .threshold, provider: account.provider, accountName: account.name,
                    title: reached ? "\(window.title) limit reached" : "\(window.title) at \(Int(window.usedPercent.rounded()))%",
                    message: ["\(account.provider.name) · \(account.name)", reset].filter { !$0.isEmpty }.joined(separator: " · "),
                    percent: window.usedPercent,
                    severity: reached || top >= 90 ? .critical : .warning))
            }
        }
        primed = true
        if !alerts.isEmpty {
            UserDefaults.standard.set(fired, forKey: Self.firedKey)
            if settings.systemNotifications { alerts.forEach(Self.postSystemNotification) }
        }
        return alerts
    }

    /// Reset times can drift by a few seconds between snapshots, so compare them in 10-minute buckets.
    private static func bucket(_ date: Date) -> Int { Int(date.timeIntervalSince1970 / 600) }

    static func requestAuthorization() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private static func postSystemNotification(_ alert: AlertItem) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.message
        let request = UNNotificationRequest(identifier: alert.id.uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
