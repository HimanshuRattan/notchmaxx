import SwiftUI

/// Black shape that grows out of the hardware notch: concave top corners that meet the
/// menu bar and rounded bottom corners.
struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set { topRadius = newValue.first; bottomRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let t = min(topRadius, rect.width / 4)
        let b = min(bottomRadius, rect.height / 2, (rect.width - 2 * t) / 2)
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.minX + t, y: rect.minY + t), control: CGPoint(x: rect.minX + t, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + t, y: rect.maxY - b))
        p.addQuadCurve(to: CGPoint(x: rect.minX + t + b, y: rect.maxY), control: CGPoint(x: rect.minX + t, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - t - b, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - t, y: rect.maxY - b), control: CGPoint(x: rect.maxX - t, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - t, y: rect.minY + t))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: rect.maxX - t, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

struct NotchRootView: View {
    @Bindable var model: NotchModel
    var store: UsageStore
    var settings: SettingsStore
    var actions: NotchActions

    private var expanded: Bool { model.presentation != .collapsed }
    private var topRadius: CGFloat { expanded ? 14 : 6 }
    private var bottomRadius: CGFloat { expanded ? 28 : 11 }

    private var showPill: Bool {
        switch settings.value.pillMode {
        case .always: true
        case .never: false
        case .whenWorking: store.isWorking
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                switch model.presentation {
                case .collapsed:
                    CollapsedNotch(model: model, store: store, showPill: showPill, inset: topRadius)
                        .transition(.opacity.animation(.easeOut(duration: 0.12)))
                case .expanded:
                    ExpandedPanel(model: model, store: store, actions: actions, inset: topRadius)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.97, anchor: .top)).animation(.easeOut(duration: 0.22).delay(0.08)),
                            removal: .opacity.animation(.easeIn(duration: 0.1))))
                case .alert:
                    if let alert = model.alert {
                        AlertBanner(alert: alert, notch: model.notchSize, inset: topRadius)
                            .transition(.opacity.animation(.easeOut(duration: 0.2).delay(0.06)))
                    }
                }
            }
            .background(
                NotchShape(topRadius: topRadius, bottomRadius: bottomRadius)
                    .fill(Color.black)
                    .opacity(collapsedAndInvisible ? 0 : 1)
            )
            .clipShape(NotchShape(topRadius: topRadius, bottomRadius: bottomRadius))
            .background(GeometryReader { geo in
                // Preference callbacks don't fire reliably inside this NSHostingView, so push
                // the size straight into the model; the window controller hit-tests with it.
                Color.clear
                    .onAppear { model.shellSize = geo.size }
                    .onChange(of: geo.size) { _, size in model.shellSize = size }
            })
            .shadow(color: .black.opacity(expanded ? 0.55 : 0), radius: 24, y: 10)
            .animation(.spring(response: 0.42, dampingFraction: 0.82), value: model.presentation)
            .animation(.spring(response: 0.42, dampingFraction: 0.82), value: showPill)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
        .onAppear { model.showsCursor = settings.value.cursorEnabled }
        .onChange(of: settings.value.cursorEnabled) { _, enabled in
            model.showsCursor = enabled
            if !enabled && model.tab == .cursor { model.tab = .overview }
        }
    }

    /// Without a hardware notch there is nothing to blend into, so stay hidden until needed.
    private var collapsedAndInvisible: Bool {
        model.presentation == .collapsed && !showPill && !model.hasPhysicalNotch
    }
}

// MARK: - Collapsed

struct CollapsedNotch: View {
    var model: NotchModel
    var store: UsageStore
    var showPill: Bool
    var inset: CGFloat

    private var activeSession: LiveSession? { store.sessions.first(where: \.isBusy) ?? store.sessions.first }

    private var focusWindow: (LimitWindow, Provider)? {
        let provider = activeSession?.provider
        let candidates = store.accounts.filter { provider == nil || $0.provider == provider }
        let accountKey = activeSession?.accountKey
        let account = candidates.first(where: { $0.key == accountKey }) ?? candidates.max {
            ($0.tightest?.usedPercent ?? 0) < ($1.tightest?.usedPercent ?? 0)
        }
        guard let account, let window = account.primaryWindows.max(by: { $0.usedPercent < $1.usedPercent }) else { return nil }
        return (window, account.provider)
    }

    var body: some View {
        let ext = showPill ? NotchModel.pillExtension : 0
        HStack(spacing: 0) {
            if showPill {
                HStack(spacing: 7) {
                    ProviderGlyph(provider: activeSession?.provider ?? focusWindow?.1 ?? .claude, size: 15, plate: false)
                    if store.isWorking { StatusDot(color: Theme.good, pulsing: true) }
                }
                .frame(width: ext, alignment: .center)
                .transition(.opacity)
            }
            Color.clear.frame(width: model.notchSize.width)
            if showPill {
                Group {
                    if let (window, provider) = focusWindow {
                        Text(Format.percent(window.usedPercent))
                            .foregroundStyle(window.usedPercent >= 90 ? Theme.bad : Theme.accent(provider))
                    } else {
                        Text("–").foregroundStyle(Theme.tertiary)
                    }
                }
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
                .frame(width: ext, alignment: .center)
                .transition(.opacity)
            }
        }
        .frame(height: model.notchSize.height)
        .padding(.horizontal, inset)
    }
}

// MARK: - Expanded

struct ExpandedPanel: View {
    @Bindable var model: NotchModel
    var store: UsageStore
    var actions: NotchActions
    var inset: CGFloat
    @Namespace private var tabSpace

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { _ in
            VStack(spacing: 0) {
                topBand
                tabBar
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                Group {
                    switch model.tab {
                    case .overview: OverviewTab(model: model, store: store, actions: actions)
                    default: ProviderTab(provider: model.tab.provider!, store: store)
                    }
                }
                .id(model.tab)
                .transition(.opacity)
                .padding(.horizontal, 20)
                .padding(.top, 16)
                footer
            }
            .frame(width: NotchModel.panelWidth)
        }
        .padding(.horizontal, inset)
    }

    private var topBand: some View {
        HStack(spacing: 0) {
            HStack(spacing: 7) {
                let running = store.sessions.filter(\.isBusy).count
                StatusDot(color: running > 0 ? Theme.good : Theme.tertiary, pulsing: running > 0)
                Text(running > 0 ? "\(running) agent\(running == 1 ? "" : "s") working" : "No agents running")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 22)
            Color.clear.frame(width: model.notchSize.width)
            HStack(spacing: 14) {
                IconButton(systemImage: "arrow.clockwise", spinning: store.isRefreshing, action: actions.refresh)
                IconButton(systemImage: "gearshape", action: actions.openSettings)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.trailing, 22)
        }
        .frame(height: max(model.notchSize.height, 30))
    }

    private var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(model.tabs) { tab in
                let selected = model.tab == tab
                Button {
                    model.select(tab)
                } label: {
                    HStack(spacing: 6) {
                        if let provider = tab.provider {
                            ProviderGlyph(provider: provider, size: 12, plate: false)
                                .opacity(selected ? 1 : 0.6)
                        }
                        Text(tab.title)
                            .font(.system(size: 12, weight: selected ? .semibold : .medium))
                        if let severity = severity(for: tab), severity > .normal {
                            Circle().fill(Theme.color(severity)).frame(width: 5, height: 5)
                        }
                    }
                    .foregroundStyle(selected ? Theme.primary : Theme.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background {
                        if selected && model.tabGlide == nil {
                            Capsule()
                                .fill(Color.white.opacity(0.12))
                                .overlay(Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))
                                .matchedGeometryEffect(id: "tab", in: tabSpace)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .background(alignment: .leading) {
            if let glide = model.tabGlide {
                GeometryReader { geo in
                    let count = CGFloat(model.tabs.count)
                    let width = (geo.size.width - 2 * (count - 1)) / count
                    Capsule()
                        .fill(Color.white.opacity(0.12))
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))
                        .frame(width: width, height: geo.size.height)
                        .offset(x: glide * (width + 2))
                }
            }
        }
        .padding(3)
        .background(Capsule().fill(Color.white.opacity(0.045)))
    }

    private func severity(for tab: NotchTab) -> Severity? {
        guard let provider = tab.provider else { return nil }
        return store.accounts(for: provider).map(\.severity).max()
    }

    private var footer: some View {
        HStack {
            Text("Updated \(Format.relative(store.lastUpdated))")
            Spacer()
            Button(action: actions.openUsage) {
                HStack(spacing: 4) {
                    Text("Usage")
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                }
                .foregroundStyle(Theme.primary.opacity(0.85))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(Theme.fill))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .font(.system(size: 11))
        .foregroundStyle(Theme.tertiary)
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 14)
    }
}

struct IconButton: View {
    var systemImage: String
    var spinning = false
    var action: () -> Void
    @StateObject private var hovering = Box(false)

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(hovering.value ? Theme.primary : Theme.secondary)
                .rotationEffect(.degrees(spinning ? 360 : 0))
                .animation(spinning ? .linear(duration: 0.9).repeatForever(autoreverses: false) : .default, value: spinning)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering.value = $0 }
    }
}

// MARK: - Tabs

struct OverviewTab: View {
    var model: NotchModel
    var store: UsageStore
    var actions: NotchActions

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if store.accounts.isEmpty {
                EmptyState(
                    title: store.hasScanned ? "No tools connected yet" : "Reading your sign-ins…",
                    message: "Notchmaxx reads the logins Claude Code, Codex and Cursor already have.",
                    actionTitle: "Run setup", action: actions.openSetup)
            } else {
                ForEach(store.sessions.filter(\.isBusy).prefix(2)) { session in
                    SessionRow(session: session, todayTokens: store.stats.today(provider: session.provider, account: session.accountKey))
                }
                VStack(spacing: 0) {
                    ForEach(Array(store.accounts.enumerated()), id: \.element.id) { index, account in
                        if index > 0 { Divider().overlay(Theme.hairline) }
                        OverviewRow(account: account)
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                            .onTapGesture { model.select(NotchTab(account.provider)) }
                    }
                }
                TodayStrip(stats: store.stats)
            }
        }
    }
}

struct OverviewRow: View {
    var account: AccountSnapshot

    var body: some View {
        HStack(spacing: 11) {
            ProviderGlyph(provider: account.provider, size: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(account.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.primary)
                    .lineLimit(1)
                Text(account.plan ?? account.provider.name)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            let windows = Array(account.primaryWindows.prefix(2))
            if windows.isEmpty {
                Text(account.error ?? "No data yet")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiary)
                    .lineLimit(1)
            } else {
                HStack(spacing: 14) {
                    // Keep the weekly column aligned across rows when a plan has no 5-hour window.
                    if windows.count == 1 { Color.clear.frame(width: 76, height: 1) }
                    ForEach(windows) { MiniMeter(window: $0, provider: account.provider) }
                }
            }
        }
    }
}

struct TodayStrip: View {
    var stats: TokenStats

    var body: some View {
        let parts = Provider.allCases.compactMap { p -> (Provider, Int)? in
            let n = stats.today(provider: p)
            return n > 0 ? (p, n) : nil
        }
        HStack(spacing: 10) {
            Text("Today")
                .foregroundStyle(Theme.tertiary)
            Text(Format.tokens(stats.today()))
                .fontWeight(.semibold)
                .foregroundStyle(Theme.primary)
            + Text(" tokens").foregroundColor(Theme.tertiary)
            Spacer()
            ForEach(parts, id: \.0) { provider, tokens in
                HStack(spacing: 5) {
                    Circle().fill(Theme.accent(provider)).frame(width: 5, height: 5)
                    Text("\(provider.name) \(Format.tokens(tokens))")
                        .foregroundStyle(Theme.secondary)
                }
            }
        }
        .font(.system(size: 11))
        .monospacedDigit()
        .padding(.top, 2)
    }
}

struct ProviderTab: View {
    var provider: Provider
    var store: UsageStore

    var body: some View {
        let accounts = store.accounts(for: provider)
        let sessions = store.sessions(for: provider)
        VStack(alignment: .leading, spacing: 14) {
            if accounts.isEmpty {
                EmptyState(title: "\(provider.name) isn't connected", message: hint, actionTitle: nil, action: nil)
            }
            ForEach(Array(accounts.enumerated()), id: \.element.id) { index, account in
                if index > 0 { Divider().overlay(Theme.hairline).padding(.vertical, 2) }
                AccountCard(account: account, isActive: sessions.contains { $0.isBusy && $0.accountKey == account.key })
            }
            ForEach(sessions.prefix(2)) { session in
                SessionRow(session: session, todayTokens: store.stats.today(provider: provider, account: session.accountKey))
            }
        }
    }

    private var hint: String {
        switch provider {
        case .claude: "Sign in with `claude` in a terminal, then it shows up here."
        case .codex: "Run `codex login`. Extra accounts can live in their own CODEX_HOME, added in Settings."
        case .cursor: "Sign in to Cursor or the Cursor CLI. Usage comes from Cursor's dashboard data."
        }
    }
}

struct EmptyState: View {
    var title: String
    var message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.primary)
            Text(.init(message))
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5, weight: .medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.white.opacity(0.1)))
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
    }
}

// MARK: - Alert

struct AlertBanner: View {
    var alert: AlertItem
    var notch: CGSize
    var inset: CGFloat
    /// 0 to 1 draws the reset check in: the disc springs up, then the tick strokes across.
    var checkProgress: Double = 1

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: notch.height)
            HStack(spacing: 12) {
                ProviderGlyph(provider: alert.provider, size: 30)
                VStack(alignment: .leading, spacing: 3) {
                    Text(alert.title)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(Theme.primary)
                    Text(alert.message)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 10)
                if alert.kind == .reset {
                    CheckBadge(progress: checkProgress)
                } else if let percent = alert.percent {
                    Text(Format.percent(percent))
                        .font(.system(size: 20, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Theme.color(alert.severity))
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 10)
            .padding(.bottom, 18)
        }
        .frame(width: 400)
        .padding(.horizontal, inset)
    }
}

struct CheckBadge: View {
    var progress: Double
    var size: CGFloat = 20

    var body: some View {
        let disc = min(max(progress / 0.55, 0), 1)
        // Ease out with a little overshoot, so the disc lands like a spring.
        let pop = 1 + 2.2 * pow(disc - 1, 3) + 1.2 * pow(disc - 1, 2)
        ZStack {
            Circle().fill(Theme.good).scaleEffect(disc == 0 ? 0 : pop)
            Tick()
                .trim(from: 0, to: min(max((progress - 0.35) / 0.55, 0), 1))
                .stroke(Color.black, style: StrokeStyle(lineWidth: size * 0.11, lineCap: .round, lineJoin: .round))
                .frame(width: size * 0.46, height: size * 0.36)
        }
        .frame(width: size, height: size)
    }
}

struct Tick: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.55))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.36, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        return path
    }
}
