import FeatureAuth
import FeatureRoomList
import FeatureTimeline
import HaloFoundation
import SwiftUI

/// Composition root of the app (AGENTS.md §5: wiring only). Screens live in the Feature packages.
@main
struct HaloApp: App {
    @State private var root = AppRoot()

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
            await root.sync.begin()
            await root.recovery.start()  // before the banner exists: a hidden banner view runs no task
            await root.auth.start()
        }
        // Sync runs only in the foreground (SYNC_ENGINE §2 rule 1).
        .task(id: scenePhase) { await root.sync.setForeground(scenePhase == .active) }
    }
}

/// Keeps the view model alive for the lifetime of the pushed screen.
private struct TimelineScreen: View {
    @State var model: TimelineViewModel
    var body: some View { TimelineView(model: model).navigationBarTitleDisplayMode(.inline) }
}
