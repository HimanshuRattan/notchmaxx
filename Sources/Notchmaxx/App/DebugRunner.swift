import AppKit
import SwiftUI

/// Command-line modes for development and marketing:
///
/// - `--dump` prints the accounts, sessions and token totals the app sees.
/// - `--render <dir>` writes a PNG of every panel state from your own data.
/// - `--shots <dir>` writes share-ready screenshots, `--video <file.mp4>` renders the promo and
///   `--video-stills <dir>` writes sample frames of it. These three use `DemoData`, never your
///   accounts.
///
/// Add `--offline` to skip network calls. No mode prints tokens or other secrets.
@MainActor
enum DebugRunner {
    static func run(_ args: [String]) {
        NSApplication.shared.setActivationPolicy(.prohibited)
        func url(after flag: String) -> URL? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return URL(fileURLWithPath: args[i + 1])
        }
        Task { @MainActor in
            let store = UsageStore.shared
            if ["--shots", "--video", "--video-stills"].contains(where: args.contains) {
                DemoData.stage(into: store)
            } else {
                await store.refreshLocal()
                if !args.contains("--offline") { await store.refreshLive(force: true) }
            }
            if args.contains("--dump") { dump(store) }
            if let dir = url(after: "--render") { render(store, into: dir) }
            if let dir = url(after: "--shots") { shots(store, into: dir) }
            if let dir = url(after: "--video-stills") { PromoVideo.stills(store: store, to: dir) }
            if let file = url(after: "--video") {
                do {
                    try await PromoVideo.render(store: store, to: file)
                } catch {
                    print("Video failed: \(error)")
                }
            }
            exit(0)
        }
        NSApplication.shared.run()
    }

    private static func dump(_ store: UsageStore) {
        print("== Accounts")
        for a in store.allAccounts {
            print("\(a.provider.name) · \(a.name) · \(a.subtitle) · source=\(a.source.rawValue) · updated=\(Format.relative(a.updatedAt))")
            for w in a.windows {
                let reset = w.resetsAt.map { Format.resetPhrase($0) } ?? "no reset"
                print("   \(w.title): \(Format.percent(w.usedPercent)) · \(reset) · \(Format.paceLabel(w.pace))\(w.detail.map { " · \($0)" } ?? "")")
            }
            if let count = a.resetCreditCount {
                let expiries = a.resetCredits.map { "\($0.title) \($0.expiresAt.map(Format.expiry) ?? "")" }.joined(separator: ", ")
                print("   manual resets: \(count) \(expiries)")
            }
            if let spend = a.spendLine { print("   credits: \(spend)") }
            if let note = a.footnote { print("   note: \(note)") }
            if let error = a.error { print("   error: \(error)") }
        }
        print("== Sessions")
        for s in store.sessions.prefix(8) {
            print("\(s.provider.name) · \(s.project) · busy=\(s.isBusy) · \(Format.duration(Date().timeIntervalSince(s.startedAt))) · \(Format.tokens(s.tokens)) tokens")
        }
        print("== Tokens")
        for p in [Provider.claude, .codex] {
            print("\(p.name): today \(Format.tokens(store.stats.today(provider: p))) · 7d \(Format.tokens(store.stats.total(provider: p, days: 7))) · 30d \(Format.tokens(store.stats.total(provider: p, days: 30)))")
        }
        for a in store.allAccounts where a.provider == .codex {
            print("  Codex \(a.name): 30d \(Format.tokens(store.stats.total(provider: .codex, account: a.key, days: 30)))")
        }
        for m in store.stats.models(days: 30, provider: nil).prefix(6) {
            print("  \(m.model): \(Format.tokens(m.counts.total))")
        }
    }

    private static func render(_ store: UsageStore, into dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let model = NotchModel()
        if let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }),
           let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            model.notchSize = CGSize(width: screen.frame.width - left.width - right.width, height: screen.safeAreaInsets.top)
        } else {
            model.notchSize = CGSize(width: 185, height: 32)
        }
        let settings = SettingsStore.shared

        func notch(_ configure: (NotchModel) -> Void, height: CGFloat) -> some View {
            configure(model)
            return NotchRootView(model: model, store: store, settings: settings, actions: NotchActions())
                .frame(width: 640, height: height)
                .background(Wallpaper())
        }

        for tab in NotchTab.allCases {
            write(notch({ $0.presentation = .expanded; $0.tab = tab }, height: 760), to: dir.appendingPathComponent("panel-\(tab.rawValue).png"))
        }
        if let account = store.accounts.first, let window = account.tightest {
            let alert = AlertItem(kind: .threshold, provider: account.provider, accountName: account.name,
                                  title: "\(window.title) at 90%", message: "\(account.provider.name) · \(account.name) · Resets in 1h 12m",
                                  percent: 90, severity: .critical)
            write(notch({ $0.presentation = .alert; $0.alert = alert }, height: 180), to: dir.appendingPathComponent("alert.png"))
        }
        if let account = store.accounts.first(where: { $0.provider == .codex }) ?? store.accounts.first,
           let window = account.windows.last {
            let alert = AlertItem(kind: .reset, provider: account.provider, accountName: account.name,
                                  title: "\(window.title) limit reset", message: "\(account.provider.name) · \(account.name) is clear again",
                                  percent: 0, severity: .normal)
            write(notch({ $0.presentation = .alert; $0.alert = alert }, height: 180), to: dir.appendingPathComponent("alert-reset.png"))
        }
        let pill = ZStack(alignment: .top) {
            Wallpaper()
            CollapsedNotch(model: model, store: store, showPill: true, inset: 6)
                .background(NotchShape(topRadius: 6, bottomRadius: 11).fill(Color.black))
        }
        .frame(width: 640, height: 80)
        write(pill, to: dir.appendingPathComponent("pill.png"))
        write(UsageWindowView(store: store, scrollable: false).frame(width: 760), to: dir.appendingPathComponent("usage.png"))
        write(SetupView(store: store, openSettings: {}, done: {}), to: dir.appendingPathComponent("setup.png"))
        print("Rendered into \(dir.path)")
    }

    /// Share-ready 2000x1200 images: each state placed on a desktop with a menu bar.
    private static func shots(_ store: UsageStore, into dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let settings = SettingsStore.shared
        let notchSize = CGSize(width: 185, height: 32)

        func scene(_ configure: (NotchModel) -> Void, canvas: CGSize, window: AnyView? = nil) -> some View {
            let model = NotchModel()
            model.notchSize = notchSize
            model.hasPhysicalNotch = true
            configure(model)
            return ZStack(alignment: .top) {
                Desktop()
                if let window { window.padding(.top, notchSize.height + 34) }
                MenuBar(height: notchSize.height)
                NotchRootView(model: model, store: store, settings: settings, actions: NotchActions())
            }
            .frame(width: canvas.width, height: canvas.height)
            .clipped()
        }

        let wide = CGSize(width: 1000, height: 600)
        for tab in [NotchTab.overview, .claude, .codex] {
            write(scene({ $0.presentation = .expanded; $0.tab = tab }, canvas: wide),
                  to: dir.appendingPathComponent("\(tab.rawValue).png"), scale: 2)
        }
        if let account = store.accounts.first(where: { $0.provider == .codex }) ?? store.accounts.first,
           let window = account.windows.last {
            let alert = AlertItem(kind: .reset, provider: account.provider, accountName: account.name,
                                  title: "\(window.title) limit reset", message: "\(account.provider.name) · \(account.name) is clear again",
                                  percent: 0, severity: .normal)
            write(scene({ $0.presentation = .alert; $0.alert = alert }, canvas: CGSize(width: 800, height: 480)),
                  to: dir.appendingPathComponent("reset.png"), scale: 2.5)
        }
        let setup = SetupView(store: store, openSettings: {}, done: {})
            .background(Color(white: 0.08))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.12)))
            .shadow(color: .black.opacity(0.45), radius: 30, y: 14)
        write(scene({ $0.presentation = .collapsed }, canvas: CGSize(width: 1200, height: 720), window: AnyView(setup)),
              to: dir.appendingPathComponent("setup.png"), scale: 2000.0 / 1200)
        print("Rendered into \(dir.path)")
    }

    private static func write<V: View>(_ view: V, to url: URL, scale: CGFloat = 2) {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, .dark))
        renderer.scale = scale
        guard let image = renderer.cgImage else {
            print("Could not render \(url.lastPathComponent)")
            return
        }
        let rep = NSBitmapImageRep(cgImage: image)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}

private struct Wallpaper: View {
    var body: some View {
        LinearGradient(colors: [Color(red: 0.42, green: 0.62, blue: 0.82), Color(red: 0.75, green: 0.84, blue: 0.92)],
                       startPoint: .top, endPoint: .bottom)
    }
}
