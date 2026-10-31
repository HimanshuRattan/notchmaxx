import Charts
import SwiftUI

struct UsageWindowView: View {
    var store: UsageStore
    var scrollable = true
    @StateObject private var filterBox = Box<Provider?>(nil)
    @StateObject private var hoverBox = Box<String?>(nil)

    private var logProviders: [Provider] { [.claude, .codex] }

    var body: some View {
        Group {
            if scrollable {
                ScrollView { content }
            } else {
                content
            }
        }
        .frame(minWidth: 640, minHeight: 640)
        .background(Color(red: 0.045, green: 0.045, blue: 0.05))
        .environment(\.colorScheme, .dark)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 22) {
            header
            totals
            card(title: "Last 7 days", subtitle: filterBox.value == nil ? "Tokens per day by tool" : "Tokens per day by model") {
                dailyChart
            }
            card(title: "Models · last 30 days", subtitle: "Share of tokens, including cached input") {
                modelBreakdown
            }
            card(title: "Limits", subtitle: "Every connected account") {
                limits
            }
            Text("Token counts come from Claude Code and Codex logs on this Mac. Cursor keeps no local logs, so it only appears under limits.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.tertiary)
        }
        .padding(28)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Usage")
                    .font(.system(size: 26, weight: .semibold))
                Text("Updated \(Format.relative(store.lastUpdated))")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.tertiary)
            }
            Spacer()
            Picker("", selection: $filterBox.value) {
                Text("All").tag(Provider?.none)
                ForEach(logProviders) { Text($0.name).tag(Provider?.some($0)) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 220)
        }
    }

    private var totals: some View {
        let models = store.stats.models(days: 30, provider: filterBox.value)
        return HStack(spacing: 12) {
            stat("Today", store.stats.total(provider: filterBox.value, days: 1))
            stat("7 days", store.stats.total(provider: filterBox.value, days: 7))
            stat("30 days", store.stats.total(provider: filterBox.value, days: 30))
            statText("Top model", models.first?.model ?? "None")
        }
    }

    private func stat(_ label: String, _ value: Int) -> some View {
        statText(label, Format.tokens(value))
    }

    private func statText(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.secondary)
            Text(value)
                .font(.system(size: 20, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.045)))
    }

    private func card<Content: View>(title: String, subtitle: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(subtitle).font(.system(size: 11.5)).foregroundStyle(Theme.tertiary)
            }
            content()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white.opacity(0.035)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.05)))
    }

    // MARK: - Chart

    private var dailyChart: some View {
        let bars = store.stats.daily(days: 7, provider: filterBox.value)
        let series = Array(Set(bars.map(\.series))).sorted()
        let palette = seriesColors(series)
        return Chart(bars) { bar in
            BarMark(
                x: .value("Day", bar.date, unit: .day),
                y: .value("Tokens", bar.tokens),
                width: .ratio(0.55)
            )
            .foregroundStyle(by: .value("Series", bar.series))
            .cornerRadius(3)
            .opacity(hoverBox.value == nil || hoverBox.value == bar.day ? 1 : 0.45)
        }
        .chartForegroundStyleScale(domain: series, range: series.map { palette[$0] ?? .gray })
        .chartXAxis {
            AxisMarks(values: .stride(by: .day)) { _ in
                AxisValueLabel(format: .dateTime.weekday(.abbreviated), centered: true)
                    .foregroundStyle(Theme.secondary)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine().foregroundStyle(Theme.hairline)
                AxisValueLabel {
                    if let v = value.as(Int.self) { Text(Format.tokens(v)).foregroundStyle(Theme.tertiary) }
                }
            }
        }
        .chartLegend(position: .top, alignment: .leading, spacing: 12)
        .chartOverlay { proxy in
            GeometryReader { _ in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let point):
                            if let date: Date = proxy.value(atX: point.x) { hoverBox.value = TokenStats.dayKey(date) }
                        case .ended:
                            hoverBox.value = nil
                        }
                    }
            }
        }
        .overlay(alignment: .topTrailing) {
            if let day = hoverBox.value {
                let total = bars.filter { $0.day == day }.reduce(0) { $0 + $1.tokens }
                Text("\(Format.tokens(total)) tokens")
                    .font(.system(size: 11.5, weight: .semibold))
                    .monospacedDigit()
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.white.opacity(0.1)))
            }
        }
        .frame(height: 220)
    }

    private func seriesColors(_ series: [String]) -> [String: Color] {
        var out: [String: Color] = [:]
        if filterBox.value == nil {
            for p in Provider.allCases { out[p.name] = Theme.accent(p) }
            out["None"] = Theme.track
            return out
        }
        let base = Theme.accent(filterBox.value!)
        let ramp: [Double] = [1, 0.72, 0.52, 0.38, 0.28, 0.2]
        for (i, name) in series.enumerated() { out[name] = base.opacity(ramp[min(i, ramp.count - 1)]) }
        return out
    }

    // MARK: - Models

    private var modelBreakdown: some View {
        let rows = store.stats.models(days: 30, provider: filterBox.value)
        let total = max(rows.reduce(0) { $0 + $1.counts.total }, 1)
        return VStack(spacing: 12) {
            if rows.isEmpty {
                Text("No model usage in the last 30 days.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(rows.prefix(8)) { row in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        ProviderGlyph(provider: row.provider, size: 16, plate: false)
                        Text(row.model).font(.system(size: 12.5, weight: .medium))
                        Spacer()
                        Text(Format.tokens(row.counts.total))
                            .font(.system(size: 12.5, weight: .semibold))
                        Text(Format.percent(Double(row.counts.total) / Double(total) * 100))
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.tertiary)
                            .frame(width: 40, alignment: .trailing)
                    }
                    UsageBar(fraction: Double(row.counts.total) / Double(total), color: Theme.accent(row.provider), height: 4)
                    Text("In \(Format.tokens(row.counts.input)) · Out \(Format.tokens(row.counts.output)) · Cache read \(Format.tokens(row.counts.cacheRead)) · Cache write \(Format.tokens(row.counts.cacheWrite))")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.tertiary)
                }
                .monospacedDigit()
            }
        }
    }

    // MARK: - Limits

    private var limits: some View {
        let accounts = store.accounts.filter { filterBox.value == nil || $0.provider == filterBox.value }
        return LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14) {
            ForEach(accounts) { account in
                AccountCard(account: account, isActive: store.sessions.contains { $0.isBusy && $0.accountKey == account.key })
                    .padding(16)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.04)))
            }
        }
    }
}
