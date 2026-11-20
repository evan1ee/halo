import Foundation
import HaloDomain
import HaloFoundation
import Observation

/// Another person's profile (USER_PROFILES FR-2, FR-3): name, user ID, message, ignore, copy ID.
@MainActor @Observable
public final class UserProfileViewModel: Identifiable {
    public enum Content: Equatable {
        case loading
        case loaded(UserProfile, isIgnored: Bool)
        case failed(String)
    }

    public private(set) var content: Content = .loading
    public private(set) var actionError: String?
    public private(set) var isWorking = false
    /// `true` for the signed-in user: no message or ignore actions.
    public let isMe: Bool
    public let userID: UserID

    private let profiles: any ProfilePort
    private let chats: any ChatCreationPort
    private let fallbackName: String?
    private let onOpenRoom: @MainActor (RoomID) -> Void

    public init(
        profiles: any ProfilePort, chats: any ChatCreationPort, user: UserID, roomDisplayName: String?, isMe: Bool,
        onOpenRoom: @escaping @MainActor (RoomID) -> Void
    ) {
        self.profiles = profiles
        self.chats = chats
        self.userID = user
        self.fallbackName = roomDisplayName
        self.isMe = isMe
        self.onOpenRoom = onOpenRoom
    }

    /// Loads the profile and whether the user is ignored. A profile that can't be fetched still shows the name known from the room.
    public func load() async {
        let ignored = (try? await profiles.ignoredUsers())?.contains(userID) ?? false
        do throws(HaloError) {
            content = .loaded(try await profiles.profile(of: userID), isIgnored: ignored)
        } catch {
            if let fallbackName { content = .loaded(UserProfile(userID: userID, displayName: fallbackName), isIgnored: ignored) } else { content = .failed(Self.text(error)) }
        }
    }

    public func toggleIgnore() async {
        guard case .loaded(let profile, let ignored) = content, !isMe, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do throws(HaloError) {
            if ignored { try await profiles.unignore(userID) } else { try await profiles.ignore(userID) }
            content = .loaded(profile, isIgnored: !ignored)
            actionError = nil
        } catch { actionError = Self.text(error) }
    }

    public func message() async {
        guard !isMe, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do throws(HaloError) {
            let room = try await chats.startDirectChat(with: userID)
            actionError = nil
            onOpenRoom(room)
        } catch { actionError = Self.text(error) }
    }

    private static func text(_ error: HaloError) -> String {
        switch error {
        case .network: "You appear to be offline. Try again."
        case .notFound: "This profile couldn't be found."
        default: "That didn't work. Try again."
        }
    }
}
