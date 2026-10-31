import Foundation
import Observation

@MainActor
@Observable
final class UsageStore {
    static let shared = UsageStore()

    private(set) var accounts: [AccountSnapshot] = []
    private(set) var allAccounts: [AccountSnapshot] = []
    private(set) var sessions: [LiveSession] = []
    private(set) var stats = TokenStats()
    private(set) var lastUpdated: Date?
    private(set) var isRefreshing = false
    private(set) var hasScanned = false
    /// Why a Codex home couldn't be used, for example an API-key sign-in. Shown in Setup.
    private(set) var codexIssue: String?

    @ObservationIgnored var onAlert: ((AlertItem) -> Void)?
    @ObservationIgnored let settings = SettingsStore.shared

    @ObservationIgnored private let scanner = LogScanner()
    @ObservationIgnored private var scan = ScanResult()
    @ObservationIgnored private var claudeLive: [String: ClaudeSource.Usage] = [:]
    @ObservationIgnored private var claudeErrors: [String: String] = [:]
    @ObservationIgnored private var codexAuths: [String: CodexSource.Auth] = [:]
    @ObservationIgnored private var codexLive: [String: CodexSource.Live] = [:]
    @ObservationIgnored private var codexErrors: [String: String] = [:]
    @ObservationIgnored private var cursorLive: CursorSource.Live?
    @ObservationIgnored private var cursorError: String?
    @ObservationIgnored private var lastLiveFetch = Date.distantPast
    @ObservationIgnored private var scanning = false
    @ObservationIgnored private var timers: [Timer] = []
    @ObservationIgnored private let alerts = AlertCenter()

    var isWorking: Bool { sessions.contains(where: \.isBusy) }

    var claudeDirs: [String] { settings.value.claudeConfigDirs.map(\.expandingTilde) }
    var codexHomes: [String] { settings.value.codexHomes.map(\.expandingTilde) }

    func accounts(for provider: Provider) -> [AccountSnapshot] {
        accounts.filter { $0.provider == provider }
    }

    func sessions(for provider: Provider) -> [LiveSession] {
        sessions.filter { $0.provider == provider }
    }

    func start() {
        Task {
            await refreshLocal()
            await refreshLive(force: true)
        }
        schedule(every: 20) { store in await store.refreshLocal() }
        schedule(every: 60) { store in await store.refreshLive(force: false) }
        // Reset times pass without any new data arriving, so re-derive windows on a short tick.
        schedule(every: 15) { store in store.rebuild() }
    }

    private func schedule(every seconds: TimeInterval, _ work: @escaping @MainActor (UsageStore) async -> Void) {
        let timer = Timer(timeInterval: seconds, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in await work(self) }
        }
        timer.tolerance = seconds * 0.2
        RunLoop.main.add(timer, forMode: .common)
        timers.append(timer)
    }

    func refreshAll() async {
        SecretCache.shared.reset()
        await refreshLocal()
        await refreshLive(force: true)
    }

    /// Called when the notch opens, so the panel shows fresh numbers without hammering the APIs.
    func refreshIfStale() {
        Task {
            await refreshLocal()
            if Date().timeIntervalSince(lastLiveFetch) > 90 { await refreshLive(force: true) }
        }
    }

    func refreshLocal() async {
        guard !scanning else { return }
        scanning = true
        defer { scanning = false }
        let roots = ScanRoots(claudeDirs: claudeDirs, codexHomes: codexHomes)
        let scanner = scanner
        scan = await Task.detached(priority: .utility) { await scanner.scan(roots) }.value
        loadCodexAuths()
        hasScanned = true
        lastUpdated = Date()
        rebuild()
    }

    /// Reads each CODEX_HOME's auth.json. It is a local file, so this runs with every local
    /// refresh; logs without an account id are attributed to the login in their home.
    private func loadCodexAuths() {
        codexAuths = [:]
        var issue: String?
        for home in codexHomes {
            do {
                codexAuths[home] = try CodexSource.readAuth(home: home)
            } catch {
                issue = error.localizedDescription
            }
        }
        if codexIssue != issue { codexIssue = issue }
    }

    func refreshLive(force: Bool) async {
        let configured = TimeInterval(settings.value.liveIntervalMinutes * 60)
        let interval = isWorking ? min(configured, 120) : configured
        guard force || Date().timeIntervalSince(lastLiveFetch) >= interval, !isRefreshing else { return }
        isRefreshing = true
        lastLiveFetch = Date()
        let s = settings.value

        async let claude: Void = refreshClaude(enabled: s.liveClaude, force: force)
        async let codex: Void = refreshCodex(enabled: s.liveCodex)
        async let cursor: Void = refreshCursor(enabled: s.liveCursor && s.cursorEnabled)
        _ = await (claude, codex, cursor)

        isRefreshing = false
        lastUpdated = Date()
        rebuild()
    }

    private func refreshClaude(enabled: Bool, force: Bool) async {
        guard enabled else { return }
        for dir in claudeDirs {
            let cached = ClaudeSource.readState(dir: dir).cached
            // Claude Code refreshes its own cache while it runs, so only call out when it is stale.
            if let cached, Date().timeIntervalSince(cached.fetchedAt) < (force ? 60 : 180) { continue }
            do {
                claudeLive[dir] = try await Task.detached { try await ClaudeSource.fetchLive(dir: dir) }.value
                claudeErrors[dir] = nil
            } catch {
                claudeErrors[dir] = error.localizedDescription
            }
        }
    }

    private func refreshCodex(enabled: Bool) async {
        loadCodexAuths()
        guard enabled else { return }
        for auth in codexAuths.values {
            do {
                codexLive[auth.accountID] = try await CodexSource.fetchLive(auth)
                codexErrors[auth.accountID] = nil
            } catch {
                codexErrors[auth.accountID] = error.localizedDescription
            }
        }
    }

    private func refreshCursor(enabled: Bool) async {
        guard enabled, CursorSource.isInstalled else { return }
        do {
            cursorLive = try await Task.detached { try await CursorSource.fetch() }.value
            cursorError = nil
        } catch {
            cursorError = error.localizedDescription
        }
    }

    // MARK: - Assembly

    func rebuild() {
        let now = Date()
        var built: [AccountSnapshot] = []
        built += buildClaude(now: now)
        built += buildCodex(now: now)
        if let cursor = buildCursor(now: now) { built.append(cursor) }
        allAccounts = built
        accounts = built.filter { !settings.value.hiddenAccounts.contains($0.id) }
        sessions = buildSessions(now: now)
        stats = TokenStats(records: remap(scan.records))

        let fired = alerts.evaluate(accounts, settings: settings.value, now: now)
        fired.forEach { onAlert?($0) }
    }

    private func buildClaude(now: Date) -> [AccountSnapshot] {
        claudeDirs.compactMap { dir in
            let state = ClaudeSource.readState(dir: dir)
            let live = claudeLive[dir]
            var usage = state.cached
            var source: DataSource = .cache
            if let live, live.fetchedAt > (usage?.fetchedAt ?? .distantPast) {
                usage = live
                source = .live
            }
            guard state.profile != nil || usage != nil else { return nil }
            let profile = state.profile
            let fallbackName = profile?.isTeam == true ? (profile?.organization ?? "Team") : "Personal"
            let id = "claude:\(dir)"
            var snapshot = AccountSnapshot(
                provider: .claude, key: dir,
                name: settings.displayName(for: id, fallback: fallbackName),
                email: profile?.email, plan: profile?.plan)
            snapshot.windows = (usage?.windows ?? []).map { $0.normalized(now: now) }
            snapshot.spendLine = usage?.spendLine
            snapshot.source = usage == nil ? .none : source
            snapshot.updatedAt = usage?.fetchedAt
            if let error = claudeErrors[dir], now.timeIntervalSince(usage?.fetchedAt ?? .distantPast) > 900 {
                snapshot.error = error
            }
            return snapshot
        }
    }

    private func buildCodex(now: Date) -> [AccountSnapshot] {
        let authByAccount = Dictionary(codexAuths.values.map { ($0.accountID, $0) }, uniquingKeysWith: { a, _ in a })
        let limits = remapLimits(scan.codexRateLimits)
        var ids = Array(authByAccount.keys)
        for id in limits.keys where !ids.contains(id) { ids.append(id) }

        var snapshots: [AccountSnapshot] = ids.compactMap { id in
            let auth = authByAccount[id]
            let live = codexLive[id]
            let log = limits[id]
            if auth == nil, log == nil { return nil }
            let planRaw = live?.plan ?? log?.planType ?? auth?.plan
            let key = "codex:\(id)"
            var s = AccountSnapshot(
                provider: .codex, key: id,
                name: settings.displayName(for: key, fallback: CodexSource.isWorkspacePlan(planRaw) ? "Team" : "Personal"),
                email: auth?.email, plan: CodexSource.planLabel(planRaw))
            if let live, live.fetchedAt >= (log?.at ?? .distantPast) || log == nil {
                s.windows = live.windows.map { $0.normalized(now: now) }
                s.source = .live
                s.updatedAt = live.fetchedAt
            } else if let log {
                s.windows = CodexSource.windows(fromLog: log, now: now)
                // Keep extra per-model limits from the last live read; logs only carry the main ones.
                if let live { s.windows += live.windows.filter { !$0.isPrimary }.map { $0.normalized(now: now) } }
                s.source = .logs
                s.updatedAt = log.at
            }
            if let live {
                s.resetCreditCount = live.resetCount
                s.resetCredits = live.resetCredits
                s.spendLine = live.creditsLine
            } else if let log {
                if log.unlimited == true {
                    s.spendLine = "Unlimited credits"
                } else if log.hasCredits == true, let balance = Double(log.balance ?? ""), balance > 0 {
                    s.spendLine = "\(Int(balance.rounded())) credits left"
                }
            }
            if auth == nil {
                s.footnote = "Seen in Codex session logs. Sign it in to its own CODEX_HOME for manual resets."
            }
            if let error = codexErrors[id], s.source != .live, now.timeIntervalSince(s.updatedAt ?? .distantPast) > 900 {
                s.error = error
            }
            return s
        }
        snapshots.sort { lhs, rhs in
            if (lhs.email != nil) != (rhs.email != nil) { return lhs.email != nil }
            return lhs.name < rhs.name
        }
        return snapshots
    }

    private func buildCursor(now: Date) -> AccountSnapshot? {
        guard settings.value.cursorEnabled, cursorLive != nil || CursorSource.isInstalled else { return nil }
        let key = "cursor:default"
        var s = AccountSnapshot(
            provider: .cursor, key: "default",
            name: settings.displayName(for: key, fallback: "Cursor"),
            email: cursorLive?.email, plan: cursorLive?.plan)
        if let live = cursorLive {
            s.windows = live.windows.map { $0.normalized(now: now) }
            s.footnote = live.footnote
            s.source = .live
            s.updatedAt = live.fetchedAt
        }
        s.error = cursorError
        return s
    }

    /// Shows fixed data instead of what's on this Mac, for screenshots and the promo video.
    /// It holds until the next rebuild, which only the app's timers trigger.
    func stage(_ staged: [AccountSnapshot], sessions stagedSessions: [LiveSession], stats stagedStats: TokenStats) {
        allAccounts = staged
        accounts = staged
        sessions = stagedSessions
        stats = stagedStats
        hasScanned = true
        lastUpdated = Date()
    }

    private func buildSessions(now: Date) -> [LiveSession] {
        var result: [LiveSession] = []
        var claudeIDs = Set<String>()
        for dir in claudeDirs {
            let folder = dir + "/sessions"
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
            for name in names where name.hasSuffix(".json") {
                guard let json = JSONValue.readFile(folder + "/" + name),
                      let pid = JSONValue.int(json["pid"]), Self.isAlive(pid) else { continue }
                let sessionID = (json["sessionId"] as? String) ?? name
                let busy = (json["status"] as? String) == "busy"
                let updated = DateParse.iso(json["updatedAt"]) ?? .distantPast
                guard busy || now.timeIntervalSince(updated) < 600 else { continue }
                let cwd = (json["cwd"] as? String) ?? ""
                claudeIDs.insert(sessionID)
                result.append(LiveSession(
                    id: sessionID, provider: .claude, accountKey: dir,
                    project: cwd.isEmpty ? "Session" : URL(fileURLWithPath: cwd).lastPathComponent,
                    startedAt: DateParse.iso(json["startedAt"]) ?? updated,
                    lastActivity: updated, isBusy: busy,
                    tokens: scan.claudeSessionTokens[sessionID] ?? 0))
            }
        }
        result += scan.claudeRecent.filter { !claudeIDs.contains($0.id) }
        result += scan.codexSessions.map { session in
            var copy = session
            copy.accountKey = session.accountKey.map(remapAccount)
            return copy
        }
        return result.sorted {
            if $0.isBusy != $1.isBusy { return $0.isBusy }
            return $0.lastActivity > $1.lastActivity
        }
    }

    private static func isAlive(_ pid: Int) -> Bool {
        kill(pid_t(pid), 0) == 0 || errno == EPERM
    }

    /// Codex logs identify accounts only by plan ("plan:team"), because a thread's creator id
    /// stays fixed when T3 Code switches the thread to another account. Map a plan onto a
    /// signed-in account when one matches; otherwise it stays a log-only account.
    private func remapAccount(_ account: String) -> String {
        guard account.hasPrefix("plan:") else { return account }
        let plan = String(account.dropFirst(5))
        let auths = codexAuths.values.sorted { $0.accountID < $1.accountID }
        if plan == "unknown" {
            return auths.count == 1 ? auths[0].accountID : account
        }
        func planOf(_ auth: CodexSource.Auth) -> String? { codexLive[auth.accountID]?.plan ?? auth.plan }
        if let exact = auths.first(where: { planOf($0) == plan }) {
            return exact.accountID
        }
        // Plan names differ between the id token and usage data (for example "pro" and
        // "promax"), so fall back to matching personal against workspace plans.
        let sameKind = auths.filter { CodexSource.isWorkspacePlan(planOf($0)) == CodexSource.isWorkspacePlan(plan) }
        return sameKind.count == 1 ? sameKind[0].accountID : account
    }

    private func remap(_ records: [UsageRecord]) -> [UsageRecord] {
        records.map { record in
            guard record.provider == .codex else { return record }
            var copy = record
            copy.account = remapAccount(record.account)
            return copy
        }
    }

    private func remapLimits(_ limits: [String: CodexRateLimitLog]) -> [String: CodexRateLimitLog] {
        var out: [String: CodexRateLimitLog] = [:]
        for (account, log) in limits {
            let id = remapAccount(account)
            if let existing = out[id], existing.at >= log.at { continue }
            out[id] = log
        }
        return out
    }
}
