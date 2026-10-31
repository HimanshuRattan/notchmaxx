import Foundation

struct CodexRateLimitLog: Codable, Sendable {
    struct Window: Codable, Sendable {
        var usedPercent: Double
        var windowMinutes: Int?
        var resetsAt: Date?
    }

    var at: Date
    var planType: String?
    var primary: Window?
    var secondary: Window?
    var hasCredits: Bool?
    var unlimited: Bool?
    var balance: String?
}

struct ScanRoots: Sendable, Hashable {
    var claudeDirs: [String]
    var codexHomes: [String]
}

struct ScanResult: Sendable {
    var records: [UsageRecord] = []
    /// Claude session id → tokens across the main transcript and its subagents.
    var claudeSessionTokens: [String: Int] = [:]
    /// Claude transcripts written in the last two minutes, for sessions launched outside the CLI.
    var claudeRecent: [LiveSession] = []
    var codexSessions: [LiveSession] = []
    /// Latest rate-limit snapshot per Codex plan, keyed "plan:<plan_type>".
    var codexRateLimits: [String: CodexRateLimitLog] = [:]
}

private struct FileState: Codable {
    var provider: Provider
    var root: String
    var size: UInt64 = 0
    var offset: UInt64 = 0
    var model = ""
    var cwd: String?
    var sessionId: String?
    var startedAt: Date?
    var modifiedAt: Date?
    var busy = false
    var lastCumulative: TokenCounts?
    var sessionTokens = 0
    var buckets: [String: TokenCounts] = [:]
    var ids: [String] = []
    /// Codex: latest snapshot per plan, and the plan of the most recent snapshot. A thread can
    /// switch accounts midway, so usage is attributed to the plan active when it happened.
    var rateLimitsByPlan: [String: CodexRateLimitLog] = [:]
    var plan: String?
}

private struct Needle {
    let bytes: [UInt8]
    init(_ s: String) { bytes = Array(s.utf8) }

    func isIn(_ line: UnsafeRawBufferPointer) -> Bool {
        guard let base = line.baseAddress, line.count >= bytes.count else { return false }
        return bytes.withUnsafeBytes { memmem(base, line.count, $0.baseAddress, $0.count) != nil }
    }
}

/// Reads Claude Code transcripts and Codex rollouts incrementally. Each file remembers how far
/// it was read, so a rescan only parses lines appended since the previous pass.
actor LogScanner {
    static let retentionDays = 32

    private var files: [String: FileState] = [:]
    private var seenClaudeIds: Set<String> = []
    private var loaded = false
    private var dirty = false
    private var lastSave = Date.distantPast
    private let cacheURL = Paths.appSupport.appendingPathComponent("scan-cache-v2.json")

    private static let assistant = Needle(#""type":"assistant""#)
    private static let codexNeedles = [
        Needle(#""session_meta""#), Needle(#""turn_context""#), Needle(#""token_count""#),
        Needle(#""task_started""#), Needle(#""task_complete""#), Needle(#""turn_aborted""#),
    ]

    func scan(_ roots: ScanRoots) -> ScanResult {
        if !loaded {
            load()
            loaded = true
        }
        let cutoff = Date().addingTimeInterval(-Double(Self.retentionDays) * 86_400)
        var present = Set<String>()
        for dir in roots.claudeDirs {
            for entry in Self.jsonlFiles(under: dir + "/projects", cutoff: cutoff) {
                present.insert(entry.path)
                update(entry, provider: .claude, root: dir)
            }
        }
        for home in roots.codexHomes {
            for sub in ["sessions", "archived_sessions"] {
                for entry in Self.jsonlFiles(under: home + "/" + sub, cutoff: cutoff) {
                    present.insert(entry.path)
                    update(entry, provider: .codex, root: home)
                }
            }
        }
        for path in files.keys where !present.contains(path) {
            forget(path)
        }
        saveIfNeeded()
        return buildResult()
    }

    // MARK: - Files

    private struct Entry {
        var path: String
        var size: UInt64
        var modified: Date
    }

    private static func jsonlFiles(under root: String, cutoff: Date) -> [Entry] {
        let url = URL(fileURLWithPath: root, isDirectory: true)
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else {
            return []
        }
        var out: [Entry] = []
        for case let file as URL in walker where file.pathExtension == "jsonl" {
            guard let values = try? file.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate,
                  modified >= cutoff else { continue }
            out.append(Entry(path: file.path, size: UInt64(values.fileSize ?? 0), modified: modified))
        }
        return out
    }

    private func update(_ entry: Entry, provider: Provider, root: String) {
        if let existing = files[entry.path], existing.size == entry.size, existing.modifiedAt == entry.modified {
            return
        }
        var state = files[entry.path] ?? FileState(provider: provider, root: root)
        if entry.size < state.offset {
            forget(entry.path)
            state = FileState(provider: provider, root: root)
        }
        state.size = entry.size
        state.modifiedAt = entry.modified
        let fallbackDate = entry.modified
        state.offset = Self.readLines(path: entry.path, from: state.offset) { line in
            switch provider {
            case .claude: self.handleClaude(line, state: &state, fallbackDate: fallbackDate)
            case .codex: self.handleCodex(line, state: &state, fallbackDate: fallbackDate)
            case .cursor: break
            }
        }
        files[entry.path] = state
        dirty = true
    }

    private func forget(_ path: String) {
        guard let state = files.removeValue(forKey: path) else { return }
        for id in state.ids { seenClaudeIds.remove(id) }
        dirty = true
    }

    /// Calls `body` for each complete line after `offset` and returns the offset just past
    /// the last newline, so a half-written final line is read again on the next pass.
    private static func readLines(path: String, from offset: UInt64, _ body: (UnsafeRawBufferPointer) -> Void) -> UInt64 {
        guard let handle = FileHandle(forReadingAtPath: path) else { return offset }
        defer { try? handle.close() }
        do { try handle.seek(toOffset: offset) } catch { return offset }
        var consumed = offset
        var pending = Data()
        while true {
            let chunk = autoreleasepool { handle.readData(ofLength: 4 << 20) }
            if chunk.isEmpty { break }
            pending.append(chunk)
            var used = 0
            pending.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                var start = 0
                while start < raw.count, let nl = memchr(base + start, 0x0A, raw.count - start) {
                    let end = base.distance(to: UnsafeRawPointer(nl))
                    if end > start {
                        body(UnsafeRawBufferPointer(start: base + start, count: end - start))
                    }
                    start = end + 1
                }
                used = start
            }
            consumed += UInt64(used)
            if used > 0 { pending = Data(pending.dropFirst(used)) }
        }
        return consumed
    }

    private static func object(_ line: UnsafeRawBufferPointer) -> [String: Any]? {
        guard let base = line.baseAddress else { return nil }
        let data = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: base), count: line.count, deallocator: .none)
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    // MARK: - Claude

    private func handleClaude(_ line: UnsafeRawBufferPointer, state: inout FileState, fallbackDate: Date) {
        guard Self.assistant.isIn(line),
              let obj = Self.object(line),
              obj["type"] as? String == "assistant",
              let message = obj["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any] else { return }
        if state.sessionId == nil { state.sessionId = obj["sessionId"] as? String }
        if let cwd = obj["cwd"] as? String { state.cwd = cwd }
        let model = (message["model"] as? String) ?? ""
        if model == "<synthetic>" { return }
        // Claude Code writes one line per content block with the same message id and usage,
        // and resumed sessions copy earlier messages, so count each message id once.
        if let id = message["id"] as? String {
            if seenClaudeIds.contains(id) { return }
            seenClaudeIds.insert(id)
            state.ids.append(id)
        }
        var counts = TokenCounts()
        counts.input = JSONValue.int(usage["input_tokens"]) ?? 0
        counts.output = JSONValue.int(usage["output_tokens"]) ?? 0
        counts.cacheRead = JSONValue.int(usage["cache_read_input_tokens"]) ?? 0
        counts.cacheWrite = JSONValue.int(usage["cache_creation_input_tokens"]) ?? 0
        let date = DateParse.iso(obj["timestamp"]) ?? fallbackDate
        if state.startedAt == nil { state.startedAt = date }
        if !model.isEmpty { state.model = model }
        state.buckets[TokenStats.dayKey(date) + "|" + model, default: TokenCounts()].add(counts)
        state.sessionTokens += counts.total
    }

    // MARK: - Codex

    private func handleCodex(_ line: UnsafeRawBufferPointer, state: inout FileState, fallbackDate: Date) {
        guard Self.codexNeedles.contains(where: { $0.isIn(line) }),
              let obj = Self.object(line),
              let payload = obj["payload"] as? [String: Any] else { return }
        let date = DateParse.iso(obj["timestamp"]) ?? fallbackDate
        switch obj["type"] as? String {
        case "session_meta":
            state.cwd = (payload["cwd"] as? String) ?? state.cwd
            state.sessionId = (payload["id"] as? String) ?? state.sessionId
            state.startedAt = DateParse.iso(payload["timestamp"]) ?? date
        case "turn_context":
            state.model = (payload["model"] as? String) ?? state.model
            state.cwd = (payload["cwd"] as? String) ?? state.cwd
        case "event_msg":
            switch payload["type"] as? String {
            case "task_started": state.busy = true
            case "task_complete", "turn_aborted": state.busy = false
            case "token_count": handleTokenCount(payload, date: date, state: &state)
            default: break
            }
        default:
            break
        }
    }

    private func handleTokenCount(_ payload: [String: Any], date: Date, state: inout FileState) {
        // Read the snapshot first: it says which plan the tokens in this same event used.
        if let limits = payload["rate_limits"] as? [String: Any] {
            let snapshot = Self.rateLimitLog(limits, at: date)
            if let plan = snapshot.planType {
                state.plan = plan
                state.rateLimitsByPlan[plan] = snapshot
            }
        }
        guard let info = payload["info"] as? [String: Any],
              let total = info["total_token_usage"] as? [String: Any] else { return }
        let input = JSONValue.int(total["input_tokens"]) ?? 0
        let cached = JSONValue.int(total["cached_input_tokens"]) ?? 0
        var cumulative = TokenCounts()
        cumulative.input = max(input - cached, 0)
        cumulative.cacheRead = cached
        cumulative.cacheWrite = JSONValue.int(total["cache_write_input_tokens"]) ?? 0
        cumulative.output = JSONValue.int(total["output_tokens"]) ?? 0
        var delta = cumulative
        if let last = state.lastCumulative {
            delta.input -= last.input
            delta.output -= last.output
            delta.cacheRead -= last.cacheRead
            delta.cacheWrite -= last.cacheWrite
            // A smaller cumulative total means the thread restarted its counter.
            if delta.input < 0 || delta.output < 0 || delta.cacheRead < 0 || delta.cacheWrite < 0 {
                delta = cumulative
            }
        }
        state.lastCumulative = cumulative
        guard delta.total > 0 else { return }
        let key = [TokenStats.dayKey(date), state.model, state.plan ?? "unknown"].joined(separator: "|")
        state.buckets[key, default: TokenCounts()].add(delta)
        state.sessionTokens += delta.total
    }

    static func rateLimitLog(_ limits: [String: Any], at date: Date) -> CodexRateLimitLog {
        func window(_ value: Any?) -> CodexRateLimitLog.Window? {
            guard let w = value as? [String: Any], let used = JSONValue.double(w["used_percent"]) else { return nil }
            return .init(
                usedPercent: used,
                windowMinutes: JSONValue.int(w["window_minutes"]),
                resetsAt: JSONValue.double(w["resets_at"]).map { Date(timeIntervalSince1970: $0) }
            )
        }
        let credits = limits["credits"] as? [String: Any]
        return CodexRateLimitLog(
            at: date,
            planType: limits["plan_type"] as? String,
            primary: window(limits["primary"]),
            secondary: window(limits["secondary"]),
            hasCredits: JSONValue.bool(credits?["has_credits"]),
            unlimited: JSONValue.bool(credits?["unlimited"]),
            balance: credits?["balance"] as? String
        )
    }

    // MARK: - Result

    private func buildResult() -> ScanResult {
        var result = ScanResult()
        var aggregate: [String: UsageRecord] = [:]
        let now = Date()
        for (path, state) in files {
            for (key, counts) in state.buckets {
                let parts = key.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
                guard parts.count >= 2 else { continue }
                let account = state.provider == .claude ? state.root : "plan:" + (parts.count > 2 ? parts[2] : "unknown")
                let id = "\(parts[0])|\(state.provider.rawValue)|\(account)|\(parts[1])"
                aggregate[id, default: UsageRecord(day: parts[0], provider: state.provider, account: account, model: parts[1], counts: TokenCounts())]
                    .counts.add(counts)
            }
            let modified = state.modifiedAt ?? .distantPast
            let project = state.cwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Session"
            switch state.provider {
            case .claude:
                if let sid = state.sessionId {
                    result.claudeSessionTokens[sid, default: 0] += state.sessionTokens
                }
                if now.timeIntervalSince(modified) < 120, !path.contains("/subagents/") {
                    result.claudeRecent.append(LiveSession(
                        id: state.sessionId ?? path, provider: .claude, accountKey: state.root,
                        project: project, startedAt: state.startedAt ?? modified, lastActivity: modified,
                        isBusy: now.timeIntervalSince(modified) < 60, tokens: state.sessionTokens))
                }
            case .codex:
                let idle = now.timeIntervalSince(modified)
                let busy = (state.busy && idle < 600) || idle < 45
                if idle < 600 {
                    result.codexSessions.append(LiveSession(
                        id: state.sessionId ?? path, provider: .codex, accountKey: "plan:" + (state.plan ?? "unknown"),
                        project: project, startedAt: state.startedAt ?? modified, lastActivity: modified,
                        isBusy: busy, tokens: state.sessionTokens))
                }
                for (plan, limits) in state.rateLimitsByPlan {
                    let key = "plan:" + plan
                    if let existing = result.codexRateLimits[key], existing.at >= limits.at { continue }
                    result.codexRateLimits[key] = limits
                }
            case .cursor:
                break
            }
        }
        result.records = Array(aggregate.values)
        result.codexSessions.sort { $0.lastActivity > $1.lastActivity }
        return result
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: cacheURL),
              let decoded = try? JSONDecoder().decode([String: FileState].self, from: data) else { return }
        files = decoded
        for state in decoded.values { seenClaudeIds.formUnion(state.ids) }
    }

    private func saveIfNeeded() {
        guard dirty, Date().timeIntervalSince(lastSave) > 60 else { return }
        guard let data = try? JSONEncoder().encode(files) else { return }
        try? data.write(to: cacheURL, options: .atomic)
        dirty = false
        lastSave = Date()
    }
}
