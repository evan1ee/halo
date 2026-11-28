import Foundation
import HaloDomain
import HaloFoundation
import MatrixRustSDK
import Testing
@testable import HaloMatrixAdapter

private let storageEnv = ProcessInfo.processInfo.environment
private let storageConfigured = storageEnv["HALO_DEV_SERVER"] != nil && storageEnv["HALO_DEV_USER"] != nil && storageEnv["HALO_DEV_PASSWORD"] != nil

/// Live Synapse contract test for M20-13 Storage (SETTINGS §3, AC-SET-3, D55).
/// Verifies SDK `getStoreSizes()`, `setMediaRetentionPolicy`, and that clearing the media cache
/// frees ≥ 95% of cached media bytes while leaving encryption keys, drafts, and unsent messages untouched.
@Suite("Storage contract against infra/dev (M20-13, AC-SET-3)", .serialized, .cleansUp, .enabled(if: storageConfigured, "needs HALO_DEV_SERVER/USER/PASSWORD"))
struct StorageContractTests {
    @Test("clearMediaCache frees ≥ 95% of cached media and never touches keys, drafts, or unsent messages")
    func clearMediaCacheFreesMediaAndPreservesKeysAndUnsent() async throws {
        let server = try #require(storageEnv["HALO_DEV_SERVER"])
        let username = try #require(storageEnv["HALO_DEV_USER"])
        let password = try #require(storageEnv["HALO_DEV_PASSWORD"])

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("halo-storage-contract-\(UUID().uuidString)", isDirectory: true)
        let storeRoot = root.appendingPathComponent("stores", isDirectory: true)
        let haloDir = root.appendingPathComponent("halo", isDirectory: true)
        let tempDir = root.appendingPathComponent("tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: storeRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: haloDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        Cleanup.current.add { try? FileManager.default.removeItem(at: root) }

        // Sentinel draft file in halo/ to verify Halo's own database is untouched.
        let haloSentinel = haloDir.appendingPathComponent("halo.sqlite")
        let sentinelBytes = Data(repeating: 0x42, count: 16_384)
        try sentinelBytes.write(to: haloSentinel)

        let session = MatrixSessionPort(baseDirectory: storeRoot)
        Cleanup.current.add {
            await session.stopSync()
            try? await session.logout()
        }
        let details = try await session.loginDetails(server: server)
        _ = try await session.loginPassword(
            PasswordCredentials(username: username, password: password, deviceDisplayName: "halo-storage-test"),
            on: details
        )

        let storage = MatrixStoragePort(session: session, haloDatabaseDirectory: haloDir, temporaryDirectory: tempDir)
        let rooms = MatrixChatCreationPort(session: session)
        let client = try await session.signedInClient()

        // Create an encrypted room (exercises cryptoStore) and register cleanup immediately.
        let roomID = try await rooms.createRoom(name: "storage-m20-13", invite: [])
        Cleanup.current.leave(roomID.rawValue, as: client)

        // Upload a 1 MiB pseudo-random payload directly into the SDK media cache via upload + fetch.
        // An empty SQLite media store has ~36 KiB schema overhead, so 1 MiB validates ≥ 95% freed (AC-SET-3).
        var rng = SeededRandomNumberGenerator(seed: 2013)
        var payload = Data(count: 1_024 * 1_024)
        for i in payload.indices { payload[i] = UInt8.random(in: 0...255, using: &rng) }
        let mxc = try await client.uploadMedia(mimeType: "application/octet-stream", data: payload, progressWatcher: nil)
        let source = try MediaSource.fromUrl(url: mxc)
        let fetched = try await client.getMediaContent(mediaSource: source)
        #expect(fetched.count == payload.count)

        // Also stage a Halo temp media copy (as viewer/export does).
        let viewerDir = tempDir.appendingPathComponent("halo-viewer-test", isDirectory: true)
        try FileManager.default.createDirectory(at: viewerDir, withIntermediateDirectories: true)
        try payload.write(to: viewerDir.appendingPathComponent("photo.bin"))

        // Queue an unsent message while send queue is disabled so it lives in stateStore (AC-SET-3).
        await client.enableAllSendQueues(enable: false)
        let room = try await session.room(roomID)
        let handle = try await room.timeline()
        _ = try await handle.send(msg: messageEventContentFromMarkdown(md: "unsent-storage-sentinel"))

        let before = try await storage.storeSizes()
        let beforeSDKMedia = try await session.sdkStoreSizes().mediaStore ?? 0
        #expect(beforeSDKMedia >= UInt64(payload.count), "expected SDK mediaStore >= 512 KiB, got \(beforeSDKMedia)")
        #expect(before.mediaCacheBytes >= Int64(payload.count), "expected cached media bytes >= 512 KiB, got \(before.mediaCacheBytes)")
        #expect(before.cryptoKeysBytes > 0, "crypto store must be non-empty")
        #expect(before.messagesBytes > 0, "state/event store must be non-empty")
        #expect(before.haloDatabaseBytes > 0, "halo database must be measured")

        // Apply a custom retention policy (D55) and clear media cache.
        let customRetention = MediaCacheRetention(maxSize: .mb500, expiry: .days7)
        try await storage.applyMediaRetention(customRetention)
        try await storage.clearMediaCache(restoring: customRetention)

        let after = try await storage.storeSizes()
        let afterSDKMedia = try await session.sdkStoreSizes().mediaStore ?? 0
        let sdkFreedFraction = Double(Int64(beforeSDKMedia) - Int64(afterSDKMedia)) / Double(max(1, Int64(beforeSDKMedia)))
        #expect(
            sdkFreedFraction >= 0.95,
            "AC-SET-3: expected SDK mediaStore >= 95% freed, before=\(beforeSDKMedia) after=\(afterSDKMedia) fraction=\(sdkFreedFraction)"
        )
        let freedFraction = Double(before.mediaCacheBytes - after.mediaCacheBytes) / Double(max(1, before.mediaCacheBytes))
        #expect(
            freedFraction >= 0.95,
            "AC-SET-3: expected >= 95% freed, before=\(before.mediaCacheBytes) after=\(after.mediaCacheBytes) fraction=\(freedFraction)"
        )
        #expect(after.cryptoKeysBytes > 0, "crypto keys must never be cleared")
        #expect(try Data(contentsOf: haloSentinel) == sentinelBytes, "halo.sqlite (drafts/intents) must never be touched")

        // Re-enable send queues and confirm the unsent message is still queued and delivers cleanly.
        await client.enableAllSendQueues(enable: true)
        var delivered = false
        for _ in 0..<20 {
            _ = try? await client.syncOnceV2(settings: SyncSettingsV2(timeoutMs: 1_000, fullState: false))
            let latest = await room.latestEvent()
            if case .remote(let remote) = latest,
               MatrixRoomListPort.previewText(remote.content) == "unsent-storage-sentinel" {
                delivered = true
                break
            }
        }
        #expect(delivered, "unsent message queued before clearMediaCache must survive and send")
    }
}
