import FeatureAuth
import FeatureRoomList
import FeatureStickers
import FeatureTimeline
import Foundation
import HaloApplication
import HaloDomain
import HaloFoundation
import HaloMatrixAdapter
import HaloPersistence
import HaloPlatform

/// Builds the object graph once at launch: platform and adapter implementations behind the ports,
/// the coordinators over them, and the view models over the coordinators.
@MainActor
final class AppRoot {
    let auth: AuthViewModel
    let roomList: RoomListViewModel
    let sync: SyncCoordinator
    let recovery: RecoveryViewModel
    /// `nil` when no push gateway is configured (Beta/Release until one is deployed).
    let push: PushCoordinator?
    let badge: BadgeCoordinator
    private let records: NotificationRecordStore
    private let timelinePort: MatrixTimelinePort
    let receipts: ReadReceiptCoordinator
    let drafts: DraftCoordinator
    let stickers: StickerLibrary
    private let sessionCoordinator: SessionCoordinator
    private let matrixSession: MatrixSessionPort
    private let media: MediaLoader

    init() {
        let namespace = Bundle.main.bundleIdentifier ?? "one.mbm.halo"
        let log = HaloLog(
            category: .session, sink: OSLogSink(subsystem: namespace),
            minimum: Self.minimumLogLevel, salt: Self.installSalt())

        // Shared with the notification extension: the Keychain access group and the App Group container.
        let keychain = HaloShared.keychain()
        let session = MatrixSessionPort(baseDirectory: HaloShared.storeDirectory())
        matrixSession = session
        let sessionCoordinator = SessionCoordinator(port: session, keychain: keychain)
        self.sessionCoordinator = sessionCoordinator
        let roomCoordinator = RoomListCoordinator(port: MatrixRoomListPort(session: session), loadsAllPages: true)
        let suite = "group.\(HaloShared.namespace())"
        records = NotificationRecordStore(suiteName: suite)
        let receipts = ReadReceiptCoordinator(port: MatrixReadMarkerPort(session: session))
        self.receipts = receipts
        drafts = DraftCoordinator()
        stickers = StickerLibrary(packs: MatrixStickerPackPort(session: session), prefs: MatrixStickerPrefsPort(session: session))
        badge = BadgeCoordinator(rooms: roomCoordinator, records: records, port: SystemBadge(suiteName: suite), receipts: receipts)

        timelinePort = MatrixTimelinePort(session: session)
        media = MediaLoader(port: MatrixMediaPort(session: session))
        recovery = RecoveryViewModel(coordinator: EncryptionCoordinator(port: MatrixEncryptionPort(session: session), session: sessionCoordinator))
        sync = SyncCoordinator(port: MatrixSyncPort(session: session), session: sessionCoordinator)
        push = Self.pushConfiguration().map {
            PushCoordinator(port: MatrixPushPort(session: session), session: sessionCoordinator, appID: $0.appID, gatewayURL: $0.gateway)
        }
        if let push { Task { await sessionCoordinator.setBeforeSignOut { await push.unregister() } } }
        auth = AuthViewModel(coordinator: sessionCoordinator)
        roomList = RoomListViewModel(session: sessionCoordinator, rooms: roomCoordinator, receipts: receipts)
        #if DEBUG
        Self.exportNSEMetrics(namespace: namespace)
        #endif
        log.info("app launched")
    }

    /// Opens Halo's database for each signed-in account and restores the read intents it holds. Runs for the life of the app.
    func followReadIntents() async {
        for await state in await sessionCoordinator.states() {
            guard case .ready(let user) = state else { continue }
            do {
                let directory = HaloShared.storeDirectory().appendingPathComponent("halo", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let database = try HaloDatabase(path: directory.appendingPathComponent("halo.sqlite").path)
                await receipts.restore(from: ReadIntentStore(database: database, account: user))
                await drafts.attach(DraftStore(database: database, account: user))
            } catch {
                // Without a database, receipts still work from memory; there is nothing to restore.
            }
        }
    }

    private static func pushConfiguration() -> (appID: String, gateway: URL)? {
        guard let appID = Bundle.main.object(forInfoDictionaryKey: "HaloPushAppID") as? String, !appID.isEmpty,
              let raw = Bundle.main.object(forInfoDictionaryKey: "HaloPushGatewayURL") as? String, !raw.isEmpty,
              let gateway = URL(string: raw) else { return nil }
        return (appID, gateway)
    }

    /// A view model for the timeline of `room`; each screen gets its own coordinator and session.
    func makeTimeline(room: RoomID) -> TimelineViewModel {
        TimelineViewModel(coordinator: TimelineCoordinator(port: timelinePort, room: room, records: records), media: media, receipts: receipts, room: room, drafts: drafts, images: ImagePreparer())
    }

    /// The sticker panel for the timeline of `room`; sending goes through that timeline's view model.
    func makeStickerPanel(room: RoomID, timeline: TimelineViewModel) -> StickerPanelViewModel {
        let creator = StickerPackCreator(port: MatrixStickerPackCreationPort(session: matrixSession), preparer: ImagePreparer(maximumDimension: 512))
        return StickerPanelViewModel(
            library: stickers, media: media, room: room, newPack: { done in NewPackViewModel(creator: creator, onCreated: done) }, send: { sticker throws(HaloError) in try await timeline.sendSticker(sticker) })
    }

    #if DEBUG
    /// Debug only: copies the extension's G-NSE metrics (App Group container) into the app's Documents folder, where
    /// `devicectl device copy from --domain-type appDataContainer` can read them.
    private static func exportNSEMetrics(namespace: String) {
        let fileManager = FileManager.default
        guard let group = fileManager.containerURL(forSecurityApplicationGroupIdentifier: "group.\(namespace)") else { return }
        let source = group.appendingPathComponent("nse-metrics.jsonl")
        let target = URL.documentsDirectory.appendingPathComponent("nse-metrics.jsonl")
        try? fileManager.removeItem(at: target)
        try? fileManager.copyItem(at: source, to: target)
    }
    #endif

    private static var minimumLogLevel: LogLevel {
        #if DEBUG
        .debug
        #else
        .info
        #endif
    }

    /// A random per-install value for hashing identifiers in logs (SECURITY §6).
    private static func installSalt() -> UInt64 {
        let key = "logSalt"
        if let stored = UserDefaults.standard.object(forKey: key) as? UInt64 { return stored }
        let salt = UInt64.random(in: .min ... .max)
        UserDefaults.standard.set(salt, forKey: key)
        return salt
    }
}
