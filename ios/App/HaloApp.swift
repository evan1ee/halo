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

private struct RootView: View {
    let root: AppRoot
    @Environment(\.scenePhase) private var scenePhase
    @State private var path: [RoomID] = []
    @State private var newChat: NewChatViewModel?
    @State private var roomInfo: RoomDetailsViewModel?
    @State private var activity: BotActivityViewModel?
    /// The message to scroll to in the room about to open (from Activity); consumed by that room's screen.
    @State private var pendingEvent: EventID?
    @State private var ownName = ""
    @State private var ownAvatar: Data?
    @AppStorage(AppPreferences.appearanceKey) private var appearance = Appearance.system.rawValue

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
                    VStack(spacing: 0) {
                        RoomListView(model: root.roomList, onRoomInfo: { roomInfo = root.makeRoomDetails(room: $0) }) { path.append($0) }
                    }
                    .navigationTitle("")
                    .navigationBarTitleDisplayMode(.inline)
                    .task { await refreshOwnProfile() }
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button {
                                newChat = root.makeNewChat { room in
                                    newChat = nil
                                    path.append(room)
                                }
                            } label: { Image(systemName: "square.and.pencil") }
                                .accessibilityLabel("New chat")
                                .accessibilityIdentifier("newChat")
                        }
                        if !AppPreferences().botSenders.isEmpty {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button { activity = root.makeBotActivity() } label: { Image(systemName: "checklist") }
                                    .accessibilityLabel("Activity")
                                    .accessibilityIdentifier("activity")
                            }
                        }
                        ToolbarItem(placement: .topBarTrailing) {
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
                                    reconcile: { await root.reconcileNow() },
                                    unexplainedAuditCount: { await root.unexplainedAuditCount() },
                                    storageSizes: { await root.storageSizes() },
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
                                    onSignOut: { Task { await root.auth.signOut() } })
                                .navigationBarTitleDisplayMode(.large)
                            } label: { AvatarCircle(name: ownName.isEmpty ? (root.signedInUserID ?? "?") : ownName, imageData: ownAvatar, size: 30)
                                .overlay(alignment: .topTrailing) {
                                    if root.recovery.needsRecovery {
                                        Circle().fill(.yellow).frame(width: 10, height: 10)
                                            .overlay(Circle().stroke(.background, lineWidth: 1.5))
                                            .accessibilityIdentifier("verify-dot")
                                    }
                                } }
                                .accessibilityLabel("Settings")
                                .accessibilityIdentifier("settings")
                        }
                    }
                    .onChange(of: root.roomList.content) { Task { await root.scanBotRooms() } }
                    .sheet(item: $newChat) { NewChatView(model: $0) }
                    .sheet(item: $activity) { model in
                        BotActivityView(model: model) { room, event in
                            activity = nil
                            pendingEvent = event
                            path.append(room)
                        }
                    }
                    .sheet(item: $roomInfo) {
                        RoomDetailsView(
                            model: $0,
                            profile: { member in
                                root.makeUserProfile(member: member) { target in
                                    roomInfo = nil
                                    path.append(target)
                                }
                            })
                    }
                    .navigationDestination(for: RoomID.self) { room in
                        TimelineScreen(root: root, room: room, jumpTo: pendingEvent, openRoom: { path.append($0) })
                            .onAppear { pendingEvent = nil }
                    }
                }
            default:
                SignInView(model: root.auth)
            }
        }
        .task {
            PushDelegate.coordinator = root.push
            await root.push?.begin()
            await root.readState.begin()
            Task { await root.followReadIntents() }
            await root.sync.begin()
            await root.recovery.start()  // before the banner exists: a hidden banner view runs no task
            await root.auth.start()
        }
        .preferredColorScheme(colorScheme)
        // Ask for notification permission once signed in; the token then arrives in `PushDelegate`.
        .task(id: root.auth.screen) {
            guard root.push != nil, case .signedIn = root.auth.screen else { return }
            if (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) == true {
                UIApplication.shared.registerForRemoteNotifications()
            }
        }
        // Sync and periodic read-state auditing run only in the foreground (SYNC_ENGINE §2 rule 1, LOGGING_AND_DIAGNOSTICS §2).
        .task(id: scenePhase) {
            await root.setForeground(scenePhase == .active)
            if scenePhase != .active { await root.receipts.flush() }
        }
    }
}

/// Keeps the view model alive for the lifetime of the pushed screen.
private struct TimelineScreen: View {
    @State private var model: TimelineViewModel
    @State private var stickers: StickerPanelViewModel
    @State private var details: RoomDetailsViewModel?
    @State private var title = ""
    @Environment(\.dismiss) private var dismiss
    private let root: AppRoot
    private let room: RoomID
    private let openRoom: @MainActor (RoomID) -> Void

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
        TimelineView(model: model, stickerPanel: { AnyView(StickerPanelView(model: stickers)) }).navigationBarTitleDisplayMode(.inline)
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
            .task { title = await root.roomName(room) ?? "Unnamed room" }
    }
}

/// Receives the APNs device token and hands it to the push coordinator (PUSH_NOTIFICATIONS §2).
final class PushDelegate: NSObject, UIApplicationDelegate {
    @MainActor static var coordinator: PushCoordinator?

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in await Self.coordinator?.deviceTokenReceived(deviceToken) }
    }
}
