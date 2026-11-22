import CoreSpotlight
import FeatureBotActivity
import FeatureComposer
import FeatureMedia
import FeatureOnboarding
import FeatureProfile
import FeatureRoomDetails
import FeatureRoomList
import FeatureSearch
import FeatureSettings
import FeatureStickers
import FeatureTimeline
import HaloApplication
import HaloDesignSystem
import HaloDomain
import HaloFoundation
import HaloPlatform
import HaloPersistence
import SwiftUI
import UIKit
import UserNotifications

/// Composition root of the app (AGENTS.md §5: wiring only; D85 single-stack navigation).
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

private struct RootView: View {
    let root: AppRoot
    @Environment(\.scenePhase) private var scenePhase
    @SceneStorage("halo.navigation.path") private var savedPath: Data?
    @State private var router = ChatsRouter(replacesDetail: UIDevice.current.userInterfaceIdiom == .pad)
    @State private var compactColumn: NavigationSplitViewColumn = .sidebar
    @State private var searchPresented = false
    @State private var pathRestored = false
    @State private var searchModel: MessageSearchViewModel
    @State private var newChat: NewChatViewModel?
    @State private var roomInfo: RoomDetailsViewModel?
    @State private var showingNotificationPriming = false
    @State private var showingWhatsNew = false
    @State private var ownName = ""
    @State private var ownAvatar: Data?
    @AppStorage("halo.onboarding.notificationPrimingShown") private var notificationPrimingShown = false

    init(root: AppRoot) {
        self.root = root
        _searchModel = State(initialValue: root.makeMessageSearch())
    }

    private struct ShortcutInputs: Equatable {
        let content: RoomListViewModel.Content
        let enabled: Bool
        let auth: AuthViewModel.Screen
    }

    private func openRequestedChat() {
        guard case .signedIn = root.auth.screen, let room = root.openChat.pending else { return }
        root.openChat.pending = nil
        router.openRoom(room)
    }

    /// The joined chats the share sheet offers.
    private var shareTargets: [ShareTargetPickerView.Target] {
        guard case .loaded(_, let rows) = root.roomList.content else { return [] }
        return rows.filter { !$0.isInvite }.map { ShareTargetPickerView.Target(id: $0.id, name: $0.name) }
    }

    private var colorScheme: ColorScheme? {
        switch root.preferences.appearance {
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

    /// ⌘1…⌘6 pick the room-list filters in menu order (hardware keyboard on iPad, M16 D91).
    private static func filterShortcut(for filter: RoomListFilter) -> KeyEquivalent {
        let index = filterOptions.firstIndex { $0.filter == filter } ?? 0
        return KeyEquivalent(Character("\(index + 1)"))
    }

    private static let filterOptions: [(filter: RoomListFilter, title: String, symbol: String)] = [
        (.all, "All", "tray.full"),
        (.unread, "Unread", "envelope.badge"),
        (.people, "People", "person.2"),
        (.rooms, "Rooms", "bubble.left.and.bubble.right"),
        (.favourites, "Favourites", "star"),
        (.invites, "Invites", "envelope.open"),
    ]

    /// The chat list with its toolbar, search and sheets: the whole screen on iPhone, the sidebar on iPad.
    @ViewBuilder private var roomListRoot: some View {
                    RoomListView(
                        model: root.roomList,
                        searchQuery: searchModel.query,
                        onRoomInfo: { roomInfo = root.makeRoomDetails(room: $0) },
                        onMediaGallery: { router.push(.globalMediaGallery) },
                        onSelect: { router.openRoom($0) }
                    ) {
                        MessageSearchResultsSection(model: searchModel) { room, event in
                            router.openRoom(room, focus: event)
                        }
                    }
                    .navigationTitle("Chats")
                    .navigationBarTitleDisplayMode(.large)
                    .searchable(text: $searchModel.query, isPresented: $searchPresented, prompt: "Search chats & messages")
                    .background {
                        // ⌘F starts a search (hardware keyboard).
                        Button("Search") { searchPresented = true }
                            .keyboardShortcut("f", modifiers: .command)
                            .opacity(0)
                            .accessibilityHidden(true)
                    }
                    .onSubmit(of: .search) { Task { await searchModel.submit() } }
                    .task(id: searchModel.query) {
                        let trimmed = searchModel.query.trimmingCharacters(in: .whitespacesAndNewlines)
                        if trimmed.isEmpty {
                            await searchModel.submit()
                            return
                        }
                        try? await Task.sleep(for: .milliseconds(300))
                        guard !Task.isCancelled else { return }
                        await searchModel.submit()
                    }
                    .task {
                        await searchModel.start()
                        await refreshOwnProfile()
                    }
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button { router.push(.settings) } label: {
                                AvatarCircle(name: ownName.isEmpty ? (root.signedInUserID ?? "?") : ownName, imageData: ownAvatar, size: 30)
                                    .overlay(alignment: .topTrailing) {
                                        if root.recovery.needsRecovery {
                                            Circle().fill(HaloColor.warning).frame(width: 10, height: 10)
                                                .overlay(Circle().stroke(.background, lineWidth: 1.5))
                                                .accessibilityIdentifier("verify-dot")
                                        }
                                    }
                            }
                            .accessibilityLabel("Settings")
                            .accessibilityIdentifier("settings")
                            .keyboardShortcut(",", modifiers: .command)
                        }
                        ToolbarItemGroup(placement: .topBarTrailing) {
                            moreMenu
                            Button {
                                newChat = root.makeNewChat { room in
                                    newChat = nil
                                    router.openRoom(room)
                                }
                            } label: {
                                Image(systemName: "square.and.pencil")
                            }
                            .accessibilityLabel("New chat")
                            .accessibilityIdentifier("compose-chat")
                            .keyboardShortcut("n", modifiers: .command)
                        }
                    }
                    .onChange(of: root.roomList.content) {
                        if !pathRestored, case .loaded = root.roomList.content {
                            pathRestored = true
                            router.restorePath(from: savedPath)
                            router.pruneInvalidRooms(joinedRoomIDs: root.roomList.joinedRoomIDs)
                        }
                        Task { await root.scanBotRooms() }
                    }
                    .onChange(of: router.path) { _, _ in
                        savedPath = router.encodePath()
                    }
                    .sheet(item: $newChat) { NewChatView(model: $0) }
                    .sheet(item: $roomInfo) { model in
                        RoomDetailsView(
                            model: model,
                            profileSheet: { member in
                                root.makeUserProfile(member: member) { target in
                                    roomInfo = nil
                                    router.openRoom(target)
                                }.map { AnyView(UserProfileView(model: $0)) }
                            }
                        )
                    }
    }

    /// iPad (M16, D91): the chat list as a sidebar and the router's path as the detail; narrow windows collapse to one column.
    private var splitShell: some View {
        NavigationSplitView(preferredCompactColumn: $compactColumn) {
            roomListRoot
        } detail: {
            NavigationStack(path: $router.path) {
                ContentUnavailableView("Select a chat", systemImage: "bubble.left.and.bubble.right")
                    .navigationDestination(for: ChatsRoute.self) { route in
                        destination(for: route)
                    }
            }
        }
        .onChange(of: router.path, initial: true) { compactColumn = router.path.isEmpty ? .sidebar : .detail }
    }

    private static var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    var body: some View {
        Group {
            switch root.auth.screen {
            case .signedIn:
                if Self.isPad {
                    splitShell
                } else {
                    NavigationStack(path: $router.path) {
                        roomListRoot
                            .navigationDestination(for: ChatsRoute.self) { route in
                                destination(for: route)
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
                router.openRoom(room, focus: event)
            }
            root.shareHandoff.onSent = { room in router.openRoom(room) }
            await root.push?.begin()
            await root.readState.begin()
            Task { await root.followReadIntents() }
            await root.sync.begin()
            await root.recovery.start()  // before the banner exists: a hidden banner view runs no task
            await root.auth.start()
        }
        .preferredColorScheme(colorScheme)
        .overlay {
            if root.preferences.privacyBlur && scenePhase != .active {
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
        // M16 Siri, Shortcuts and Spotlight: open a chat by name; chat names are offered only while the setting is on (D88).
        .onChange(of: root.focus.chats, initial: true) { root.roomList.setFocus(root.focus.chats) }
        .onChange(of: root.openChat.pending, initial: true) { openRequestedChat() }
        .onChange(of: root.auth.screen) { openRequestedChat() }
        .onContinueUserActivity(CSSearchableItemActionType) { activity in
            let identifier = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String
            if let room = HaloSpotlight.roomID(fromIdentifier: identifier) { root.openChat.request(room) }
        }
        .task(id: ShortcutInputs(content: root.roomList.content, enabled: root.preferences.chatsInSystemSearch, auth: root.auth.screen)) {
            var enabled = root.preferences.chatsInSystemSearch
            if case .signedIn = root.auth.screen {} else { enabled = false }
            await root.chatShortcuts.update(rooms: await root.roomCoordinator.rooms, enabled: enabled)
        }
        .onOpenURL { url in
            Task {
                guard let target = await root.resolveMatrixLink(url) else { return }
                router.openRoom(target.room, focus: target.event)
            }
        }
        // S14 Notifications priming (AC-UX-7, UX-07): explain why Halo needs notifications before showing the system prompt.
        .task(id: root.auth.screen) {
            guard root.push != nil, case .signedIn = root.auth.screen else { return }
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                UIApplication.shared.registerForRemoteNotifications()
            case .notDetermined where !notificationPrimingShown:
                showingNotificationPriming = true
            default:
                let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
                if root.preferences.lastSeenWhatsNewVersion != currentVersion {
                    showingWhatsNew = true
                }
            }
        }
        // M16 share extension: what another app shared waits in the App Group inbox until the person picks a chat.
        .task(id: root.auth.screen) {
            if case .signedIn = root.auth.screen { await root.shareHandoff.refresh() }
        }
        .sheet(isPresented: Binding(
            get: { root.shareHandoff.current != nil },
            set: { if !$0 { root.shareHandoff.sheetClosed() } }
        )) {
            ShareTargetPickerView(model: root.shareHandoff, targets: shareTargets)
        }
        .sheet(isPresented: $showingWhatsNew) {
            let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
            WhatsNewView(version: currentVersion) {
                root.preferences.lastSeenWhatsNewVersion = currentVersion
                showingWhatsNew = false
            }
        }
        .sheet(isPresented: $showingNotificationPriming) {
            NotificationPrimingView(
                onTurnOn: {
                    notificationPrimingShown = true
                    if (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) == true {
                        UIApplication.shared.registerForRemoteNotifications()
                    }
                    showingNotificationPriming = false
                },
                onNotNow: {
                    notificationPrimingShown = true
                    showingNotificationPriming = false
                }
            )
            .presentationDetents([.medium, .large])
        }
        // Sync and periodic read-state auditing run only in the foreground (SYNC_ENGINE §2 rule 1, LOGGING_AND_DIAGNOSTICS §2).
        .task(id: scenePhase) {
            switch scenePhase {
            case .active:
                HaloDatabase.resumeAll()
                await root.setForeground(true)
                if case .signedIn = root.auth.screen { await root.shareHandoff.refresh() }
                UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["halo.share.ready"])
                // M16 Focus filter: the system's current filter is the truth; a change missed in the background is caught here.
                root.focus.chats = (try? await HaloFocusFilter.current)?.chats.domain
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

    private var moreMenu: some View {
        Menu {
            Section("Filter") {
                ForEach(Self.filterOptions, id: \.title) { option in
                    Button {
                        root.roomList.filter = option.filter
                    } label: {
                        if root.roomList.filter == option.filter {
                            Label(option.title, systemImage: "checkmark")
                        } else {
                            Label(option.title, systemImage: option.symbol)
                        }
                    }
                    .accessibilityIdentifier("filter-\(option.title)")
                    .keyboardShortcut(Self.filterShortcut(for: option.filter), modifiers: .command)
                }
            }
            Section {
                Button {
                    router.push(.stickerLibrary)
                } label: {
                    Label("Stickers", systemImage: "sparkles.rectangle.stack")
                }
                .accessibilityIdentifier("more-stickers")
                if !root.preferences.botSenders.isEmpty {
                    Button {
                        router.push(.activity)
                    } label: {
                        Label("Activity", systemImage: "checklist")
                    }
                    .accessibilityIdentifier("more-activity")
                }
            }
        } label: {
            Image(systemName: root.roomList.filter == .all ? "ellipsis.circle" : "ellipsis.circle.fill")
        }
        .accessibilityLabel("More")
        .accessibilityIdentifier("more-menu")
    }

    @ViewBuilder
    private func destination(for route: ChatsRoute) -> some View {
        switch route {
        case .room(let room, let focus):
            TimelineScreen(
                root: root,
                room: room,
                jumpTo: focus,
                openRoom: { router.openRoom($0) },
                openThread: { router.openThread(room: room, rootEvent: $0) }
            )
        case .thread(let room, let rootEvent):
            ThreadScreen(root: root, room: room, rootEvent: rootEvent)
        case .settings:
            SettingsView(config: root.makeSettingsConfiguration(onOpenStickers: {
                router.push(.stickerLibrary)
            }))
            .navigationBarTitleDisplayMode(.large)
        case .stickerLibrary:
            StickerPackSettingsView(actions: root.stickerPackSettings())
                .navigationTitle("Stickers")
                .navigationBarTitleDisplayMode(.large)
        case .activity:
            BotActivityView(model: root.makeBotActivity()) { room, event in
                router.openRoom(room, focus: event)
            }
        case .globalMediaGallery:
            GlobalMediaGalleryScreen(root: root) { room, event in
                router.openRoom(room, focus: event)
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

/// Keeps the view model alive for the lifetime of the pushed room screen.
private struct TimelineScreen: View {
    @State private var model: TimelineViewModel
    @State private var stickers: StickerPanelViewModel
    @State private var details: RoomDetailsViewModel?
    @State private var title = ""
    @Environment(\.dismiss) private var dismiss
    private let root: AppRoot
    private let room: RoomID
    private let openRoom: @MainActor (RoomID) -> Void
    private let openThread: @MainActor (EventID) -> Void

    init(
        root: AppRoot,
        room: RoomID,
        jumpTo: EventID? = nil,
        openRoom: @escaping @MainActor (RoomID) -> Void,
        openThread: @escaping @MainActor (EventID) -> Void
    ) {
        self.openRoom = openRoom
        self.openThread = openThread
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
            onOpenThread: openThread
        )
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
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
                profileSheet: { member in
                    root.makeUserProfile(member: member, onOpenRoom: { room in details = nil; openRoom(room) })
                        .map { AnyView(UserProfileView(model: $0)) }
                },
                onRenamed: { title = $0 },
                onLeft: { dismiss() }
            )
        }
        .task { title = await root.roomName(room) ?? "Unnamed room" }
    }
}

/// Focused thread timeline pushed on the single `NavigationStack` (M10 Threads, D85).
private struct ThreadScreen: View {
    @State private var model: TimelineViewModel

    init(root: AppRoot, room: RoomID, rootEvent: EventID) {
        _model = State(initialValue: root.makeTimeline(room: room, threadRoot: rootEvent))
    }

    var body: some View {
        TimelineView(model: model)
            .navigationTitle("Thread")
            .navigationBarTitleDisplayMode(.inline)
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
