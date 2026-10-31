import Foundation
import Observation
import ServiceManagement

enum PillMode: String, Codable, CaseIterable, Identifiable {
    case whenWorking, always, never
    var id: String { rawValue }
    var label: String {
        switch self {
        case .whenWorking: "While an agent is working"
        case .always: "Always"
        case .never: "Never"
        }
    }
}

struct AppSettings: Codable, Equatable {
    var claudeConfigDirs: [String] = ["~/.claude"]
    var codexHomes: [String] = ["~/.codex"]
    var cursorEnabled = true
    var accountNames: [String: String] = [:]
    var hiddenAccounts: Set<String> = []
    var alertThresholds: Set<Int> = [75, 90, 100]
    var resetAlerts = true
    var systemNotifications = false
    var pillMode: PillMode = .whenWorking
    var showMenuBarIcon = true
    var liveClaude = true
    var liveCodex = true
    var liveCursor = true
    var liveIntervalMinutes = 5
    var setupCompleted = false

    init() {}

    // Decode field by field so new settings never wipe a saved configuration.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        claudeConfigDirs = (try? c.decode([String].self, forKey: .claudeConfigDirs)) ?? d.claudeConfigDirs
        codexHomes = (try? c.decode([String].self, forKey: .codexHomes)) ?? d.codexHomes
        cursorEnabled = (try? c.decode(Bool.self, forKey: .cursorEnabled)) ?? d.cursorEnabled
        accountNames = (try? c.decode([String: String].self, forKey: .accountNames)) ?? d.accountNames
        hiddenAccounts = (try? c.decode(Set<String>.self, forKey: .hiddenAccounts)) ?? d.hiddenAccounts
        alertThresholds = (try? c.decode(Set<Int>.self, forKey: .alertThresholds)) ?? d.alertThresholds
        resetAlerts = (try? c.decode(Bool.self, forKey: .resetAlerts)) ?? d.resetAlerts
        systemNotifications = (try? c.decode(Bool.self, forKey: .systemNotifications)) ?? d.systemNotifications
        pillMode = (try? c.decode(PillMode.self, forKey: .pillMode)) ?? d.pillMode
        showMenuBarIcon = (try? c.decode(Bool.self, forKey: .showMenuBarIcon)) ?? d.showMenuBarIcon
        liveClaude = (try? c.decode(Bool.self, forKey: .liveClaude)) ?? d.liveClaude
        liveCodex = (try? c.decode(Bool.self, forKey: .liveCodex)) ?? d.liveCodex
        liveCursor = (try? c.decode(Bool.self, forKey: .liveCursor)) ?? d.liveCursor
        liveIntervalMinutes = (try? c.decode(Int.self, forKey: .liveIntervalMinutes)) ?? d.liveIntervalMinutes
        setupCompleted = (try? c.decode(Bool.self, forKey: .setupCompleted)) ?? d.setupCompleted
    }
}

@MainActor
@Observable
final class SettingsStore {
    static let shared = SettingsStore()

    private static let key = "settings.v1"

    var value: AppSettings {
        didSet {
            guard value != oldValue else { return }
            if let data = try? JSONEncoder().encode(value) {
                UserDefaults.standard.set(data, forKey: Self.key)
            }
            onChange?(oldValue, value)
        }
    }

    @ObservationIgnored var onChange: ((AppSettings, AppSettings) -> Void)?

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            value = decoded
        } else {
            value = AppSettings()
        }
    }

    func displayName(for accountID: String, fallback: String) -> String {
        let custom = value.accountNames[accountID]?.trimmingCharacters(in: .whitespaces) ?? ""
        return custom.isEmpty ? fallback : custom
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("Notchmaxx: launch at login change failed: \(error.localizedDescription)")
            }
        }
    }
}

extension String {
    var expandingTilde: String { (self as NSString).expandingTildeInPath }
}
