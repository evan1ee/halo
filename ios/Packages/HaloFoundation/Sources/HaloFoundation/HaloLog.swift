#if canImport(os)
import os
#endif
import Synchronization

/// Log categories (docs/architecture/LOGGING_AND_DIAGNOSTICS.md §1).
public enum LogCategory: String, Sendable, CaseIterable {
    case session, sync, readstate, outbox, push, nse, stickers, bot, db, ui
}

public enum LogLevel: Int, Sendable, Comparable {
    case debug, info, warning, error
    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Where log lines go. `HaloLog` only ever passes it constant text, a `HaloError` code and an
/// already-hashed identifier, so a sink can't leak content (SECURITY §6).
public protocol LogSink: Sendable {
    func emit(level: LogLevel, category: LogCategory, event: String, code: String?, id: String?)
}

/// The logging facade (D58). Deliberately has no API for dynamic strings: an event is a
/// `StaticString`, details are a stable `HaloError` code and a hashed Matrix identifier. Create it
/// in the composition root and inject it; there is no global instance.
public struct HaloLog: Sendable {
    public let category: LogCategory
    private let sink: any LogSink
    private let minimum: LogLevel
    private let salt: UInt64

    /// - Parameter salt: per-install random value, so hashes can't be compared across installs.
    public init(category: LogCategory, sink: any LogSink, minimum: LogLevel = .info, salt: UInt64) {
        self.category = category
        self.sink = sink
        self.minimum = minimum
        self.salt = salt
    }

    public func with(category: LogCategory) -> HaloLog {
        HaloLog(category: category, sink: sink, minimum: minimum, salt: salt)
    }

    public func debug(_ event: StaticString, error: HaloError? = nil, id: (some MatrixIdentifier)? = nil as UserID?) {
        log(.debug, event, error, id)
    }
    public func info(_ event: StaticString, error: HaloError? = nil, id: (some MatrixIdentifier)? = nil as UserID?) {
        log(.info, event, error, id)
    }
    public func warning(_ event: StaticString, error: HaloError? = nil, id: (some MatrixIdentifier)? = nil as UserID?) {
        log(.warning, event, error, id)
    }
    public func error(_ event: StaticString, error: HaloError? = nil, id: (some MatrixIdentifier)? = nil as UserID?) {
        log(.error, event, error, id)
    }

    /// A short, salted hash such as `!a1b2c3` (sigil + 6 hex digits) for logging a Matrix identifier.
    public func id(_ value: some MatrixIdentifier) -> String {
        Self.shortHash(value.rawValue, salt: salt)
    }

    static func shortHash(_ raw: String, salt: UInt64) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325 ^ salt  // FNV-1a, 64 bit
        for byte in raw.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        let hex = String(hash & 0xff_ffff, radix: 16)
        return String(raw.first ?? "?") + String(repeating: "0", count: 6 - hex.count) + hex
    }

    private func log(_ level: LogLevel, _ event: StaticString, _ error: HaloError?, _ id: (some MatrixIdentifier)?) {
        guard level >= minimum else { return }
        sink.emit(level: level, category: category, event: "\(event)", code: error?.code, id: id.map(self.id))
    }
}

#if canImport(os)
/// Writes to the unified log. Event, code and hashed id are public; there is nothing private to redact.
public struct OSLogSink: LogSink {
    private let subsystem: String

    /// - Parameter subsystem: the project namespace root (`one.mbm.halo`, D63).
    public init(subsystem: String) { self.subsystem = subsystem }

    public func emit(level: LogLevel, category: LogCategory, event: String, code: String?, id: String?) {
        let logger = Logger(subsystem: subsystem, category: category.rawValue)
        let code = code ?? "-"
        let id = id ?? "-"
        switch level {
        case .debug: logger.debug("\(event, privacy: .public) code=\(code, privacy: .public) id=\(id, privacy: .public)")
        case .info: logger.info("\(event, privacy: .public) code=\(code, privacy: .public) id=\(id, privacy: .public)")
        case .warning: logger.warning("\(event, privacy: .public) code=\(code, privacy: .public) id=\(id, privacy: .public)")
        case .error: logger.error("\(event, privacy: .public) code=\(code, privacy: .public) id=\(id, privacy: .public)")
        }
    }
}
#endif

/// Keeps a capped ring buffer of privacy-reviewed `HaloLog` lines in memory for Settings → Diagnostics zip export
/// (docs/architecture/LOGGING_AND_DIAGNOSTICS.md §3), optionally forwarding every line to another sink (such as `OSLogSink`).
public final class RingLogSink: LogSink {
    private let capacity: Int
    private let forwarding: (any LogSink)?
    private let lines = Mutex<[String]>([])

    public init(capacity: Int = 500, forwarding: (any LogSink)? = nil) {
        self.capacity = max(1, capacity)
        self.forwarding = forwarding
    }

    public func emit(level: LogLevel, category: LogCategory, event: String, code: String?, id: String?) {
        forwarding?.emit(level: level, category: category, event: event, code: code, id: id)
        let levelTag = switch level {
        case .debug: "DEBUG"
        case .info: "INFO"
        case .warning: "WARN"
        case .error: "ERROR"
        }
        let line = "[\(levelTag)] [\(category.rawValue)] \(event) code=\(code ?? "-") id=\(id ?? "-")"
        lines.withLock { buffer in
            buffer.append(line)
            if buffer.count > capacity {
                buffer.removeFirst(buffer.count - capacity)
            }
        }
    }

    public func snapshot() -> [String] {
        lines.withLock { $0 }
    }
}
