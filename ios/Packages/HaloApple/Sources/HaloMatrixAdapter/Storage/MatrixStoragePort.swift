import Foundation
import HaloDomain
import HaloFoundation
import MatrixRustSDK

/// `StoragePort` over `MatrixSessionPort` (`Client.getStoreSizes()` + `Client.setMediaRetentionPolicy`) and Halo's
/// local SQLite directory (SETTINGS §3, AC-SET-3, D55, M20-13).
public final class MatrixStoragePort: StoragePort, Sendable {
    private let session: MatrixSessionPort
    private let haloDatabaseDirectory: URL
    private let temporaryDirectory: URL

    /// Prefixes of temporary files Halo creates while viewing/playing/exporting media.
    static let mediaTempPrefixes = ["halo-open-", "halo-video-", "halo-audio-", "halo-viewer-", "halo-photo-"]

    public init(
        session: MatrixSessionPort,
        haloDatabaseDirectory: URL,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) {
        self.session = session
        self.haloDatabaseDirectory = haloDatabaseDirectory
        self.temporaryDirectory = temporaryDirectory
    }

    public func storeSizes() async throws(HaloError) -> StoreSizeBreakdown {
        let sdk = try await session.sdkStoreSizes()
        let haloBytes = Self.directorySize(of: haloDatabaseDirectory)
        let tempMediaBytes = Self.mediaTempSize(in: temporaryDirectory)
        let mediaBytes = Int64(sdk.mediaStore ?? 0) + tempMediaBytes
        let messagesBytes = Int64(sdk.stateStore ?? 0) + Int64(sdk.eventCacheStore ?? 0)
        let cryptoBytes = Int64(sdk.cryptoStore ?? 0)
        return StoreSizeBreakdown(
            mediaCacheBytes: mediaBytes,
            messagesBytes: messagesBytes,
            cryptoKeysBytes: cryptoBytes,
            haloDatabaseBytes: haloBytes
        )
    }

    public func clearMediaCache(restoring retention: MediaCacheRetention) async throws(HaloError) {
        try await session.clearMediaStore(restoring: retention)
        Self.removeMediaTempFiles(in: temporaryDirectory)
        // Clean up stale cache folders from inactive/orphaned sessions only (never active open SQLite files or data/).
        let activeID = await session.activeStoreID()
        Self.removeInactiveSessionCaches(under: session.storeBaseDirectory, keepingStoreID: activeID)
    }

    public func applyMediaRetention(_ retention: MediaCacheRetention) async throws(HaloError) {
        try await session.applyMediaRetention(retention)
    }

    // MARK: Disk helpers

    static func directorySize(of url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileSizeKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
        }
        return total
    }

    static func mediaTempSize(in directory: URL) -> Int64 {
        guard let entries = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return 0 }
        var total: Int64 = 0
        for entry in entries where mediaTempPrefixes.contains(where: { entry.lastPathComponent.hasPrefix($0) }) {
            total += directorySize(of: entry)
        }
        return total
    }

    static func removeMediaTempFiles(in directory: URL) {
        guard let entries = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for entry in entries where mediaTempPrefixes.contains(where: { entry.lastPathComponent.hasPrefix($0) }) {
            try? FileManager.default.removeItem(at: entry)
        }
    }

    static func removeInactiveSessionCaches(under baseDirectory: URL, keepingStoreID activeID: String?) {
        let fm = FileManager.default
        guard let subdirs = try? fm.contentsOfDirectory(at: baseDirectory, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        for dir in subdirs {
            let name = dir.lastPathComponent
            if name == "halo" || name == activeID { continue }
            let cacheDir = dir.appendingPathComponent("caches", isDirectory: true)
            guard let files = try? fm.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: nil) else { continue }
            for file in files { try? fm.removeItem(at: file) }
        }
    }
}
