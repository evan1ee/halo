import FeatureAuth
import FeatureRoomList
import FeatureTimeline
import HaloApplication
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

    var body: some View {
        Group {
            switch root.auth.screen {
            case .signedIn:
                NavigationStack(path: $path) {
                    VStack(spacing: 0) {
                        RecoveryBanner(model: root.recovery)
                        RoomListView(model: root.roomList) { path.append($0) }
                        Button("Sign out") { Task { await root.auth.signOut() } }.padding()
                    }
                    .navigationDestination(for: RoomID.self) { room in
                        TimelineScreen(model: root.makeTimeline(room: room))
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
    @State var model: TimelineViewModel
    var body: some View { TimelineView(model: model).navigationBarTitleDisplayMode(.inline) }
}

/// Receives the APNs device token and hands it to the push coordinator (PUSH_NOTIFICATIONS §2).
final class PushDelegate: NSObject, UIApplicationDelegate {
    @MainActor static var coordinator: PushCoordinator?

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in await Self.coordinator?.deviceTokenReceived(deviceToken) }
    }
}
