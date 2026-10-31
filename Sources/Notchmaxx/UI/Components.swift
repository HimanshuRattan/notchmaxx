import SwiftUI

struct UsageBar: View {
    var fraction: Double
    var color: Color
    var height: CGFloat = 5

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                Capsule()
                    .fill(LinearGradient(colors: [color.opacity(0.75), color], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(fraction > 0 ? height : 0, geo.size.width * fraction))
                    .shadow(color: color.opacity(0.35), radius: 4)
            }
        }
        .frame(height: height)
        .animation(.spring(response: 0.6, dampingFraction: 0.85), value: fraction)
    }
}

struct PaceBadge: View {
    var pace: Pace

    var body: some View {
        HStack(spacing: 6) {
            StatusDot(color: Theme.color(pace.severity))
            Text(Format.paceLabel(pace))
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Theme.color(pace.severity))
        }
    }
}

/// The full meter used on provider tabs: title and pace, bar, then usage and reset.
struct MeterBlock: View {
    var window: LimitWindow
    var provider: Provider

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(window.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.primary)
                Spacer()
                PaceBadge(pace: window.pace)
            }
            UsageBar(fraction: window.clampedFraction, color: Theme.barColor(window, provider: provider))
            HStack {
                Text(window.detail.map { "\(Format.percent(window.usedPercent)) used · \($0)" } ?? "\(Format.percent(window.usedPercent)) used")
                Spacer()
                Text(window.resetsAt.map { Format.resetPhrase($0) } ?? "Starts with your next request")
            }
            .font(.system(size: 11.5))
            .foregroundStyle(Theme.secondary)
            .monospacedDigit()
        }
    }
}

/// The compact meter used on the overview rows.
struct MiniMeter: View {
    var window: LimitWindow
    var provider: Provider

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 0) {
                Text(window.shortTitle)
                    .foregroundStyle(Theme.tertiary)
                Spacer(minLength: 4)
                Text(Format.percent(window.usedPercent))
                    .foregroundStyle(window.usedPercent >= 90 ? Theme.bad : Theme.primary)
                    .fontWeight(.semibold)
            }
            .font(.system(size: 10.5))
            UsageBar(fraction: window.clampedFraction, color: Theme.barColor(window, provider: provider), height: 3)
            Text(window.resetsAt.map { Format.resetShort($0) } ?? "idle")
                .font(.system(size: 10))
                .foregroundStyle(Theme.tertiary)
                .lineLimit(1)
        }
        .monospacedDigit()
        .frame(width: 76)
    }
}

struct Chip: View {
    var systemImage: String
    var text: String
    var tint: Color = Theme.secondary

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tint)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Capsule().fill(Theme.fill))
    }
}

struct AccountHeader: View {
    var account: AccountSnapshot
    var isActive: Bool

    var body: some View {
        HStack(spacing: 10) {
            ProviderGlyph(provider: account.provider, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(account.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.primary)
                if !account.subtitle.isEmpty {
                    Text(account.subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            if isActive {
                HStack(spacing: 6) {
                    StatusDot(color: Theme.good, pulsing: true)
                    Text("Active now")
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.secondary)
            } else if account.source == .logs, let updated = account.updatedAt {
                Text("Logged \(Format.relative(updated))")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiary)
            }
        }
    }
}

struct AccountCard: View {
    var account: AccountSnapshot
    var isActive: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            AccountHeader(account: account, isActive: isActive)
            if account.windows.isEmpty {
                Text(account.error ?? (account.provider == .cursor ? "Waiting for Cursor usage" : "No usage reported yet"))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondary)
            }
            ForEach(account.windows) { window in
                MeterBlock(window: window, provider: account.provider)
            }
            extras
        }
    }

    @ViewBuilder private var extras: some View {
        let chips = chipItems
        if !chips.isEmpty || account.footnote != nil || account.error != nil {
            VStack(alignment: .leading, spacing: 6) {
                if !chips.isEmpty {
                    FlowRow(spacing: 6) {
                        ForEach(chips, id: \.text) { chip in
                            Chip(systemImage: chip.icon, text: chip.text, tint: chip.tint)
                        }
                    }
                }
                if let footnote = account.footnote {
                    Text(footnote)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let error = account.error, !account.windows.isEmpty {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.warn.opacity(0.85))
                }
            }
        }
    }

    private struct ChipItem {
        var icon: String
        var text: String
        var tint: Color
    }

    private var chipItems: [ChipItem] {
        var items: [ChipItem] = []
        if let count = account.resetCreditCount {
            if count > 0 {
                let soonest = account.resetCredits.compactMap(\.expiresAt).min()
                let text = "\(count) manual reset\(count == 1 ? "" : "s") available" + (soonest.map { " · \(Format.expiry($0))" } ?? "")
                items.append(ChipItem(icon: "arrow.counterclockwise", text: text, tint: Theme.good))
            } else {
                items.append(ChipItem(icon: "arrow.counterclockwise", text: "No manual resets", tint: Theme.tertiary))
            }
        }
        if let spend = account.spendLine {
            items.append(ChipItem(icon: "creditcard", text: spend, tint: Theme.secondary))
        }
        return items
    }
}

struct SessionRow: View {
    var session: LiveSession
    var todayTokens: Int

    var body: some View {
        HStack(spacing: 8) {
            StatusDot(color: session.isBusy ? Theme.good : Theme.tertiary, pulsing: session.isBusy)
            ProviderGlyph(provider: session.provider, size: 14, plate: false)
            Text(session.project)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.primary)
                .lineLimit(1)
            Text("· \(Format.duration(Date().timeIntervalSince(session.startedAt)))")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondary)
            Spacer(minLength: 8)
            (Text(Format.tokens(session.tokens)).fontWeight(.semibold).foregroundColor(Theme.primary)
                + Text(" session · ").foregroundColor(Theme.tertiary)
                + Text(Format.tokens(todayTokens)).fontWeight(.semibold).foregroundColor(Theme.primary)
                + Text(" today").foregroundColor(Theme.tertiary))
                .font(.system(size: 11.5))
                .lineLimit(1)
        }
        .monospacedDigit()
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.fill))
    }
}

/// Wraps chips onto new lines when they do not fit.
struct FlowRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: min(maxX, width), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
