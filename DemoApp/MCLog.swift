import Foundation

public enum LogLevel: Int, Codable, Comparable {
    case trace = 0, debug, info, warn, error, fatal
    public static func < (a: LogLevel, b: LogLevel) -> Bool { a.rawValue < b.rawValue }
    public var name: String {
        switch self {
        case .trace: return "TRACE"; case .debug: return "DEBUG"; case .info: return "INFO"
        case .warn: return "WARN"; case .error: return "ERROR"; case .fatal: return "FATAL"
        }
    }
}

public enum LogCategory: String, Codable {
    case general, document, sketch, solver, feature, thread, kernel, io
    case assembly, drawing, render, ui, perf, lifecycle
}

public struct LogEntry: Codable, Equatable {
    public var timestamp: Date
    public var level: LogLevel
    public var category: LogCategory
    public var code: String?
    public var message: String
    public var context: [String: String]
    public init(timestamp: Date, level: LogLevel, category: LogCategory,
                code: String?, message: String, context: [String: String]) {
        self.timestamp = timestamp; self.level = level; self.category = category
        self.code = code; self.message = message; self.context = context
    }
    /// One JSON Lines record.
    public func jsonLine() -> String {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys]
        guard let data = try? enc.encode(self),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }
}

/// Structured logger: ring buffer + rotating JSONL file sink.
/// Design: LOGGING.md. Privacy: callers must never pass document content.
public final class MCLog {
    public static let shared = MCLog()

    public var minimumLevel: LogLevel = .info
    public let ringCapacity: Int
    private var ring: [LogEntry] = []
    private let lock = NSLock()
    private var fileHandle: FileHandle?
    private var currentFileBytes: Int = 0
    public let maxFileBytes: Int
    public private(set) var logDirectory: URL?
    public private(set) var totalEntriesWritten: Int = 0
    public var dateProvider: () -> Date = { Date() }

    public init(ringCapacity: Int = 2000, maxFileBytes: Int = 5_000_000) {
        self.ringCapacity = ringCapacity
        self.maxFileBytes = maxFileBytes
    }

    /// Attach the file sink. Files: metalcad-YYYYMMDD-N.log, rotated by size,
    /// at most 4 kept.
    public func attachFileSink(directory: URL) {
        lock.lock(); defer { lock.unlock() }
        logDirectory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        rotateLocked(forceNew: true)
        pruneOldFilesLocked()
    }

    public func detachFileSink() {
        lock.lock(); defer { lock.unlock() }
        try? fileHandle?.close()
        fileHandle = nil
    }

    private func fileNameLocked() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return "metalcad-\(f.string(from: dateProvider()))"
    }

    private func rotateLocked(forceNew: Bool) {
        guard let dir = logDirectory else { return }
        let base = fileNameLocked()
        var idx = 0
        var candidate = dir.appendingPathComponent("\(base)-\(idx).log")
        while FileManager.default.fileExists(atPath: candidate.path) {
            let attrs = try? FileManager.default.attributesOfItem(atPath: candidate.path)
            let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
            if !forceNew && size < maxFileBytes {
                currentFileBytes = size
                fileHandle = try? FileHandle(forWritingTo: candidate)
                _ = try? fileHandle?.seekToEnd()
                return
            }
            idx += 1
            candidate = dir.appendingPathComponent("\(base)-\(idx).log")
            if idx > 99 { return }
        }
        _ = FileManager.default.createFile(atPath: candidate.path, contents: nil)
        currentFileBytes = 0
        try? fileHandle?.close()
        fileHandle = try? FileHandle(forWritingTo: candidate)
    }

    private func pruneOldFilesLocked() {
        guard let dir = logDirectory,
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return }
        let logs = files.filter { $0.lastPathComponent.hasPrefix("metalcad-") && $0.pathExtension == "log" }
            .sorted { (a, b) in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? nil
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? nil
                return (da ?? .distantPast) > (db ?? .distantPast)
            }
        for f in logs.dropFirst(4) { try? FileManager.default.removeItem(at: f) }
    }

    public func log(_ level: LogLevel, _ category: LogCategory, _ message: String,
                    code: String? = nil, context: [String: String] = [:]) {
        guard level >= minimumLevel || level >= .warn else { return }
        let entry = LogEntry(timestamp: dateProvider(), level: level, category: category,
                             code: code, message: message, context: context)
        lock.lock(); defer { lock.unlock() }
        ring.append(entry)
        if ring.count > ringCapacity { ring.removeFirst(ring.count - ringCapacity) }
        totalEntriesWritten += 1
        if let fh = fileHandle {
            let line = entry.jsonLine() + "\n"
            if let data = line.data(using: .utf8) {
                try? fh.write(contentsOf: data)
                currentFileBytes += data.count
                if currentFileBytes >= maxFileBytes {
                    rotateLocked(forceNew: false)
                    pruneOldFilesLocked()
                }
            }
        }
    }

    /// Log a CADError at its own severity. Rebuild loops call this for every
    /// thrown error — coverage is enforced centrally, not per call site.
    public func log(error: CADError, category: LogCategory, context: [String: String] = [:]) {
        let level: LogLevel
        switch error.severity {
        case .warning: level = .warn
        case .error: level = .error
        case .fatal: level = .fatal
        }
        log(level, category, error.userMessage, code: error.code, context: context)
    }

    public func trace(_ c: LogCategory, _ m: String, context: [String: String] = [:]) { log(.trace, c, m, context: context) }
    public func debug(_ c: LogCategory, _ m: String, context: [String: String] = [:]) { log(.debug, c, m, context: context) }
    public func info(_ c: LogCategory, _ m: String, context: [String: String] = [:]) { log(.info, c, m, context: context) }
    public func warn(_ c: LogCategory, _ m: String, code: String? = nil, context: [String: String] = [:]) { log(.warn, c, m, code: code, context: context) }

    /// Most recent entries, newest last.
    public func recentEntries(limit: Int = 200) -> [LogEntry] {
        lock.lock(); defer { lock.unlock() }
        return Array(ring.suffix(limit))
    }

    public func lastErrorCode() -> String? {
        lock.lock(); defer { lock.unlock() }
        return ring.last(where: { $0.level >= .error && $0.code != nil })?.code
    }

    public var entryCount: Int {
        lock.lock(); defer { lock.unlock() }
        return ring.count
    }

    public func clear() {
        lock.lock(); defer { lock.unlock() }
        ring.removeAll()
    }
}
