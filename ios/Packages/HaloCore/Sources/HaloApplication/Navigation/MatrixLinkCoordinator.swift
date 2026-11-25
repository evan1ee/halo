import Foundation
import HaloDomain
import HaloFoundation
import Observation

/// Opens `matrix.to` links and `matrix:` URIs, from a tap in a message or from outside the app (docs/design/NAVIGATION.md §3).
/// A link never joins a room or starts a chat by itself: it first asks, and says plainly when it fails (AGENTS §4.4, M18-9).
@MainActor @Observable
public final class MatrixLinkCoordinator {
    /// What the person is asked before anything happens.
    public enum Prompt: Equatable, Identifiable, Sendable {
        /// Join the room `address` (a room ID or an alias); `event` is shown once it is joined.
        case join(address: String, event: EventID?)
        /// Start a direct chat with `user` (an existing chat is opened, a new one invites them).
        case startChat(UserID)

        public var id: String {
            switch self {
            case .join(let address, let event): "join:\(address):\(event?.rawValue ?? "")"
            case .startChat(let user): "chat:\(user.rawValue)"
            }
        }
    }

    public private(set) var prompt: Prompt?
    public private(set) var isWorking = false
    /// Why the last link couldn't be opened, in words for the person; cleared by `dismissFailure`.
    public private(set) var failure: String?

    private let isSignedIn: @MainActor () -> Bool
    private let joinedRooms: @MainActor () async -> Set<RoomID>
    private let chats: any ChatCreationPort
    /// Shows `room`, at `event` when there is one.
    public var open: @MainActor (RoomID, EventID?) -> Void = { _, _ in }

    public init(
        isSignedIn: @escaping @MainActor () -> Bool,
        joinedRooms: @escaping @MainActor () async -> Set<RoomID>,
        chats: any ChatCreationPort
    ) {
        self.isSignedIn = isSignedIn
        self.joinedRooms = joinedRooms
        self.chats = chats
    }

    /// Handles `url` when it is a Matrix link; `false` leaves it to the system (a web link). A room the person is already in
    /// opens at once, since nothing changes by opening it; anything else asks first.
    @discardableResult
    public func handle(_ url: URL) async -> Bool {
        guard let link = MatrixLink.parse(url) else { return false }
        guard isSignedIn() else {
            failure = "Sign in to open Matrix links."
            return true
        }
        failure = nil
        switch link {
        case .room(let id, let event):
            if await joinedRooms().contains(id) { open(id, event) } else { prompt = .join(address: id.rawValue, event: event) }
        case .roomAlias(let alias, let event):
            prompt = .join(address: alias, event: event)
        case .user(let user):
            prompt = .startChat(user)
        }
        return true
    }

    /// The person agreed: do what the prompt said.
    public func confirm() async {
        guard let asked = prompt, !isWorking else { return }
        prompt = nil
        isWorking = true
        defer { isWorking = false }
        do {
            switch asked {
            case .join(let address, let event):
                open(try await chats.joinRoom(address), event)
            case .startChat(let user):
                open(try await chats.startDirectChat(with: user), nil)
            }
        } catch {
            failure = Self.text(for: error, asked)
        }
    }

    /// The person said no: nothing happens.
    public func cancel() { prompt = nil }

    public func dismissFailure() { failure = nil }

    static func text(for error: HaloError, _ asked: Prompt) -> String {
        let what: String = if case .startChat = asked { "start that chat" } else { "join that room" }
        return switch error {
        case .notFound: "That \(what == "join that room" ? "room" : "person") wasn't found."
        case .forbidden: "You can't \(what). The room may be invite-only."
        case .network: "Can't reach the server, so Halo couldn't \(what). Try again."
        case .unauthorized: "Sign in again to \(what)."
        default: "Halo couldn't \(what)."
        }
    }
}
