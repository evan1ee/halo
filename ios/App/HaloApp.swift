import SwiftUI

/// Composition root of the app (AGENTS.md §5: wiring only). Screens arrive as Feature packages.
@main
struct HaloApp: App {
    var body: some Scene {
        WindowGroup {
            Text("Halo")
        }
    }
}
