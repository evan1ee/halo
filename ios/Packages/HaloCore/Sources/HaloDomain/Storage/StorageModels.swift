import Foundation

/// Maximum disk budget for the SDK's encrypted media cache (D55, SETTINGS §3, M20-13).
public enum MediaCacheSizeLimit: String, CaseIterable, Sendable, Codable, Equatable, Identifiable {
    case mb250
    case mb500
    case gb1
    case gb2
    case unlimited

    public var id: String { rawValue }

    /// Maximum total bytes, or `nil` for no cap.
    public var bytes: UInt64? {
        switch self {
        case .mb250: 250 * 1_048_576
        case .mb500: 500 * 1_048_576
        case .gb1: 1_073_741_824
        case .gb2: 2 * 1_073_741_824
        case .unlimited: nil
        }
    }

    public var title: String {
        switch self {
        case .mb250: "250 MB"
        case .mb500: "500 MB"
        case .gb1: "1 GB"
        case .gb2: "2 GB"
        case .unlimited: "Unlimited"
        }
    }
}

/// How long unaccessed media stays in the SDK's encrypted media cache before cleanup (D55, SETTINGS §3, M20-13).
public enum MediaCacheExpiry: String, CaseIterable, Sendable, Codable, Equatable, Identifiable {
    case days7
    case days30
    case days90
    case never

    public var id: String { rawValue }

    /// Expiry duration in seconds, or `nil` for no age limit.
    public var seconds: TimeInterval? {
        switch self {
        case .days7: 7 * 86_400
        case .days30: 30 * 86_400
        case .days90: 90 * 86_400
        case .never: nil
        }
    }

    public var title: String {
        switch self {
        case .days7: "7 days"
        case .days30: "30 days"
        case .days90: "90 days"
        case .never: "Never"
        }
    }
}

/// Media cache retention policy applied to the Matrix SDK media store (D55: 1 GB / 30 days default).
public struct MediaCacheRetention: Sendable, Codable, Equatable {
    public static let defaultPolicy = MediaCacheRetention(maxSize: .gb1, expiry: .days30)
    /// Maximum single cached file size (50 MiB, matching Halo's upload limit).
    public static let maxFileSizeBytes: UInt64 = 52_428_800
    /// Automatic cleanup cadence (daily).
    public static let cleanupFrequencySeconds: TimeInterval = 86_400

    public var maxSize: MediaCacheSizeLimit
    public var expiry: MediaCacheExpiry

    public init(maxSize: MediaCacheSizeLimit = .gb1, expiry: MediaCacheExpiry = .days30) {
        self.maxSize = maxSize
        self.expiry = expiry
    }
}

/// Breakdown of on-device storage by category from SDK `getStoreSizes()` plus Halo's own SQLite database (SETTINGS §3, M20-13).
public struct StoreSizeBreakdown: Sendable, Equatable {
    /// Cached photos, videos, audio and files (what "Clear media cache" frees; AC-SET-3).
    public let mediaCacheBytes: Int64
    /// Synced room state and cached timeline events (SDK `stateStore` + `eventCacheStore`; includes unsent message queue).
    public let messagesBytes: Int64
    /// End-to-end encryption keys (SDK `cryptoStore`; never cleared by "Clear media cache").
    public let cryptoKeysBytes: Int64
    /// Halo's own SQLite database (`halo.sqlite`: drafts, read intents, notification records, sticker pack cache).
    public let haloDatabaseBytes: Int64

    public var totalBytes: Int64 {
        mediaCacheBytes + messagesBytes + cryptoKeysBytes + haloDatabaseBytes
    }

    public init(
        mediaCacheBytes: Int64,
        messagesBytes: Int64,
        cryptoKeysBytes: Int64,
        haloDatabaseBytes: Int64
    ) {
        self.mediaCacheBytes = max(0, mediaCacheBytes)
        self.messagesBytes = max(0, messagesBytes)
        self.cryptoKeysBytes = max(0, cryptoKeysBytes)
        self.haloDatabaseBytes = max(0, haloDatabaseBytes)
    }
}

/// Outcome of clearing the media cache, reporting the exact before/after media cache sizes (AC-SET-3).
public struct MediaCacheClearResult: Sendable, Equatable {
    public let beforeMediaBytes: Int64
    public let afterMediaBytes: Int64
    public let breakdown: StoreSizeBreakdown

    public var freedBytes: Int64 { max(0, beforeMediaBytes - afterMediaBytes) }

    public init(beforeMediaBytes: Int64, afterMediaBytes: Int64, breakdown: StoreSizeBreakdown) {
        self.beforeMediaBytes = max(0, beforeMediaBytes)
        self.afterMediaBytes = max(0, afterMediaBytes)
        self.breakdown = breakdown
    }
}
