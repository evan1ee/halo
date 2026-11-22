import Foundation
import HaloApplication
import HaloDomain
import HaloFoundation
import HaloTestSupport
import Testing

@Suite("SiriSendCoordinator")
struct SiriSendCoordinatorTests {
    private func storedSession() throws -> StoredSession {
        StoredSession(
            userID: try UserID("@alice:x.org"),
            deviceID: try DeviceID("DEV1"),
            payload: Data("session".utf8)
        )
    }

    @Test("rejects blank messages without touching the session or timeline")
    func rejectsBlank() async throws {
        let session = SessionCoordinator(port: FakeSessionPort(), keychain: InMemoryKeychain())
        let timelines = FakeTimelinePort()
        let coordinator = SiriSendCoordinator(session: session, timelines: timelines, confirmLimit: .milliseconds(50))
        let room = try RoomID("!room:x.org")

        await #expect(throws: HaloError.invalidInput("SIRI_EMPTY_MESSAGE")) {
            _ = try await coordinator.send(text: "  \n\t ", to: room)
        }
    }

    @Test("fails with unauthorized when signed out")
    func failsWhenSignedOut() async throws {
        let session = SessionCoordinator(port: FakeSessionPort(), keychain: InMemoryKeychain())
        let timelines = FakeTimelinePort()
        let coordinator = SiriSendCoordinator(session: session, timelines: timelines, confirmLimit: .milliseconds(50))
        let room = try RoomID("!room:x.org")

        await #expect(throws: HaloError.unauthorized(soft: false)) {
            _ = try await coordinator.send(text: "On my way", to: room)
        }
    }

    @Test("restores a stored session, trims and sends the message, and reports confirmed")
    func restoresAndConfirms() async throws {
        let keychain = InMemoryKeychain()
        try await keychain.write(try JSONEncoder().encode(storedSession()), for: .session)
        let session = SessionCoordinator(port: FakeSessionPort(), keychain: keychain)

        let room = try RoomID("!room:x.org")
        let timelines = FakeTimelinePort()
        timelines.addRoom(room)
        let coordinator = SiriSendCoordinator(session: session, timelines: timelines, confirmLimit: .seconds(2))

        let outcome = try await coordinator.send(text: "  On my way!  ", to: room)
        #expect(outcome == .confirmed)
        #expect(timelines.sentTexts(in: room) == ["On my way!"])
    }

    @Test("propagates room notFound when the chat no longer exists")
    func unknownRoomFails() async throws {
        let keychain = InMemoryKeychain()
        try await keychain.write(try JSONEncoder().encode(storedSession()), for: .session)
        let session = SessionCoordinator(port: FakeSessionPort(), keychain: keychain)

        let room = try RoomID("!missing:x.org")
        let timelines = FakeTimelinePort()
        let coordinator = SiriSendCoordinator(session: session, timelines: timelines, confirmLimit: .milliseconds(50))

        await #expect(throws: HaloError.notFound) {
            _ = try await coordinator.send(text: "Hello?", to: room)
        }
    }
}
