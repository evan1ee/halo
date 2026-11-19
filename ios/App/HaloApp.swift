import FeatureAuth
import FeatureRoomList
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

    var body: some View {
        Group {
            switch root.auth.screen {
            case .signedIn:
                VStack {
                    RoomListView(model: root.roomList)
                    Button("Sign out") { Task { await root.auth.signOut() } }.padding()
                }
            case .softLoggedOut:
                Text("Your session expired. Sign in again.")  // re-authentication arrives in M1
            default:
                SignInView(model: root.auth)
            }
        }
        .task { await root.auth.start() }
    }
}
