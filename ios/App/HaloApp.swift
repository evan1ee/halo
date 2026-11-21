import FeatureAuth
import FeatureRoomDetails
import FeatureRoomList
import FeatureSettings
import FeatureStickers
import FeatureTimeline
import HaloApplication
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
    @AppStorage(AppPreferences.appearanceKey) private var appearance = Appearance.system.rawValue

    private var colorScheme: ColorScheme? {
        switch Appearance(rawValue: appearance) ?? .system {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    var body: some View {
        Group {
            switch root.auth.screen {
            case .signedIn:
                NavigationStack(path: $path) {
                    VStack(spacing: 0) {
                        RecoveryBanner(model: root.recovery)
                        RoomListView(model: root.roomList, onRoomInfo: { roomInfo = root.makeRoomDetails(room: $0) }) { path.append($0) }
                    }
                    .navigationTitle("Halo")
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
                            } label: { Image(systemName: "gearshape") }
                                .accessibilityLabel("Settings")
                                .accessibilityIdentifier("settings")
                        }
                    }
                    .sheet(item: $newChat) { NewChatView(model: $0) }
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
                        TimelineScreen(root: root, room: room, openRoom: { path.append($0) })
                    }
                }
            default:
                SignInView(model: root.auth)
            }
        }
        .task {
            PushDelegate.coordinator = root.push
            await root.push?.begin()
            await root.badge.begin()
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
            await root.sync.setForeground(scenePhase == .active)
            await root.badge.setForeground(scenePhase == .active)
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

    init(root: AppRoot, room: RoomID, openRoom: @escaping @MainActor (RoomID) -> Void) {
        self.openRoom = openRoom
        self.root = root
        self.room = room
        let timeline = root.makeTimeline(room: room)
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
