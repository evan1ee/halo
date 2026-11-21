import HaloApplication
import HaloDomain
import HaloFoundation
import HaloMatrixAdapter
import HaloPersistence
import HaloPlatform
import UserNotifications

/// Notification service extension (docs/matrix/PUSH_NOTIFICATIONS.md §3, gate G-NSE, ADR-0016).
/// Thin wiring over `HaloApplication.NotificationProcessor`: fetches the event through the SDK, records it in
/// `halo.sqlite` (`notification_record`, R-13), and evaluates any badge fallback via `ReadStatePolicy` (R-08).
/// Never sets `aps.badge` from a payload and never creates attention from a payload (AGENTS.md §17).
final class NotificationService: UNNotificationServiceExtension, @unchecked Sendable {
    private struct SessionKey: Hashable, Sendable {
        let userID: UserID
        let deviceID: DeviceID
    }

    private struct CachedRuntime: Sendable {
        let session: MatrixSessionPort
        let database: HaloDatabase
        let records: NotificationRecordStore
    }

    /// Reuses one restored SDK `Client` + GRDB handle across pushes in the same extension process (R-23),
    /// coalescing concurrent pushes so two clients never race on the same store.
    private static let runtimeCache = SingleFlightCache<SessionKey, CachedRuntime>()

    private var handler: ((UNNotificationContent) -> Void)?
    private var original: UNNotificationContent?
    private let lock = NSLock()
    private var delivered = false

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        handler = contentHandler
        original = request.content
        let info = request.content.userInfo
        guard let roomRaw = info["room_id"] as? String, let eventRaw = info["event_id"] as? String,
              let room = try? RoomID(roomRaw), let event = try? EventID(eventRaw) else {
            deliver(silentSuppressedContent(), outcome: "no-event", metrics: NSEMetrics())  // PUSH_NO_EVENT
            return
        }
        // UserNotifications types aren't Sendable; the request is only read by `run`, which delivers exactly once.
        nonisolated(unsafe) let request = request
        Task { await self.run(room: room, event: event, request: request) }
    }

    /// iOS is about to kill the extension: deliver the generic content (no message text, no badge) now.
    override func serviceExtensionTimeWillExpire() {
        if let original { deliver(genericWithoutBadge(original), outcome: "timeout", metrics: NSEMetrics()) }
    }

    private func run(room: RoomID, event: EventID, request: UNNotificationRequest) async {
        var metrics = NSEMetrics()
        let content = genericWithoutBadge(request.content)
        let suite = "group.\(HaloShared.namespace())"
        let attention = AttentionCache(suiteName: suite)
        do {
            let keychain = HaloShared.keychain()
            guard let data = try await keychain.read(.session) else {
                return deliver(content, outcome: "no-session", metrics: metrics)
            }
            let stored = try JSONDecoder().decode(StoredSession.self, from: data)
            metrics.step("keychain")
            let key = SessionKey(userID: stored.userID, deviceID: stored.deviceID)
            let runtime = try await Self.runtimeCache.value(for: key) {
                let directory = HaloShared.storeDirectory().appendingPathComponent("halo", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let database = try HaloDatabase(path: directory.appendingPathComponent("halo.sqlite").path)
                let signal = DarwinSignal()
                let records = NotificationRecordStore(database: database, account: stored.userID, onChange: { signal.post() })
                let session = MatrixSessionPort(
                    baseDirectory: HaloShared.storeDirectory(),
                    holderName: "nse",
                    sendsMessages: false,
                    lightweightRuntime: true,
                    readStoredSession: {
                        (try? keychain.readSync(.session)).flatMap { try? JSONDecoder().decode(StoredSession.self, from: $0) }
                    },
                    persistRefreshedSession: { refreshed in
                        if let encoded = try? JSONEncoder().encode(refreshed) {
                            try? keychain.writeSync(encoded, for: .session)
                        }
                    })
                try await session.restore(stored)
                return CachedRuntime(session: session, database: database, records: records)
            }
            metrics.step("restore")
            let processor = NotificationProcessor(
                fetcher: MatrixNotificationPort(session: runtime.session),
                records: runtime.records,
                lastAttention: { attention.roomIDs() },
                isAppForeground: { attention.isForeground() })
            let decision = await processor.process(room: room, event: event)
            metrics.step("fetch")
            switch decision {
            case .deliver(let title, let body, let threadID, let badge, let outcome):
                content.title = title
                content.body = body
                content.threadIdentifier = threadID
                content.badge = badge.map(NSNumber.init(value:))
                deliver(content, outcome: outcome, metrics: metrics)
            case .suppressed(let outcome):
                // Empty, silent, passive content (R-14): suppresses delivery completely once Apple's
                // com.apple.developer.usernotifications.filtering entitlement (V-PUSH-3) is granted.
                deliver(silentSuppressedContent(), outcome: outcome, metrics: metrics)
            case .fallback(let outcome):
                deliver(content, outcome: outcome, metrics: metrics)
            }
        } catch {
            deliver(content, outcome: "error", metrics: metrics)
        }
    }

    private func genericWithoutBadge(_ base: UNNotificationContent) -> UNMutableNotificationContent {
        let copy = (base.mutableCopy() as? UNMutableNotificationContent) ?? UNMutableNotificationContent()
        copy.badge = nil  // the badge is never taken from a push payload (ADR-0015)
        return copy
    }

    private func silentSuppressedContent() -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = ""
        content.subtitle = ""
        content.body = ""
        content.sound = nil
        content.badge = nil
        content.interruptionLevel = .passive
        content.relevanceScore = 0
        return content
    }

    private func deliver(_ content: UNNotificationContent, outcome: String, metrics: NSEMetrics) {
        lock.lock()
        let already = delivered
        delivered = true
        lock.unlock()
        guard !already else { return }
        metrics.write(outcome: outcome, appGroup: "group.\(HaloShared.namespace())")
        handler?(content)
    }
}
