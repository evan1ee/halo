import Foundation
import HaloDomain
import HaloFoundation
import HaloTestSupport
import Testing
@testable import HaloApplication

@MainActor
@Suite("MatrixLinkCoordinator (NAVIGATION §3, M18-9)")
struct MatrixLinkCoordinatorTests {
    private struct Opened: Equatable { let room: RoomID; let event: EventID? }

    private final class Log { var opened: [Opened] = [] }

    private func make(signedIn: Bool = true, joined: Set<RoomID> = [], chats: FakeChatCreationPort = FakeChatCreationPort()) -> (MatrixLinkCoordinator, FakeChatCreationPort, Log) {
        let log = Log()
        let coordinator = MatrixLinkCoordinator(isSignedIn: { signedIn }, joinedRooms: { joined }, chats: chats)
        coordinator.open = { room, event in log.opened.append(Opened(room: room, event: event)) }
        return (coordinator, chats, log)
    }

    private func url(_ text: String) throws -> URL { try #require(URL(string: text)) }

    @Test("a link to a room you aren't in asks first: nothing is joined until you agree, and cancelling joins nothing")
    func joinAsks() async throws {
        let (links, chats, log) = make()
        #expect(await links.handle(try url("https://matrix.to/#/%23halo:example.org")))
        #expect(links.prompt == .join(address: "#halo:example.org", event: nil))
        #expect(chats.joinedAddresses.isEmpty && log.opened.isEmpty)
        links.cancel()
        #expect(links.prompt == nil && chats.joinedAddresses.isEmpty && log.opened.isEmpty)

        _ = await links.handle(try url("matrix:r/halo:example.org"))
        await links.confirm()
        #expect(chats.joinedAddresses == ["#halo:example.org"])
        #expect(log.opened.count == 1)
        #expect(links.failure == nil)
    }

    @Test("a room you are already in opens at once, at the message the link names")
    func joinedOpens() async throws {
        let room = try RoomID("!r:example.org")
        let (links, chats, log) = make(joined: [room])
        _ = await links.handle(try url("https://matrix.to/#/!r:example.org/$ev1"))
        #expect(links.prompt == nil && chats.joinedAddresses.isEmpty)
        #expect(log.opened == [Opened(room: room, event: try EventID("$ev1"))])
    }

    @Test("a link to a person asks before starting a chat, and starts none until you agree")
    func chatAsks() async throws {
        let (links, chats, log) = make()
        _ = await links.handle(try url("https://matrix.to/#/@bob:example.org"))
        #expect(links.prompt == .startChat(try UserID("@bob:example.org")))
        #expect(log.opened.isEmpty)
        #expect(chats.startedChats.isEmpty)
        links.cancel()
        #expect(chats.startedChats.isEmpty && log.opened.isEmpty)
        _ = await links.handle(try url("matrix:u/bob:example.org"))
        await links.confirm()
        #expect(chats.startedChats == [try UserID("@bob:example.org")])
        #expect(log.opened.count == 1 && log.opened[0].event == nil)
    }

    @Test("failures are said in plain words and never as a silent no-op (the room is gone, invite-only, offline)")
    func failuresSpeak() async throws {
        for (error, expected) in [
            (HaloError.notFound, "That room wasn't found."),
            (.forbidden, "You can't join that room. The room may be invite-only."),
            (.network(retryable: true), "Can't reach the server, so Halo couldn't join that room. Try again."),
        ] {
            let (links, chats, log) = make()
            chats.fail(with: error)
            _ = await links.handle(try url("https://matrix.to/#/!gone:example.org"))
            await links.confirm()
            #expect(links.failure == expected)
            #expect(log.opened.isEmpty)
            links.dismissFailure()
            #expect(links.failure == nil)
        }
        let (links, chats, _) = make()
        chats.fail(with: .notFound)
        _ = await links.handle(try url("https://matrix.to/#/@nobody:example.org"))
        await links.confirm()
        #expect(links.failure == "That person wasn't found.")
    }

    @Test("web links are left to the system; signed out, a Matrix link says to sign in")
    func others() async throws {
        let (links, _, _) = make()
        #expect(await links.handle(try url("https://example.org/page")) == false)
        #expect(links.prompt == nil && links.failure == nil)
        let (signedOut, chats, log) = make(signedIn: false)
        #expect(await signedOut.handle(try url("https://matrix.to/#/!r:example.org")))
        #expect(signedOut.prompt == nil && signedOut.failure == "Sign in to open Matrix links.")
        #expect(chats.joinedAddresses.isEmpty && log.opened.isEmpty)
    }
}
