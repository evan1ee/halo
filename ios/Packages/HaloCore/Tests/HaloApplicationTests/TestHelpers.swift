import Foundation
import HaloDomain
import HaloFoundation
import HaloTestSupport

/// The first element of `stream` satisfying `predicate`. No sleeps: tests wait on state streams
/// (AGENTS.md §12) and rely on the suite's time limit if a state never arrives.
func first<T: Sendable>(_ stream: AsyncStream<T>, where predicate: (T) -> Bool) async -> T? {
    for await value in stream where predicate(value) { return value }
    return nil
}

let devServer = ServerDetails(
    homeserverURL: URL(string: "https://halo.localhost")!,
    supportsPassword: true, supportsOIDC: false, supportsNativeSlidingSync: true
)

func makeSessionFixture() -> (FakeSessionPort, InMemoryKeychain) {
    let port = FakeSessionPort()
    port.addServer("halo.localhost", devServer)
    port.addAccount(.init(localpart: "alice", password: "correct horse"))
    return (port, InMemoryKeychain())
}

func room(_ n: Int) -> RoomSummary {
    RoomSummary(id: try! RoomID("!r\(n):halo.localhost"), name: "Room \(n)", isDirect: false, isEncrypted: true, membership: .joined)
}
