import FeatureAuth
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
                        RoomListView(model: root.roomList) { path.append($0) }
                    }
                    .navigationTitle("Halo")
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            // Destination-based: the stack's path is typed to `RoomID`, so a value link of another type can't push.
                            NavigationLink {
                                SettingsView(
                                    version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?",
                                    build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?",
                                    onPrivateReceiptsChange: { value in Task { await root.receipts.setPrivateReceipts(value) } },
                                    loadMediaPreviews: { await root.mediaPreviewChoice() },
                                    saveMediaPreviews: { await root.setMediaPreviewChoice($0) },
                                    diagnostics: { await root.diagnosticsReport() },
                                    storageSizes: { await root.storageSizes() },
                                    onSignOut: { Task { await root.auth.signOut() } })
                            } label: { Image(systemName: "gearshape") }
                                .accessibilityLabel("Settings")
                                .accessibilityIdentifier("settings")
                        }
                    }
                    .navigationDestination(for: RoomID.self) { room in
                        TimelineScreen(root: root, room: room)
                    }
                }
            case .softLoggedOut:
                Text("Your session expired. Sign in again.")  // re-authentication arrives in M1
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
        // Sync runs only in the foreground (SYNC_ENGINE §2 rule 1).
        .task(id: scenePhase) {
            await root.sync.setForeground(scenePhase == .active)
            if scenePhase != .active { await root.receipts.flush() }
        }
    }
}

/// Keeps the view model alive for the lifetime of the pushed screen.
private struct TimelineScreen: View {
    @State private var model: TimelineViewModel
    @State private var stickers: StickerPanelViewModel

    init(root: AppRoot, room: RoomID) {
        let timeline = root.makeTimeline(room: room)
        _model = State(initialValue: timeline)
        _stickers = State(initialValue: root.makeStickerPanel(room: room, timeline: timeline))
    }

    var body: some View {
        TimelineView(model: model, stickerPanel: { AnyView(StickerPanelView(model: stickers)) }).navigationBarTitleDisplayMode(.inline)
    }
}

/// Receives the APNs device token and hands it to the push coordinator (PUSH_NOTIFICATIONS §2).
final class PushDelegate: NSObject, UIApplicationDelegate {
    @MainActor static var coordinator: PushCoordinator?

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in await Self.coordinator?.deviceTokenReceived(deviceToken) }
    }
}
