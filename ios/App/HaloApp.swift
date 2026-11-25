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
    @State private var root: AppRoot
    @UIApplicationDelegateAdaptor(PushDelegate.self) private var delegate

    init() {
        // iOS may prewarm the process long before the user opens the app; that time isn't a launch.
        let coldStart = ProcessInfo.processInfo.environment["ActivePrewarm"] == "1" ? nil : HaloSignpost.begin(.coldStart)
        // Not in a view: a background launch (silent push, app refresh) connects no scene, so no view ever appears.
        let root = AppRoot()
        root.coldStart = coldStart
        _root = State(initialValue: root)
        PushDelegate.coordinator = root.push
        PushDelegate.onBackgroundPush = { await root.refreshInBackground() ? .newData : .noData }
    }

    var body: some Scene {
        WindowGroup {
            RootView(root: root)
        }
        .backgroundTask(.appRefresh(BackgroundRefreshScheduler.identifier())) { [root] in
            BackgroundRefreshScheduler.schedule()
            _ = await root.refreshInBackground()
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
    @State private var showingNotificationPriming = false
    @State private var showingWhatsNew = false
    @State private var ownName = ""
    @State private var ownAvatar: Data?
    @State private var privacyCover = false
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

    /// The Focus filter narrows the chat list only when the user opted in; otherwise every chat shows (D104).
    private func applyFocusFilter() {
        root.roomList.setFocus(root.preferences.followFocusFilter ? root.focus.chats : nil)
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

    /// The user's own name and photo for the avatar button; kept as is when they can't be read. The last ones seen are
    /// shown at once from the device (founder: "the user avatar not show instantly"), then refreshed from the server.
    private func refreshOwnProfile() async {
        let user = root.signedInUserID
        if let cached = OwnProfileCache.load(user: user) {
            if ownName.isEmpty, let name = cached.name { ownName = name }
            if ownAvatar == nil { ownAvatar = cached.avatar }
        }
        let profile = root.profileSettings()
        if let name = await profile.loadName() { ownName = name }
        if let avatar = await profile.loadAvatar() { ownAvatar = avatar }
        OwnProfileCache.save(.init(user: user, name: ownName.isEmpty ? nil : ownName, avatar: ownAvatar))
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
                        onRoomInfo: { router.openRoomInfo($0) },
                        onMediaGallery: { router.push(.globalMediaGallery) },
                        onSelect: { router.openRoom($0) }
                    ) {
                        MessageSearchResultsSection(model: searchModel) { room, event in
                            router.openRoom(room, focus: event)
                        }
                    }
                    .navigationTitle("")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
                    .searchable(text: $searchModel.query, isPresented: $searchPresented, prompt: Self.isPad ? "Search" : "Search chats & messages")  // the iPad sidebar is too narrow for the long prompt at large text sizes
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
                                AvatarCircle(
                                    name: ownName.isEmpty ? (root.signedInUserID ?? "?") : ownName,
                                    imageData: ownAvatar,
                                    size: 30,
                                    showsOuterFrame: false,
                                    avatarBorderColor: root.recovery.needsRecovery ? HaloColor.warning : nil
                                )
                                .frame(width: 44, height: 44)
                                .contentShape(.circle)
                            }
                            .buttonStyle(.plain)
                            .glassEffect(.regular.interactive(), in: .circle)
                            .accessibilityLabel("Settings")
                            .accessibilityValue(root.recovery.needsRecovery ? "Verification needed" : "")
                            .accessibilityIdentifier("settings")
                            .keyboardShortcut(",", modifiers: .command)
                        }
                        .sharedBackgroundVisibility(.hidden)
                        ToolbarItemGroup(placement: .topBarTrailing) {
                            moreMenu
                        }
                    }
                    .onChange(of: root.roomList.content, initial: true) {
                        guard case .loaded = root.roomList.content else { return }
                        root.coldStart?.end()
                        root.coldStart = nil
                    }
                    .onChange(of: root.roomList.content) {
                        if !pathRestored, case .loaded = root.roomList.content {
                            pathRestored = true
                            // Only when nothing was opened yet: restoring (and pruning rooms the list hasn't shown yet)
                            // after the user already opened a room would pop it.
                            if router.path.isEmpty {
                                router.restorePath(from: savedPath)
                                router.pruneInvalidRooms(joinedRoomIDs: root.roomList.joinedRoomIDs)
                            }
                        }
                        Task { await root.scanBotRooms() }
                    }
                    .onChange(of: router.path) { old, new in
                        savedPath = router.encodePath()
                        if new.count > old.count || Self.isPad, case .room = new.last, new.last != old.last {
                            root.roomOpen = HaloSignpost.begin(.roomOpen)
                        }
                    }
                    .sheet(item: $newChat) { NewChatView(model: $0) }
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
            case .launching:
                // Restoring a stored session takes a fraction of a second: show the plain background the system launch
                // screen showed, not the sign-in logo (founder: "i can see the blue chat icon during the animation").
                HaloColor.bgPrimary.ignoresSafeArea()
            default:
                SignInView(model: root.auth)
            }
        }
        .task {
            PushDelegate.onNotificationTap = { room, event in
                router.openRoom(room, focus: event)
            }
            root.shareHandoff.onSent = { room in router.openRoom(room) }
            await root.begin()
        }
        .preferredColorScheme(colorScheme)
        .overlay {
            // D61: hides the chats in the app switcher's snapshot. Only while leaving (active → inactive → background), not
            // while launching or coming back, and without an icon (founder: "i can see the lock icon during the animation").
            if root.preferences.privacyBlur && privacyCover {
                Rectangle().fill(.ultraThinMaterial)
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
        // M16 Siri, Shortcuts and Spotlight: open a chat by name; chat names are offered only while the setting is on (D88).
        // M16 Focus filter (D90), only while Settings → Follow Focus filters is on (D104, default off).
        .onChange(of: root.focus.chats, initial: true) { applyFocusFilter() }
        .onChange(of: root.preferences.followFocusFilter) { applyFocusFilter() }
        .onChange(of: root.openChat.pending, initial: true) { openRequestedChat() }
        // The avatar button's cached name and photo: shown on the first frame once signed in, forgotten on sign-out.
        .onChange(of: root.auth.screen, initial: true) {
            switch root.auth.screen {
            case .signedIn:
                if ownAvatar == nil, ownName.isEmpty, let cached = OwnProfileCache.load(user: root.signedInUserID) {
                    ownName = cached.name ?? ""
                    ownAvatar = cached.avatar
                }
            case .server, .credentials:
                root.coldStart = nil
                OwnProfileCache.clear()
                ownName = ""
                ownAvatar = nil
            default:
                break
            }
        }
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
        .onChange(of: scenePhase) { old, new in
            switch new {
            case .active: privacyCover = false
            case .background: privacyCover = true
            case .inactive: privacyCover = old == .active  // leaving: cover; launching or returning: none
            @unknown default: break
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            // Synchronously clear the shared foreground flag before iOS suspends or terminates the app so the NSE
            // never sees a stale foreground state (R-08).
            root.attentionCache.setForeground(false)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willTerminateNotification)) { _ in
            root.attentionCache.setForeground(false)
        }
        .task(id: scenePhase) {
            switch scenePhase {
            case .active:
                HaloDatabase.resumeAll()
                await root.setForeground(true)
                await root.readState.reconcile()
                if case .signedIn = root.auth.screen { await root.shareHandoff.refresh() }
                UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["halo.share.ready"])
                // M16 Focus filter: the system's current filter is the truth; a change missed in the background is caught here.
                root.focus.chats = (try? await HaloFocusFilter.current)?.chats.domain
                await root.receipts.flush()
                await root.renewForeground()
            case .background:
                BackgroundRefreshScheduler.schedule(log: root.log)
                let lease = BackgroundTaskLease(name: "halo.receipts.flush", onEnd: { HaloDatabase.suspendAll() })
                defer { lease.end() }
                await root.setForeground(false)
                await root.receipts.flush()
                await root.readState.reconcile()
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

    /// Opens (creating once) the private Saved Messages room straight from the menu.
    private func openSavedMessages() async {
        let model = root.makeNewChat { room in router.openRoom(room) }
        await model.openSavedMessages()
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
                    newChat = root.makeNewChat { room in
                        newChat = nil
                        router.openRoom(room)
                    }
                } label: {
                    Label("New chat", systemImage: "square.and.pencil")
                }
                .accessibilityIdentifier("compose-chat")
                .keyboardShortcut("n", modifiers: .command)
                Button {
                    Task { await openSavedMessages() }
                } label: {
                    Label("Saved Messages", systemImage: "bookmark")
                }
                .accessibilityIdentifier("savedMessages")
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
                openRoomInfo: { router.openRoomInfo(room) },
                openThread: { router.openThread(room: room, rootEvent: $0) }
            )
        case .roomInfo(let room):
            RoomDetailsScreen(
                root: root,
                room: room,
                openRoom: { router.openRoom($0) },
                onLeft: { router.removeRoom(room) }
            )
        case .thread(let room, let rootEvent):
            ThreadScreen(root: root, room: room, rootEvent: rootEvent)
        case .settings:
            SettingsView(config: root.makeSettingsConfiguration(onOpenStickers: {
                router.push(.stickerLibrary)
            }))
        case .stickerLibrary:
            StickerLibraryView(model: root.makeStickerLibrary())
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
    @State private var klipyGIFs: KlipyPanelModel?
    @State private var klipyStickers: KlipyPanelModel?
    @State private var details: RoomDetailsViewModel?
    @State private var stickerToSave: PendingStickerSave?
    @State private var title = ""
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    private let root: AppRoot
    private let room: RoomID
    private let openRoom: @MainActor (RoomID) -> Void
    private let openRoomInfo: @MainActor () -> Void
    private let openThread: @MainActor (EventID) -> Void

    init(
        root: AppRoot,
        room: RoomID,
        jumpTo: EventID? = nil,
        openRoom: @escaping @MainActor (RoomID) -> Void,
        openRoomInfo: @escaping @MainActor () -> Void,
        openThread: @escaping @MainActor (EventID) -> Void
    ) {
        self.openRoom = openRoom
        self.openRoomInfo = openRoomInfo
        self.openThread = openThread
        self.root = root
        self.room = room
        let timeline = root.makeTimeline(room: room)
        timeline.initialEvent = jumpTo
        _model = State(initialValue: timeline)
        _stickers = State(initialValue: root.makeStickerPanel(room: room, timeline: timeline))
        _klipyGIFs = State(initialValue: root.makeKlipyPanel(.gifs, timeline: timeline))
        _klipyStickers = State(initialValue: root.makeKlipyPanel(.stickers, timeline: timeline))
    }

    /// The room's picture from the chat list (for a direct chat the other person's); `nil` shows the initial.
    private var roomAvatar: MediaRef? {
        guard case .loaded(_, let rows) = root.roomList.content else { return nil }
        return rows.first(where: { $0.id == room })?.avatar
    }

    /// On regular-width iPad, Room info docks as a trailing third column (M16 three-column layout, D91); on iPhone and
    /// compact Slide Over / Split View it pushes as a page on the navigation stack.
    private var usesInspector: Bool {
        RoomInfoPresentation.style(
            isPad: UIDevice.current.userInterfaceIdiom == .pad,
            regularWidth: horizontalSizeClass == .regular
        ) == .inspector
    }

    private func toggleRoomInfo() {
        if usesInspector {
            if details != nil {
                details = nil
            } else {
                details = root.makeRoomDetails(room: room)
            }
        } else {
            openRoomInfo()
        }
    }

    private func roomDetailsInspectorView(_ model: RoomDetailsViewModel) -> some View {
        NavigationStack {
            RoomDetailsView(
                model: model,
                profileSheet: { member, dismissProfile in
                    root.makeUserProfile(member: member, onOpenRoom: { room in
                        dismissProfile()
                        details = nil
                        openRoom(room)
                    }).map { AnyView(UserProfileView(model: $0)) }
                },
                onRenamed: { title = $0 },
                onLeft: { details = nil; dismiss() }
            )
        }
    }

    var body: some View {
        TimelineView(
            model: model,
            stickerPanel: { AnyView(StickerTabView(packs: stickers, klipy: klipyStickers)) },
            gifPanel: klipyGIFs.map { gifs -> @MainActor () -> AnyView in { AnyView(KlipyPanelView(model: gifs)) } },
            onOpenThread: openThread,
            onSaveAsSticker: { data, filename in
                stickerToSave = PendingStickerSave(data: data, filename: filename)
            },
            onFirstRows: {
                root.roomOpen?.end()
                root.roomOpen = nil
            }
        )
        .sheet(item: $stickerToSave) { pending in
            AddToStickerPackSheet(model: root.makeStickerLibrary(), imageData: pending.data, filename: pending.filename)
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { toggleRoomInfo() } label: {
                    AvatarView(name: title, ref: roomAvatar, size: 30, showsOuterFrame: false) { [roomList = root.roomList] in
                        await roomList.avatarData($0)
                    }
                    .frame(width: 44, height: 44)
                    .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .keyboardShortcut("i", modifiers: .command)
                .accessibilityLabel("Room info")
                .accessibilityIdentifier("roomInfo")
            }
            .sharedBackgroundVisibility(.hidden)
        }
        .modifier(RoomInfoInspector(
            enabled: UIDevice.current.userInterfaceIdiom == .pad,
            isPresented: Binding(
                get: { usesInspector && details != nil },
                set: { if !$0 { details = nil; Task { title = await root.roomName(room) ?? title } } }
            ),
            content: { if let model = details { roomDetailsInspectorView(model).inspectorColumnWidth(min: 300, ideal: 340, max: 420) } }
        ))
        .task { title = await root.roomName(room) ?? "Unnamed room" }
        .onAppear { Task { title = await root.roomName(room) ?? title } }
    }
}

/// Pushed Room info page on the single `NavigationStack`.
private struct RoomDetailsScreen: View {
    @State private var model: RoomDetailsViewModel
    private let root: AppRoot
    private let openRoom: @MainActor (RoomID) -> Void
    private let onLeft: @MainActor () -> Void

    init(
        root: AppRoot,
        room: RoomID,
        openRoom: @escaping @MainActor (RoomID) -> Void,
        onLeft: @escaping @MainActor () -> Void
    ) {
        self.root = root
        self.openRoom = openRoom
        self.onLeft = onLeft
        _model = State(initialValue: root.makeRoomDetails(room: room))
    }

    var body: some View {
        RoomDetailsView(
            model: model,
            profileSheet: { member, dismissProfile in
                root.makeUserProfile(member: member, onOpenRoom: { target in
                    dismissProfile()
                    openRoom(target)
                }).map { AnyView(UserProfileView(model: $0)) }
            },
            onLeft: onLeft
        )
    }
}

/// The signed-in user's last known name and photo, so the avatar button is drawn on the first frame after launch.
/// Stored in the app's shared store directory (same protection as the session store) and removed on sign-out.
private struct OwnProfileCache: Codable {
    var user: String?
    var name: String?
    var avatar: Data?

    private static var url: URL {
        HaloShared.storeDirectory().appendingPathComponent("halo", isDirectory: true).appendingPathComponent("own-profile.json")
    }

    static func load(user: String?) -> OwnProfileCache? {
        guard let user, let data = try? Data(contentsOf: url),
              let cached = try? JSONDecoder().decode(OwnProfileCache.self, from: data), cached.user == user else { return nil }
        return cached
    }

    static func save(_ cache: OwnProfileCache) {
        guard cache.user != nil, let data = try? JSONEncoder().encode(cache) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    static func clear() { try? FileManager.default.removeItem(at: url) }
}

/// Room info as an iPad inspector column (D91). On iPhone the modifier isn't applied at all: an `.inspector` in compact
/// width is itself a sheet presenter, and next to the room's real Room-info sheet it popped the room screen out of the
/// navigation stack without updating the router's path (founder: "tap room avatar, then auto exit"; the next tap crashed
/// with `AnyNavigationPath.Error.comparisonTypeMismatch`).
private struct RoomInfoInspector<Inspector: View>: ViewModifier {
    let enabled: Bool
    @Binding var isPresented: Bool
    @ViewBuilder let content: () -> Inspector

    func body(content base: Content) -> some View {
        if enabled {
            base.inspector(isPresented: $isPresented) { content() }
        } else {
            base
        }
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
        .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
    }
}

/// Receives the APNs device token and handles notification taps (PUSH_NOTIFICATIONS §2, NOTIFICATIONS §5).
final class PushDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    @MainActor static var coordinator: PushCoordinator?
    @MainActor static var onNotificationTap: (@MainActor (RoomID, EventID?) -> Void)?
    @MainActor static var onBackgroundPush: (@MainActor () async -> UIBackgroundFetchResult)?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in await Self.coordinator?.deviceTokenReceived(deviceToken) }
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        Task { @MainActor in
            let result = await Self.onBackgroundPush?() ?? .noData
            completionHandler(result)
        }
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

private struct PendingStickerSave: Identifiable {
    let id = UUID()
    let data: Data
    let filename: String
}

/// Keeps the global media gallery view model alive for the lifetime of the pushed preset room screen (D34, D83).
private struct GlobalMediaGalleryScreen: View {
    @State private var model: GlobalMediaGalleryViewModel
    @State private var stickerToSave: PendingStickerSave?
    private let root: AppRoot
    private let onJumpToMessage: @MainActor (RoomID, EventID) -> Void

    init(root: AppRoot, onJumpToMessage: @escaping @MainActor (RoomID, EventID) -> Void) {
        self.root = root
        _model = State(initialValue: root.makeGlobalMediaGallery())
        self.onJumpToMessage = onJumpToMessage
    }

    var body: some View {
        GlobalMediaGalleryView(
            model: model,
            onJumpToMessage: onJumpToMessage,
            onSaveAsSticker: { data, filename in
                stickerToSave = PendingStickerSave(data: data, filename: filename)
            }
        )
        .sheet(item: $stickerToSave) { pending in
            AddToStickerPackSheet(model: root.makeStickerLibrary(), imageData: pending.data, filename: pending.filename)
        }
    }
}
