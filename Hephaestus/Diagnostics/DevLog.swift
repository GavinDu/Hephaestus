import Foundation
import UIKit

// MARK: - DevLog
//
// Development telemetry for the separated Xcode flow: Hephaestus is built
// and run on a Mac, away from the backend workspace, so the app keeps a
// structured session log that can be dumped into chat for analysis
// (Profile tab -> Diagnostics -> Copy session log).
//
// Design: in-memory ring buffer (fast, no I/O on the hot path), plain-text
// export with a session header. Every entry is one line:
//   [17:59:12.412] [API] GET v1/feed -> 200 (183ms, 2.1 KB)
// Warnings and errors are tagged so failures stand out in a pasted dump:
//   [17:59:13.001] [PACKAGE] ERROR asset 'bear' sha256 mismatch
//
// Log generously at subsystem boundaries (requests, package load steps,
// rule firings, phase changes); never per frame.

enum DevLogCategory: String {
    case app = "APP"
    case api = "API"
    case package = "PACKAGE"
    case runtime = "RUNTIME"
    case player = "PLAYER"
    case create = "CREATE"
    case ui = "UI"
    case ai = "AI"
}

enum DevLogLevel: String {
    case info = ""
    case warn = "WARN "
    case error = "ERROR "
}

final class DevLog {
    static let shared = DevLog()

    struct Entry {
        let date: Date
        let category: DevLogCategory
        let level: DevLogLevel
        let message: String
    }

    private let lock = NSLock()
    private var entries: [Entry] = []
    private let capacity = 3000
    let sessionStart = Date()
    let sessionID = String(UUID().uuidString.prefix(8)).lowercased()

    /// Correlation key for the testing feedback loop
    /// (docs/TESTING_FRAMEWORK.md §5–§6). Set by a test harness or a
    /// Diagnostics export for the active run; nil for ordinary sessions.
    /// Included in exportJSON() and in PlayerTelemetry payloads so a
    /// failure can be joined to its server-side incidents by run id.
    var runID: String?

    private init() {}

    // MARK: Recording

    func record(_ category: DevLogCategory, _ level: DevLogLevel, _ message: String) {
        let entry = Entry(date: Date(), category: category, level: level, message: message)
        lock.lock()
        entries.append(entry)
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
        lock.unlock()
    }

    static func info(_ category: DevLogCategory, _ message: String) {
        shared.record(category, .info, message)
    }

    static func warn(_ category: DevLogCategory, _ message: String) {
        shared.record(category, .warn, message)
    }

    static func error(_ category: DevLogCategory, _ message: String) {
        shared.record(category, .error, message)
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    func clear() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
        record(.app, .info, "log cleared; new session segment begins")
    }

    // MARK: Export

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return f
    }()

    /// The full session dump: header + one line per entry. This is the text
    /// the Diagnostics UI copies/shares for analysis.
    func exportText() -> String {
        lock.lock()
        let snapshot = entries
        lock.unlock()

        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        var lines: [String] = []
        lines.append("=== Hephaestus dev log ===")
        lines.append("session: \(sessionID) started \(Self.dayFormatter.string(from: sessionStart))")
        lines.append("app: \(appVersion) (\(build)) | iOS \(UIDevice.current.systemVersion) | \(UIDevice.current.model)")
        lines.append("backend: \(BackendConfig.baseURL.absoluteString) | user: \(BackendConfig.userID)")
        lines.append("entries: \(snapshot.count)")
        lines.append("---")
        for e in snapshot {
            lines.append("[\(Self.timeFormatter.string(from: e.date))] [\(e.category.rawValue)] \(e.level.rawValue)\(e.message)")
        }
        return lines.joined(separator: "\n")
    }

    /// The same session as structured JSON, for the testing feedback
    /// loop (docs/TESTING_FRAMEWORK.md §6). The text export stays for
    /// humans reading a dump; this one is for machines joining a
    /// failure to its cause. Returns nil only if encoding fails, which
    /// must not happen for plain log strings.
    func exportJSON() -> String? {
        lock.lock()
        let snapshot = entries
        let runID = runID
        lock.unlock()

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let dicts: [[String: Any]] = snapshot.map { e in
            let level = e.level.rawValue.trimmingCharacters(in: .whitespaces).lowercased()
            return [
                "timestamp": iso.string(from: e.date),
                "category": e.category.rawValue,
                "level": level.isEmpty ? "info" : level,
                "message": e.message,
            ]
        }
        var doc: [String: Any] = [
            "session_id": sessionID,
            "started_at": iso.string(from: sessionStart),
            "app_version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?",
            "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?",
            "os": UIDevice.current.systemVersion,
            "device": UIDevice.current.model,
            "backend": BackendConfig.baseURL.absoluteString,
            "entries": dicts,
        ]
        if let runID {
            doc["run_id"] = runID
        }
        guard let data = try? JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return text
    }

    /// Session bootstrap line, recorded once at app launch.
    func recordLaunch() {
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        record(.app, .info, "launch: Hephaestus \(appVersion), iOS \(UIDevice.current.systemVersion), backend \(BackendConfig.baseURL.absoluteString)")
    }
}
