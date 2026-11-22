import FeatureAuth
import FeatureBotActivity
import FeatureRoomDetails
import FeatureRoomList
import FeatureSettings
import FeatureStickers
import FeatureTimeline
import HaloApplication
import HaloDesignSystem
import HaloDomain
import HaloFoundation
import HaloPersistence
import SwiftUI
import UIKit
import UserNotifications

/// Composition root of the app (AGENTS.md §5: wiring only). Screens live in the Feature packages.
@main
struct HaloApp: App {
    @State private var root = AppRoot()
    @UIApplicationDelegateAdaptor(PushDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            RootView(root: root)
        }
    }
}

private enum HomeRoute: Hashable {
    case room(RoomID)
    case globalMediaGallery
}

private struct RootView: View {
    let root: AppRoot
    @Environment(\.scenePhase) private var scenePhase
    @State private var path: [HomeRoute] = []
    @State private var newChat: NewChatViewModel?
    @State private var messageSearch: MessageSearchViewModel?
    @State private var roomInfo: RoomDetailsViewModel?
    @State private var activity: BotActivityViewModel?
    /// The message to scroll to in the room about to open (from Activity); consumed by that room's screen.
    @State private var pendingEvent: EventID?
    @State private var ownName = ""
    @State private var ownAvatar: Data?
    @AppStorage(AppPreferences.appearanceKey) private var appearance = Appearance.system.rawValue
    @AppStorage(AppPreferences.privacyBlurKey) private var privacyBlur = true

    private var colorScheme: ColorScheme? {
        switch Appearance(rawValue: appearance) ?? .system {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    /// The user's own name and photo for the avatar button; kept as is when they can't be read.
    private func refreshOwnProfile() async {
        let profile = root.profileSettings()
        if let name = await profile.loadName() { ownName = name }
        ownAvatar = await profile.loadAvatar()
    }

    var body: some View {
        Group {
            switch root.auth.screen {
            case .signedIn:
                NavigationStack(path: $path) {
                    RoomListView(
                        model: root.roomList,
                        onRoomInfo: { roomInfo = root.makeRoomDetails(room: $0) },
                        onMediaGallery: { path.append(.globalMediaGallery) }
                    ) { path.append(.room($0)) }
                    .navigationTitle("")
                    .navigationBarTitleDisplayMode(.inline)
                    .task { await refreshOwnProfile() }
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            // Destination-based: the stack's path is typed to `RoomID`, so a value link of another type can't push.
                            NavigationLink {
                                SettingsView(
                                    version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?",
                                    build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?",
                                    onPrivateReceiptsChange: { value in Task { await root.receipts.setPrivateReceipts(value) } },
                                    saveBotSenders: { await root.saveBotSenders($0) },
                                    loadMediaPreviews: { await root.mediaPreviewChoice() },
                                    saveMediaPreviews: { await root.setMediaPreviewChoice($0) },
                                    profile: root.profileSettings(),
                                    stickerPacks: root.stickerPackSettings(),
                                    devices: root.deviceSettings(),
                                    changePassword: root.changePasswordActions(),
                                    verifyDevice: VerifyDeviceAction(isNeeded: { root.recovery.needsRecovery }, makeView: { AnyView(RecoveryView(model: root.recovery)) }),
                                    diagnostics: { await root.diagnosticsReport() },
                                    exportDiagnosticsZip: { await root.exportDiagnosticsZip() },
                                    reconcile: { await root.reconcileNow() },
                                    unexplainedAuditCount: { await root.unexplainedAuditCount() },
                                    storageSizes: { await root.storageSizes() },
                                    clearCache: { await root.clearMediaCache() },
                                    security: { [StorageSize(name: "This device", text: root.recovery.deviceStatus), StorageSize(name: "Recovery key", text: root.recovery.recoveryStatus)] },
                                    setUpRecovery: {
                                        switch await root.recovery.setUpRecovery() {
                                        case .success(let key): .success(key)
                                        case .failure(let failure): .failure(SettingsMessage(failure.text, offersReplace: failure.backupExists))
                                        }
                                    },
                                    replaceRecovery: {
                                        switch await root.recovery.replaceRecovery() {
                                        case .success(let key): .success(key)
                                        case .failure(let failure): .failure(SettingsMessage(failure.text))
                                        }
                                    },
                                    notificationDefaults: root.notificationDefaults(),
                                    notificationStatus: { await root.notificationStatus() },
                                    openSystemSettings: {
                                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                                    },
                                    onNewChat: {
                                        newChat = root.makeNewChat { room in
                                            newChat = nil
                                            path.append(.room(room))
                                        }
                                    },
                                    onSignOut: { Task { await root.auth.signOut() } })
                                .navigationBarTitleDisplayMode(.large)
                            } label: { AvatarCircle(name: ownName.isEmpty ? (root.signedInUserID ?? "?") : ownName, imageData: ownAvatar, size: 30)
                                .overlay(alignment: .topTrailing) {
                                    if root.recovery.needsRecovery {
                                        Circle().fill(HaloColor.warning).frame(width: 10, height: 10)
                                            .overlay(Circle().stroke(.background, lineWidth: 1.5))
                                            .accessibilityIdentifier("verify-dot")
                                    }
                                } }
                                .accessibilityLabel("Settings")
                                .accessibilityIdentifier("settings")
                        }
                        ToolbarItem(placement: .topBarTrailing) {
                            RoomListFilterMenu(model: root.roomList)
                        }
                        ToolbarItem(placement: .topBarTrailing) {
                            Button { messageSearch = root.makeMessageSearch() } label: { Image(systemName: "magnifyingglass") }
                                .accessibilityLabel("Search")
                                .accessibilityIdentifier("search")
                        }
                        if !AppPreferences().botSenders.isEmpty {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button { activity = root.makeBotActivity() } label: { Image(systemName: "checklist") }
                                    .accessibilityLabel("Activity")
                                    .accessibilityIdentifier("activity")
                            }
                        }
                    }
                    .onChange(of: root.roomList.content) { Task { await root.scanBotRooms() } }
                    .sheet(item: $newChat) { NewChatView(model: $0) }
                    .sheet(item: $messageSearch) { model in
                        MessageSearchView(model: model) { room, event in
                            messageSearch = nil
                            pendingEvent = event
                            path.append(.room(room))
                        }
                    }
                    .sheet(item: $activity) { model in
                        BotActivityView(model: model) { room, event in
                            activity = nil
                            pendingEvent = event
                            path.append(.room(room))
                        }
                    }
                    .sheet(item: $roomInfo) {
                        RoomDetailsView(
                            model: $0,
                            profile: { member in
                                root.makeUserProfile(member: member) { target in
                                    roomInfo = nil
                                    path.append(.room(target))
                                }
                            })
                    }
                    .navigationDestination(for: HomeRoute.self) { route in
                        switch route {
                        case .room(let room):
                            TimelineScreen(root: root, room: room, jumpTo: pendingEvent, openRoom: { path.append(.room($0)) })
                                .onAppear { pendingEvent = nil }
                        case .globalMediaGallery:
                            GlobalMediaGalleryScreen(root: root) { room, event in
                                pendingEvent = event
                                path.append(.room(room))
                            }
                        }
                    }
                }
            default:
                SignInView(model: root.auth)
            }
        }
        .task {
            PushDelegate.coordinator = root.push
            PushDelegate.onNotificationTap = { room, event in
                pendingEvent = event
                if path.last != .room(room) {
                    path.append(.room(room))
                }
            }
            await root.push?.begin()
            await root.readState.begin()
            Task { await root.followReadIntents() }
            await root.sync.begin()
            await root.recovery.start()  // before the banner exists: a hidden banner view runs no task
            await root.auth.start()
        }
        .preferredColorScheme(colorScheme)
        .overlay {
            if privacyBlur && scenePhase != .active {
                ZStack {
                    Rectangle().fill(.ultraThinMaterial)
                    Image(systemName: "lock.shield.fill")
                        .font(.largeTitle)
                        .imageScale(.large)
                        .foregroundStyle(HaloColor.textSecondary)
                }
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
        .onOpenURL { url in
            Task {
                guard let target = await root.resolveMatrixLink(url) else { return }
                pendingEvent = target.event
                if path.last != .room(target.room) {
                    path.append(.room(target.room))
                }
            }
        }
        // Ask for notification permission once signed in; the token then arrives in `PushDelegate`.
        .task(id: root.auth.screen) {
            guard root.push != nil, case .signedIn = root.auth.screen else { return }
            if (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) == true {
                UIApplication.shared.registerForRemoteNotifications()
            }
        }
        // Sync and periodic read-state auditing run only in the foreground (SYNC_ENGINE §2 rule 1, LOGGING_AND_DIAGNOSTICS §2).
        // Wrap the background receipt flush in a UIKit background task (R-22) and suspend GRDB pools before iOS suspends
        // the process so no SQLite lock is held in the shared App Group container (R-25 / 0xdead10cc).
        .task(id: scenePhase) {
            switch scenePhase {
            case .active:
                HaloDatabase.resumeAll()
                await root.setForeground(true)
                await root.receipts.flush()
            case .background:
                let lease = BackgroundTaskLease(name: "halo.receipts.flush", onEnd: { HaloDatabase.suspendAll() })
                defer { lease.end() }
                await root.setForeground(false)
                await root.receipts.flush()
            case .inactive:
                let lease = BackgroundTaskLease(name: "halo.receipts.flush")
                defer { lease.end() }
                await root.setForeground(false)
                await root.receipts.flush()
            @unknown default:
                await root.setForeground(false)
            }
        }
    }
}

/// Keeps a UIKit background-task assertion alive until `end()` or iOS's expiration handler (R-22).
@MainActor
private final class BackgroundTaskLease {
    private var id: UIBackgroundTaskIdentifier = .invalid
    private let onEnd: (@MainActor () -> Void)?

    init(name: String, onEnd: (@MainActor () -> Void)? = nil) {
        self.onEnd = onEnd
        id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            MainActor.assumeIsolated { self?.end() }
        }
    }

    func end() {
        guard id != .invalid else { return }
        let ending = id
        id = .invalid
        onEnd?()
        UIApplication.shared.endBackgroundTask(ending)
    }
}

/// Keeps the view model alive for the lifetime of the pushed screen.
private struct TimelineScreen: View {
    @State private var model: TimelineViewModel
    @State private var stickers: StickerPanelViewModel
    @State private var details: RoomDetailsViewModel?
    @State private var activeThread: ThreadSelection?
    @State private var title = ""
    @Environment(\.dismiss) private var dismiss
    private let root: AppRoot
    private let room: RoomID
    private let openRoom: @MainActor (RoomID) -> Void

    private struct ThreadSelection: Identifiable {
        let rootEvent: EventID
        var id: String { rootEvent.rawValue }
    }

    init(root: AppRoot, room: RoomID, jumpTo: EventID? = nil, openRoom: @escaping @MainActor (RoomID) -> Void) {
        self.openRoom = openRoom
        self.root = root
        self.room = room
        let timeline = root.makeTimeline(room: room)
        timeline.initialEvent = jumpTo
        _model = State(initialValue: timeline)
        _stickers = State(initialValue: root.makeStickerPanel(room: room, timeline: timeline))
    }

    var body: some View {
        TimelineView(
            model: model,
            stickerPanel: { AnyView(StickerPanelView(model: stickers)) },
            onOpenThread: { eventID in activeThread = ThreadSelection(rootEvent: eventID) }
        ).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // The room's name, so it's clear where you are; tapping it opens the room info, like the button.
                ToolbarItem(placement: .principal) {
                    Button { details = root.makeRoomDetails(room: room) } label: {
                        Text(title).font(.headline).lineLimit(1).foregroundStyle(.primary)
                    }
                    .accessibilityIdentifier("roomTitle")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { details = root.makeRoomDetails(room: room) } label: { Image(systemName: "info.circle") }
                        .accessibilityLabel("Room info")
                        .accessibilityIdentifier("roomInfo")
                }
            }
            .sheet(item: $details, onDismiss: { Task { title = await root.roomName(room) ?? title } }) { model in
                RoomDetailsView(
                    model: model,
                    profile: { member in root.makeUserProfile(member: member, onOpenRoom: { room in details = nil; openRoom(room) }) },
                    onRenamed: { title = $0 },
                    onLeft: { dismiss() })
            }
            .sheet(item: $activeThread) { thread in
                ThreadSheet(root: root, room: room, rootEvent: thread.rootEvent)
            }
            .task { title = await root.roomName(room) ?? "Unnamed room" }
    }
}

/// Focused thread timeline sheet (M10 Threads, `TimelineFocus.thread`).
private struct ThreadSheet: View {
    @State private var model: TimelineViewModel
    @Environment(\.dismiss) private var dismiss

    init(root: AppRoot, room: RoomID, rootEvent: EventID) {
        _model = State(initialValue: root.makeTimeline(room: room, threadRoot: rootEvent))
    }

    var body: some View {
        NavigationStack {
            TimelineView(model: model)
                .navigationTitle("Thread")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
    }
}

/// Receives the APNs device token and handles notification taps (PUSH_NOTIFICATIONS §2, NOTIFICATIONS §5).
final class PushDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    @MainActor static var coordinator: PushCoordinator?
    @MainActor static var onNotificationTap: (@MainActor (RoomID, EventID?) -> Void)?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in await Self.coordinator?.deviceTokenReceived(deviceToken) }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let threadID = response.notification.request.content.threadIdentifier
        let roomRaw = (userInfo["room_id"] as? String) ?? (threadID.isEmpty ? nil : threadID)
        let eventRaw = userInfo["event_id"] as? String
        if let roomRaw, let room = try? RoomID(roomRaw) {
            let event = eventRaw.flatMap { try? EventID($0) }
            Task { @MainActor in
                Self.onNotificationTap?(room, event)
            }
        }
        completionHandler()
    }
}

/// Keeps the global media gallery view model alive for the lifetime of the pushed preset room screen (D34, D83).
private struct GlobalMediaGalleryScreen: View {
    @State private var model: GlobalMediaGalleryViewModel
    private let onJumpToMessage: @MainActor (RoomID, EventID) -> Void

    init(root: AppRoot, onJumpToMessage: @escaping @MainActor (RoomID, EventID) -> Void) {
        _model = State(initialValue: root.makeGlobalMediaGallery())
        self.onJumpToMessage = onJumpToMessage
    }

    var body: some View {
        GlobalMediaGalleryView(model: model, onJumpToMessage: onJumpToMessage)
    }
}
