import Foundation
import HaloFoundation
@testable import HaloMatrixAdapter
import MatrixRustSDK
import Synchronization
import Testing

/// What a test must undo on the shared dev accounts (rooms, devices, account data). With the `.cleansUp` trait each test has
/// its own, run before the test ends, whether it passed or threw. Not `defer { Task { … } }`: nothing awaits that task, so the
/// process can end first and the rooms stay behind. `scripts/contract-test.sh` fails a run that left something.
final class Cleanup: Sendable {
    @TaskLocal static var current = Cleanup()

    private let steps = Mutex<[@Sendable () async -> Void]>([])

    /// Adds a step; the steps run last added first (a room is left before its device signs out).
    func add(_ step: @escaping @Sendable () async -> Void) { steps.withLock { $0.append(step) } }

    /// Leaves (or declines) and forgets `room` as the account of `client`. Straight to the server: the client only knows a room
    /// once a sync delivered it, which a failing test may not get to.
    func leave(_ room: String, as client: Client) {
        add {
            guard let session = try? client.session() else { return }
            await Self.leave(room, server: session.homeserverUrl, token: session.accessToken)
        }
    }

    func leave(_ room: String, server: String, token: String) {
        add { await Self.leave(room, server: server, token: token) }
    }

    func logout(server: String, token: String) {
        add { await Self.post("logout", server: server, token: token) }
    }

    private static func leave(_ room: String, server: String, token: String) async {
        let id = room.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? room
        await post("rooms/\(id)/leave", server: server, token: token)
        await post("rooms/\(id)/forget", server: server, token: token)
    }

    private static func post(_ path: String, server: String, token: String) async {
        let base = server.hasSuffix("/") ? server : server + "/"
        guard let url = URL(string: base + "_matrix/client/v3/" + path) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)
        _ = try? await URLSession.shared.data(for: request)
    }

    fileprivate func run() async {
        let pending = steps.withLock { all in
            defer { all = [] }
            return all
        }
        for step in pending.reversed() { await step() }
    }
}

struct CleansUp: SuiteTrait, TestTrait, TestScoping {
    var isRecursive: Bool { true }

    func provideScope(for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void) async throws {
        let cleanup = Cleanup()
        do {
            try await Cleanup.$current.withValue(cleanup) { try await function() }
        } catch {
            await cleanup.run()
            throw error
        }
        await cleanup.run()
    }
}

extension Trait where Self == CleansUp {
    static var cleansUp: Self { Self() }
}
