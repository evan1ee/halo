import FeatureAuth
import FeatureRoomList
import FeatureRoomDetails
import FeatureSettings
import FeatureStickers
import FeatureTimeline
import Foundation
import HaloApplication
import HaloDomain
import HaloFoundation
import HaloMatrixAdapter
import HaloPersistence
import HaloPlatform
import UserNotifications

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
    private let unrecognisedBots = UnrecognisedBotMessages()
    private let previewPolicy: any MediaPreviewPolicyPort
    private let roomPort: MatrixRoomPort
    private let chatCreation: MatrixChatCreationPort
    private let profilePort: MatrixProfilePort
    private let roomCoordinator: RoomListCoordinator
    private let log: HaloLog
    private var auditPort: (any AuditEventPort)?

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
        let roomCoordinator = RoomListCoordinator(port: MatrixRoomListPort(session: session), loadsAllPages: true, hiddenRooms: MatrixHiddenRoomsPort(session: session))
        self.roomCoordinator = roomCoordinator
        let suite = "group.\(HaloShared.namespace())"
        records = NotificationRecordStore(suiteName: suite)
        let receipts = ReadReceiptCoordinator(port: MatrixReadMarkerPort(session: session), privateReceipts: AppPreferences().privateReceipts, log: log)
        self.receipts = receipts
        drafts = DraftCoordinator()
        let stickers = StickerLibrary(packs: MatrixStickerPackPort(session: session), prefs: MatrixStickerPrefsPort(session: session))
        self.stickers = stickers
        badge = BadgeCoordinator(rooms: roomCoordinator, records: records, port: SystemBadge(suiteName: suite), receipts: receipts)

        timelinePort = MatrixTimelinePort(session: session)
        media = MediaLoader(port: MatrixMediaPort(session: session))
        previewPolicy = MatrixMediaPreviewPolicyPort(session: session)
        roomPort = MatrixRoomPort(session: session)
        chatCreation = MatrixChatCreationPort(session: session)
        profilePort = MatrixProfilePort(session: session)
        recovery = RecoveryViewModel(coordinator: EncryptionCoordinator(port: MatrixEncryptionPort(session: session), session: sessionCoordinator))
        sync = SyncCoordinator(port: MatrixSyncPort(session: session), session: sessionCoordinator)
        let push = Self.pushConfiguration().map {
            PushCoordinator(port: MatrixPushPort(session: session), session: sessionCoordinator, appID: $0.appID, gatewayURL: $0.gateway)
        }
        self.push = push
        // While the session is still valid: send what is pending for this account, then remove the pusher.
        Task {
            await sessionCoordinator.setBeforeSignOut {
                await receipts.flush()
                await stickers.flush()
                await push?.unregister()
            }
        }
        auth = AuthViewModel(coordinator: sessionCoordinator)
        roomList = RoomListViewModel(session: sessionCoordinator, rooms: roomCoordinator, receipts: receipts, actions: roomPort, media: media)
        roomList.warm = { [timelinePort] rooms in await timelinePort.warm(rooms) }
        #if DEBUG
        Self.exportNSEMetrics(namespace: namespace)
        #endif
        self.log = log
        log.info("app launched")
    }

    /// Opens Halo's database for each signed-in account and restores the read intents and drafts it holds. When the
    /// account changes or signs out, everything kept in memory for the previous one is dropped first, so nothing of it is
    /// shown to, sent as, or written into the next account. Runs for the life of the app.
    func followReadIntents() async {
        var current: UserID?
        for await state in await sessionCoordinator.states() {
            switch state {
            case .ready(let user):
                guard user != current else { continue }  // the same account again (e.g. after a soft logout)
                if current != nil { await resetAccountState() }
                current = user
                do {
                    let directory = HaloShared.storeDirectory().appendingPathComponent("halo", isDirectory: true)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let database = try HaloDatabase(path: directory.appendingPathComponent("halo.sqlite").path)
                    await receipts.restore(from: ReadIntentStore(database: database, account: user))
                    await drafts.attach(DraftStore(database: database, account: user))
                    #if DEBUG
                    // The read-state auditor runs in debug (and later TestFlight) builds only (LOGGING_AND_DIAGNOSTICS §2).
                    let log = log
                    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
                    auditPort = AuditEventStore(database: database, account: user)
                    await badge.setAudit(.init(port: AuditEventStore(database: database, account: user), roomHash: { log.id($0) }, appVersion: version))
                    #endif
                } catch {
                    // Without a database, receipts and drafts still work from memory; there is nothing to restore.
                }
            case .signedOut:
                guard current != nil else { continue }
                current = nil
                await resetAccountState()
            default:
                continue
            }
        }
    }

    private func resetAccountState() async {
        await receipts.reset()
        await badge.setAudit(nil)
        auditPort = nil
        await badge.reset()
        await drafts.reset()
        await stickers.reset()
        await timelinePort.dropWarm()
    }

    private static func pushConfiguration() -> (appID: String, gateway: URL)? {
        guard let appID = Bundle.main.object(forInfoDictionaryKey: "HaloPushAppID") as? String, !appID.isEmpty,
              let raw = Bundle.main.object(forInfoDictionaryKey: "HaloPushGatewayURL") as? String, !raw.isEmpty,
              let gateway = URL(string: raw) else { return nil }
        return (appID, gateway)
    }

    /// The account's media preview setting for the Settings screen.
    /// The Settings → Diagnostics report: versions, device and read-state audit counts. No messages, names or account IDs.
    func diagnosticsReport() async -> String {
        let info = Bundle.main.infoDictionary
        var lines = [
            "Halo \(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))",
            "iOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
        ]
        lines.append("Bot messages shown as plain text (no template matched), this launch: \(unrecognisedBots.count)")
        if let auditPort {
            let events = (try? await auditPort.all().count).map(String.init) ?? "unavailable"
            let unexplained = (try? await auditPort.unexplainedCount()).map(String.init) ?? "unavailable"
            lines.append("Read-state audit: \(events) events, \(unexplained) unexplained")
        } else {
            lines.append("Read-state audit: off in this build")
        }
        return lines.joined(separator: "\n")
    }

    /// Settings → Storage: sizes of the Matrix store and of Halo's own database on this device.
    nonisolated func storageSizes() async -> [StorageSize] {
        let directory = HaloShared.storeDirectory()
        func size(of url: URL) -> Int64 {
            let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
            guard let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else { return 0 }
            var total: Int64 = 0
            for case let file as URL in files {
                let values = try? file.resourceValues(forKeys: Set(keys))
                if values?.isRegularFile == true { total += Int64(values?.totalFileAllocatedSize ?? 0) }
            }
            return total
        }
        let own = size(of: directory.appendingPathComponent("halo", isDirectory: true))
        return [StorageSize(name: "Messages and keys", bytes: max(0, size(of: directory) - own)), StorageSize(name: "Halo database", bytes: own)]
    }

    /// Settings → Notifications: what iOS currently allows.
    nonisolated func notificationStatus() async -> String {
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: "On"
        case .denied: "Off in iOS Settings"
        case .notDetermined: "Not asked yet"
        @unknown default: "Unknown"
        }
    }

    func mediaPreviewChoice() async -> MediaPreviewChoice {
        switch await previewPolicy.setting() {
        case .always: .always
        case .privateRoomsOnly: .privateRoomsOnly
        case .never: .never
        }
    }

    /// Stores the choice; `false` when it couldn't be saved.
    func setMediaPreviewChoice(_ choice: MediaPreviewChoice) async -> Bool {
        let setting: MediaPreviewSetting = switch choice {
        case .always: .always
        case .privateRoomsOnly: .privateRoomsOnly
        case .never: .never
        }
        do { try await previewPolicy.setSetting(setting); return true } catch { return false }
    }

    /// The "New chat" sheet (ROOM_MANAGEMENT FR-5); `onCreated` gets the room to open.
    func makeNewChat(onCreated: @escaping @MainActor (RoomID) -> Void) -> NewChatViewModel { NewChatViewModel(port: chatCreation, onCreated: onCreated) }

    /// The profile sheet of a room member (USER_PROFILES); `nil` when the member's ID is not valid.
    func makeUserProfile(member: RoomMemberInfo, onOpenRoom: @escaping @MainActor (RoomID) -> Void) -> UserProfileViewModel? {
        guard let user = try? UserID(member.userID) else { return nil }
        return UserProfileViewModel(profiles: profilePort, chats: chatCreation, user: user, roomDisplayName: member.displayName, isMe: member.isMe, onOpenRoom: onOpenRoom)
    }

    /// Settings → Account → Profile: the display name and the ignored users.
    func profileSettings() -> ProfileSettingsActions {
        let port = profilePort
        let media = media
        return ProfileSettingsActions(
            loadName: { try? await port.ownDisplayName() },
            saveName: { name in (try? await port.setOwnDisplayName(name)) != nil },
            loadIgnored: { (try? await port.ignoredUsers())?.map(\.rawValue) },
            unignore: { raw in
                guard let user = try? UserID(raw) else { return false }
                return (try? await port.unignore(user)) != nil
            },
            loadAvatar: {
                guard let ref = try? await port.ownAvatar() else { return nil }
                return try? await media.thumbnail(ref, width: 256, height: 256)
            },
            setAvatar: { data in
                guard let image = try? ImagePreparer(maximumDimension: 512).prepare(data: data, filename: "avatar") else { return false }
                return (try? await port.setOwnAvatar(mimeType: image.mimeType, data: image.data)) != nil
            },
            removeAvatar: { (try? await port.removeOwnAvatar()) != nil })
    }

    /// The room info sheet for `room` (ROOM_MANAGEMENT).
    func makeRoomDetails(room: RoomID) -> RoomDetailsViewModel { RoomDetailsViewModel(port: roomPort, room: room, images: ImagePreparer(maximumDimension: 512), media: media) }

    /// A view model for the timeline of `room`; each screen gets its own coordinator and session.
    func makeTimeline(room: RoomID) -> TimelineViewModel {
        let model = TimelineViewModel(
            coordinator: TimelineCoordinator(port: timelinePort, room: room, records: records), media: media, previewsAllowed: { [previewPolicy] in await previewPolicy.previewsAllowed(in: room) }, receipts: receipts, room: room, drafts: drafts, images: ImagePreparer(),
            // Where to land on opening: the user's own read position (a receipt from any device) at that moment.
            readThrough: { [roomCoordinator] in await roomCoordinator.rooms.first { $0.id == room }?.ownReadThrough })
        model.botSenders = Set(AppPreferences().botSenders)
        model.unrecognisedBotMessages = unrecognisedBots
        return model
    }

    /// The sticker panel for the timeline of `room`; sending goes through that timeline's view model.
    func makeStickerPanel(room: RoomID, timeline: TimelineViewModel) -> StickerPanelViewModel {
        let creator = StickerPackCreator(port: MatrixStickerPackCreationPort(session: matrixSession), preparer: ImagePreparer(maximumDimension: 512))
        return StickerPanelViewModel(
            library: stickers, media: media, room: room, newPack: { done in NewPackViewModel(creator: creator, onCreated: done) },
            notice: StickerPanelViewModel.EncryptionNotice(
                roomIsEncrypted: { [roomCoordinator] in await roomCoordinator.rooms.first { $0.id == room }?.isEncrypted ?? false },
                isAcknowledged: { UserDefaults.standard.bool(forKey: "halo.stickers.encryptionNoticeSeen") },
                acknowledge: { UserDefaults.standard.set(true, forKey: "halo.stickers.encryptionNoticeSeen") }),
            send: { sticker throws(HaloError) in try await timeline.sendSticker(sticker) })
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
