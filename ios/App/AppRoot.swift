import AppIntents
import FeatureBotActivity
import FeatureOnboarding
import FeatureRoomList
import Foundation
import HaloApplication
import HaloDomain
import HaloFoundation
import HaloMatrixAdapter
import HaloPersistence
import HaloPlatform
import Synchronization

/// Composition root object graph (ADR-0022 step 2, TD-10).
///
/// Builds platform and adapter implementations behind domain ports once at launch. Feature factories and
/// lifecycle routines live in `App/Composition/{Session,Chats,Settings,Notifications,Bots}Assembly.swift`.
@MainActor
final class AppRoot {
    let preferencesPort: any PreferencesPort
    let preferences: PreferencesStore
    let auth: AuthViewModel
    let roomList: RoomListViewModel
    /// The "Send to…" sheet for what the share extension staged (M16).
    let shareHandoff: ShareHandoffViewModel
    /// Chats offered to Siri, Shortcuts and Spotlight while the person allows it (M16, D88).
    let chatShortcuts = ChatShortcutPublisher(port: SystemChatShortcutStore(file: SystemChatShortcutStore.defaultFile()))
    /// An outside request (Siri, Shortcuts, Spotlight) to open a chat; the root view consumes it.
    let openChat = OpenChatRequest()
    /// The chats the active Focus allows (M16, D90).
    let focus = FocusFilterState()
    let sync: SyncCoordinator
    let recovery: RecoveryViewModel
    /// `nil` when no push gateway is configured (Beta/Release until one is deployed).
    let push: PushCoordinator?
    let readState: ReadStateCoordinator
    let receipts: ReadReceiptCoordinator
    let drafts: DraftCoordinator
    let stickers: StickerLibrary
    let stickerPackManager: StickerPackManager
    /// KLIPY GIFs and stickers (D98); unavailable when the build has no `HALO_KLIPY_API_KEY`.
    let klipy = KlipyCatalog(port: KlipyClient.configured())
    let botActivity: BotActivityCoordinator
    /// Ticks from Activity; kept for the app's life so a pending tick survives leaving the screen.
    lazy var botActions = BotActionCoordinator(
        port: timelinePort,
        activity: botActivity,
        botSenders: { [preferencesPort] in Set(preferencesPort.load().botSenders) }
    )

    let attentionCache: AttentionCache
    let activeRecords = ActiveRecordsBox()
    let timelinePort: MatrixTimelinePort
    let sessionCoordinator: SessionCoordinator
    let matrixSession: MatrixSessionPort
    let media: MediaLoader
    let unrecognisedBots = UnrecognisedBotMessages()
    let previewPolicy: any MediaPreviewPolicyPort
    let roomPort: MatrixRoomPort
    let chatCreation: MatrixChatCreationPort
    let profilePort: MatrixProfilePort
    let notificationDefaultsPort: MatrixNotificationDefaultsPort
    let devicesPort: MatrixDevicesPort
    let passwordPort: MatrixAccountPasswordPort
    let botAllowlistPort: MatrixBotAllowlistPort
    let searchPort: MatrixSearchPort
    let searchCoordinator: SearchCoordinator
    let roomCoordinator: RoomListCoordinator
    /// The signed-in account, once the session is ready (kept out of "New chat" results).
    var signedInUser: UserID?
    /// The signed-in Matrix ID, for the avatar's initial before the display name is known.
    var signedInUserID: String? { signedInUser?.rawValue }
    let log: HaloLog
    let ringLog: RingLogSink
    /// Apple's own crash, hang and performance reports, on this device only (D114); exported with the diagnostics.
    let metricPayloads = MetricPayloadStore(directory: MetricPayloadStore.standardDirectory())
    private let metricKit: MetricKitRecorder
    let webAuth = WebAuthSessionPresenter()
    var auditPort: (any AuditEventPort)?
    /// Running performance signposts (LOGGING_AND_DIAGNOSTICS §5); dropped, not ended, when the measured path didn't happen.
    var coldStart: HaloSignpost.Running?
    var roomOpen: HaloSignpost.Running?
    private(set) var hasBegun = false

    init() {
        let preferencesPort = UserDefaultsPreferencesStore()
        self.preferencesPort = preferencesPort
        let preferences = PreferencesStore(port: preferencesPort)
        self.preferences = preferences

        let namespace = Bundle.main.bundleIdentifier ?? "one.mbm.halo"
        let ringLog = RingLogSink(capacity: 500, forwarding: OSLogSink(subsystem: namespace))
        self.ringLog = ringLog
        metricKit = MetricKitRecorder(store: metricPayloads)
        metricKit.start()
        let log = HaloLog(
            category: .session, sink: ringLog,
            minimum: Self.minimumLogLevel, salt: Self.installSalt()
        )

        // Shared with the notification extension: the Keychain access group and the App Group container.
        let keychain = HaloShared.keychain()
        let session = MatrixSessionPort(
            baseDirectory: HaloShared.storeDirectory(),
            readStoredSession: {
                (try? keychain.readSync(.session)).flatMap { try? JSONDecoder().decode(StoredSession.self, from: $0) }
            }
        )
        matrixSession = session
        let sessionCoordinator = SessionCoordinator(port: session, keychain: keychain)
        self.sessionCoordinator = sessionCoordinator

        let profilePort = MatrixProfilePort(session: session)
        self.profilePort = profilePort
        self.notificationDefaultsPort = MatrixNotificationDefaultsPort(session: session)
        self.devicesPort = MatrixDevicesPort(session: session)
        self.passwordPort = MatrixAccountPasswordPort(session: session)
        botAllowlistPort = MatrixBotAllowlistPort(session: session)
        let searchPort = MatrixSearchPort(session: session)
        self.searchPort = searchPort
        self.searchCoordinator = SearchCoordinator(port: searchPort)

        let suite = "group.\(HaloShared.namespace())"
        attentionCache = AttentionCache(suiteName: suite)
        let legacyStorageName = "notificationRecords.v1"
        UserDefaults(suiteName: suite)?.removeObject(forKey: legacyStorageName)

        let recordsBox = activeRecords
        let roomCoordinator = RoomListCoordinator(
            port: MatrixRoomListPort(session: session, hasRecords: { room in
                recordsBox.current?.all().contains { $0.roomID == room } ?? false
            }),
            loadsAllPages: true, hiddenRooms: MatrixHiddenRoomsPort(session: session), profiles: profilePort
        )
        self.roomCoordinator = roomCoordinator

        let receipts = ReadReceiptCoordinator(
            port: MatrixReadMarkerPort(session: session),
            privateReceipts: preferences.privateReceipts,
            log: log
        )
        self.receipts = receipts
        drafts = DraftCoordinator()
        let stickerPackPort = MatrixStickerPackPort(session: session)
        let stickers = StickerLibrary(
            packs: stickerPackPort,
            prefs: MatrixStickerPrefsPort(session: session)
        )
        self.stickers = stickers
        self.stickerPackManager = StickerPackManager(
            port: MatrixStickerPackManagementPort(session: session, packs: stickerPackPort),
            preparer: ImagePreparer(maximumDimension: 512),
            library: stickers
        )
        readState = ReadStateCoordinator(rooms: roomCoordinator, port: SystemBadge(suiteName: suite), receipts: receipts)

        timelinePort = MatrixTimelinePort(session: session)
        botActivity = BotActivityCoordinator(timelines: timelinePort)
        media = MediaLoader(port: MatrixMediaPort(session: session))
        previewPolicy = MatrixMediaPreviewPolicyPort(session: session)
        roomPort = MatrixRoomPort(session: session)
        chatCreation = MatrixChatCreationPort(session: session)
        recovery = RecoveryViewModel(coordinator: EncryptionCoordinator(port: MatrixEncryptionPort(session: session), session: sessionCoordinator))
        sync = SyncCoordinator(port: MatrixSyncPort(session: session), session: sessionCoordinator)
        let push = Self.pushConfiguration().map {
            PushCoordinator(port: MatrixPushPort(session: session), session: sessionCoordinator, appID: $0.appID, gatewayURL: $0.gateway)
        }
        self.push = push

        Task {
            await sessionCoordinator.setBeforeSignOut {
                await receipts.flush()
                await stickers.flush()
                await push?.unregister()
            }
        }

        let webAuth = self.webAuth
        auth = AuthViewModel(coordinator: sessionCoordinator, runWebAuth: { url in
            await webAuth.authenticate(url: url, callbackScheme: "one.mbm.halo")
        })
        roomList = RoomListViewModel(
            session: sessionCoordinator, rooms: roomCoordinator, readState: readState,
            sync: sync, receipts: receipts, actions: roomPort, media: media
        )
        shareHandoff = ShareHandoffViewModel(coordinator: ShareCoordinator(
            inbox: FileShareInbox(directory: HaloShared.shareInboxDirectory()), timelines: timelinePort
        ))
        let siriSend = SiriSendCoordinatorBox(SiriSendCoordinator(session: sessionCoordinator, timelines: timelinePort))
        AppDependencyManager.shared.add(dependency: OpenChatRequestBox(self.openChat))
        AppDependencyManager.shared.add(dependency: FocusFilterStateBox(self.focus))
        AppDependencyManager.shared.add(dependency: siriSend)
        roomList.warm = { [timelinePort] rooms in await timelinePort.warm(rooms) }
        roomList.botSenders = { [preferences] in Set(preferences.botSenders) }

        #if DEBUG
        Self.exportNSEMetrics(namespace: namespace)
        #endif
        self.log = log
        log.info("app launched")
    }
}

extension AppRoot {
    /// Starts everything that must run whenever the process runs, with or without a window: iOS launches the app in the
    /// background for a silent push or an app refresh without connecting a scene. Call it as often as you like.
    func begin() async {
        guard !hasBegun else { return }
        hasBegun = true
        await push?.begin()
        await readState.begin()
        Task { await followReadIntents() }
        await sync.begin()
        await roomList.start()  // subscribes the room list, which the badge is computed from
        await recovery.start()  // before the banner exists: a hidden banner view runs no task
        await auth.start()
    }
}

final class ActiveRecordsBox: Sendable {
    private let value = Mutex<(any NotificationRecordPort)?>(nil)
    var current: (any NotificationRecordPort)? {
        get { value.withLock { $0 } }
        set { value.withLock { $0 = newValue } }
    }
}
