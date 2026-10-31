import Foundation

/// Reads secrets that coding tools already stored. Nothing here writes to the keychain
/// or refreshes tokens, because rotating a token would sign the owning tool out.
enum Keychain {
    static func genericPassword(service: String, account: String? = nil, timeout: TimeInterval = 20) -> String? {
        var args = ["find-generic-password", "-s", service]
        if let account { args += ["-a", account] }
        args.append("-w")
        guard let out = Shell.run("/usr/bin/security", args, timeout: timeout) else { return nil }
        let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Keeps secrets in memory for the life of the app so the keychain is only asked again
/// when a token stops working, not on every refresh.
final class SecretCache: @unchecked Sendable {
    static let shared = SecretCache()
    private var values: [String: String] = [:]
    private var misses: [String: Date] = [:]
    private let lock = NSLock()

    func value(for key: String, load: () -> String?) -> String? {
        lock.lock()
        if let hit = values[key] {
            lock.unlock()
            return hit
        }
        // After a miss (not signed in, or a keychain prompt was declined) wait before asking again.
        if let miss = misses[key], Date().timeIntervalSince(miss) < 1800 {
            lock.unlock()
            return nil
        }
        lock.unlock()
        let loaded = load()
        lock.lock()
        values[key] = loaded
        misses[key] = loaded == nil ? Date() : nil
        lock.unlock()
        return loaded
    }

    func invalidate(_ key: String) {
        lock.lock()
        values[key] = nil
        lock.unlock()
    }

    func reset() {
        lock.lock()
        values.removeAll()
        misses.removeAll()
        lock.unlock()
    }
}

enum Shell {
    /// Runs a tool and returns stdout, or nil on failure or timeout.
    static func run(_ path: String, _ args: [String], timeout: TimeInterval) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do { try process.run() } catch { return nil }
        // Wait before reading: `security` can sit on a keychain prompt, and a blocking read
        // would never hit the timeout. Outputs here are tiny, so the pipe buffer cannot fill.
        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            return nil
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

enum JWT {
    static func claims(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64.append("=") }
        guard let data = Data(base64Encoded: b64) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func expiry(_ token: String) -> Date? {
        guard let exp = JSONValue.double(claims(token)?["exp"]) else { return nil }
        return Date(timeIntervalSince1970: exp)
    }
}

enum HTTPError: LocalizedError {
    case status(Int)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .status(401), .status(403): "Signed out or token expired"
        case .status(429): "Rate limited, will retry"
        case .status(let code): "Server returned \(code)"
        case .badResponse: "Unexpected response"
        }
    }
}

enum HTTP {
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    static func json(_ url: URL, headers: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw HTTPError.badResponse }
        guard (200..<300).contains(http.statusCode) else { throw HTTPError.status(http.statusCode) }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HTTPError.badResponse
        }
        return object
    }
}

enum JSONValue {
    static func double(_ value: Any?) -> Double? {
        switch value {
        case let n as NSNumber: n.doubleValue
        case let s as String: Double(s)
        default: nil
        }
    }

    static func int(_ value: Any?) -> Int? { double(value).map { Int($0) } }

    static func bool(_ value: Any?) -> Bool? {
        switch value {
        case let n as NSNumber: n.boolValue
        default: nil
        }
    }

    static func string(_ value: Any?) -> String? {
        guard let s = value as? String, !s.isEmpty else { return nil }
        return s
    }

    static func readFile(_ path: String) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

enum DateParse {
    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let lock = NSLock()

    static func iso(_ value: Any?) -> Date? {
        if let n = JSONValue.double(value), !(value is String) {
            return Date(timeIntervalSince1970: n > 1e12 ? n / 1000 : n)
        }
        guard var s = value as? String, !s.isEmpty else { return nil }
        lock.lock(); defer { lock.unlock() }
        if let d = fractional.date(from: s) ?? plain.date(from: s) { return d }
        // Microsecond precision ("…59.600777+00:00") trips ISO8601DateFormatter, so trim to milliseconds.
        if let dot = s.firstIndex(of: ".") {
            let afterDot = s[s.index(after: dot)...]
            let digits = afterDot.prefix { $0.isNumber }
            if digits.count > 3 {
                let start = s.index(dot, offsetBy: 4)
                let end = s.index(dot, offsetBy: 1 + digits.count)
                s.removeSubrange(start..<end)
                return fractional.date(from: s)
            }
        }
        return nil
    }
}

enum Paths {
    static var appSupport: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("Notchmaxx", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func modificationDate(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }
}
