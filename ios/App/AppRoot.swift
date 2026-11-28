import AppIntents
import FeatureBotActivity
import FeatureOnboarding
import FeatureRoomList
import FeatureTimeline
import Foundation
import HaloApplication
import HaloDomain
import HaloFoundation
import HaloMatrixAdapter
import HaloPersistence
import HaloPlatform
import Synchronization
import UIKit

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

    /// The timeline of a room chosen in the chat list, started before its screen is pushed (M19-9, D-MOT-2).
    lazy var preparedTimelines = PreparedTimelines { [unowned self] room in makeTimeline(room: room) }
    /// The pictures the timelines have shown, one bounded store for all of them (M19-9): a re-opened room paints them at once.
    let thumbnailMemory = TimelineThumbnailMemory(byteLimit: 32 * 1024 * 1024)
    private var memoryWarning: (any NSObjectProtocol)?

    let attentionCache: AttentionCache
    let activeRecords = ActiveRecordsBox()
    let timelinePort: MatrixTimelinePort
    let roomListPort: MatrixRoomListPort
    let sessionCoordinator: SessionCoordinator
    let matrixSession: MatrixSessionPort
    /// Tracks Low Power Mode, thermal state, and network reachability for sync and background scheduling (M19-7).
    private let deviceConditionsBox = DeviceConditionsBox()
    private var deviceConditions: DeviceConditions?
    private var conditionUpdateTask: Task<Void, Never>?
    /// Whether protected data (the search index file) is readable, and the lock/unlock calls into search.
    var searchLock: ProtectedData?
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
    let search: MessageSearchEngine
    let roomCoordinator: RoomListCoordinator
    /// Matrix links from taps in messages and from outside; asks before joining or starting a chat (M18-9).
    lazy var matrixLinks = MatrixLinkCoordinator(
        isSignedIn: { [unowned self] in if case .signedIn = auth.screen { true } else { false } },
        joinedRooms: { [unowned self] in Set(await roomCoordinator.rooms.filter { $0.membership == .joined }.map(\.id)) },
        chats: chatCreation
    )
    /// Reply and Mark as read on a notification, also when iOS starts Halo in the background for them (M18-7).
    lazy var notificationActions = NotificationActionCoordinator(
        send: { [unowned self] text, room throws(HaloError) in
            try await SiriSendCoordinator(session: sessionCoordinator, timelines: timelinePort).send(text: text, to: room)
        },
        markRead: { [unowned self] room, time throws(HaloError) in
            guard await sessionIsReady() else { throw HaloError.unauthorized(soft: false) }
            try await receipts.markRoomRead(room, latestEventTime: time)
        },
        keepDraft: { [unowned self] text, room in await drafts.save(text, for: room) }
    )
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
    var roomFirstRows: HaloSignpost.Running?
    /// The room whose chat-list row was just tapped: its timing began at the tap, not when it reached the navigation path.
    var roomChosen: RoomID?
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
        AccountDataEraser.prepareStoreFolders(.standard())  // stores stay out of backups from the first byte
        let conditionsBox = deviceConditionsBox
        let session = MatrixSessionPort(
            baseDirectory: HaloShared.storeDirectory(),
            readStoredSession: {
                (try? keychain.readSync(.session)).flatMap { try? JSONDecoder().decode(StoredSession.self, from: $0) }
            },
            syncConditions: { conditionsBox.syncConditions }
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

        let suite = "group.\(HaloShared.namespace())"
        attentionCache = AttentionCache(suiteName: suite)
        let legacyStorageName = "notificationRecords.v1"
        UserDefaults(suiteName: suite)?.removeObject(forKey: legacyStorageName)

        let recordsBox = activeRecords
        let roomListPort = MatrixRoomListPort(
            session: session,
            hasRecords: { room in
                recordsBox.current?.all().contains { $0.roomID == room } ?? false
            },
            eventTimeCacheFile: HaloShared.eventTimeCacheFile()
        )
        self.roomListPort = roomListPort
        let roomCoordinator = RoomListCoordinator(
            port: roomListPort,
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
        let encryption = EncryptionCoordinator(port: MatrixEncryptionPort(session: session), session: sessionCoordinator)
        recovery = RecoveryViewModel(coordinator: encryption)
        let search = MessageSearchEngine(
            source: MatrixMessageIndexSource(session: session), rooms: roomCoordinator, profiles: profilePort, encryption: encryption,
            preferences: preferences, environment: MessageSearchEngine.environment(conditions: conditionsBox, log: log), log: log)
        self.search = search
        // The index file is unreadable while the phone is locked (D124): it closes before and opens again after.
        searchLock = ProtectedData(
            willLock: { [weak search] in Task { @MainActor in await search?.phoneWillLock() } },
            didUnlock: { [weak search] in Task { @MainActor in await search?.phoneUnlocked() } })
        let gate = search.gate
        sync = SyncCoordinator(port: MatrixSyncPort(session: session), session: sessionCoordinator, beforeStart: { await gate.wait() })
        let push = Self.pushConfiguration().map {
            PushCoordinator(port: MatrixPushPort(session: session), session: sessionCoordinator, appID: $0.appID, gatewayURL: $0.gateway)
        }
        self.push = push

        Task {
            await sessionCoordinator.setBeforeSignOut {
                await receipts.flush()
                await stickers.flush()
                await search.stop()
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
        roomList.botSenders = { [preferences] in Set(preferences.botSenders) }

        #if DEBUG
        Self.exportNSEMetrics(namespace: namespace)
        #endif
        self.log = log
        // The adapter keeps the SDK timelines of the top rooms ready; skipped under Low Power Mode or thermal stress (M19-7, M19-9).
        roomList.warm = { [timelinePort, conditionsBox] rooms in
            guard !SyncEnergyPolicy.schedule(for: conditionsBox.syncConditions).pauseAuxiliaryWork else { return }
            await timelinePort.warm(rooms)
        }
        let readStateRef = readState
        let device = DeviceConditions { [weak self, session, readStateRef, conditionsBox] in
            Task { @MainActor in
                self?.applyDeviceConditions(session: session, readState: readStateRef, conditionsBox: conditionsBox)
                self?.search.conditionsChanged()
            }
        }
        deviceConditions = device
        conditionsBox.current = device
        applyDeviceConditions(session: session, readState: readStateRef, conditionsBox: conditionsBox)
        // Under memory pressure a timeline started for a room not yet pushed goes first.
        memoryWarning = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.preparedTimelines.dropAll()
                self?.thumbnailMemory.removeAll()
            }
        }
        log.info("app launched")
    }
}

extension AppRoot {
    /// Begins the `room-open` and `room-first-rows` signposts (a room is being opened); `chosen` when a chat-list row was tapped.
    func beginRoomOpen(chosen: RoomID? = nil) {
        roomChosen = chosen
        roomOpen = HaloSignpost.begin(.roomOpen)
        roomFirstRows = HaloSignpost.begin(.roomFirstRows)
    }

    /// Background refresh interval adapted to Low Power Mode and thermal state (M19-7).
    nonisolated var backgroundRefreshInterval: TimeInterval {
        SyncEnergyPolicy.schedule(for: deviceConditionsBox.syncConditions).backgroundRefreshInterval
    }

    /// Serialises device-condition notifications so rapid transitions never apply stale low-energy flags out of order.
    fileprivate func applyDeviceConditions(
        session: MatrixSessionPort,
        readState: ReadStateCoordinator,
        conditionsBox: DeviceConditionsBox
    ) {
        let previous = conditionUpdateTask
        conditionUpdateTask = Task {
            await previous?.value
            await session.conditionsChanged()
            let pause = SyncEnergyPolicy.schedule(for: conditionsBox.syncConditions).pauseAuxiliaryWork
            await readState.setLowEnergyMode(pause)
        }
    }

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

final class DeviceConditionsBox: Sendable {
    private let value = Mutex<DeviceConditions?>(nil)
    var current: DeviceConditions? {
        get { value.withLock { $0 } }
        set { value.withLock { $0 = newValue } }
    }

    var syncConditions: SyncEnergyPolicy.Conditions {
        guard let snap = current?.snapshot else { return .init() }
        return SyncEnergyPolicy.Conditions(lowPower: snap.lowPower, isHot: snap.isHot, offline: snap.offline)
    }

    var searchDevice: MessageSearchEngine.DeviceState {
        guard let snap = current?.snapshot else { return .init() }
        return .init(lowPower: snap.lowPower, isHot: snap.isHot, onMobileData: snap.onMobileData, offline: snap.offline)
    }
}
