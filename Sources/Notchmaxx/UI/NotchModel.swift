import SwiftUI

enum NotchTab: String, CaseIterable, Identifiable {
    case overview, claude, codex, cursor

    var id: String { rawValue }

    var provider: Provider? {
        switch self {
        case .overview: nil
        case .claude: .claude
        case .codex: .codex
        case .cursor: .cursor
        }
    }

    var title: String { provider?.name ?? "Overview" }

    init(_ provider: Provider) {
        switch provider {
        case .claude: self = .claude
        case .codex: self = .codex
        case .cursor: self = .cursor
        }
    }
}

@MainActor
@Observable
final class NotchModel {
    enum Presentation: Equatable { case collapsed, expanded, alert }

    var presentation: Presentation = .collapsed
    var tab: NotchTab = .overview
    var alert: AlertItem?
    var notchSize = CGSize(width: 200, height: 32)
    var hasPhysicalNotch = true
    /// Size of the visible black shape, measured by SwiftUI and used for hit testing.
    var shellSize: CGSize = .zero
    /// Fractional tab index for the highlight. The promo renderer sets it to draw the slide
    /// between tabs one frame at a time; the app leaves it nil and animates instead.
    var tabGlide: Double?
    /// Follows the Cursor setting, so a disabled tool has no tab to land on.
    var showsCursor = true

    var tabs: [NotchTab] { showsCursor ? NotchTab.allCases : NotchTab.allCases.filter { $0 != .cursor } }

    static let pillExtension: CGFloat = 58
    static let panelWidth: CGFloat = 480

    func select(_ tab: NotchTab) {
        withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) { self.tab = tab }
    }

    func step(_ delta: Int) {
        let all = tabs
        guard let index = all.firstIndex(of: tab) else { return }
        let next = min(max(index + delta, 0), all.count - 1)
        if next != index { select(all[next]) }
    }
}

struct NotchActions {
    var openUsage: () -> Void = {}
    var openSettings: () -> Void = {}
    var openSetup: () -> Void = {}
    var refresh: () -> Void = {}
}
