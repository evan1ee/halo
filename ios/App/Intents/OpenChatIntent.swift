import AppIntents
import HaloApplication
import HaloDomain
import HaloFoundation
import HaloPlatform

/// A chat Siri and Shortcuts can name (M16, D88). The set is what `ChatShortcutPublisher` stored while "Chats in Siri and
/// Spotlight" is on; with it off the list is empty and Siri finds nothing.
struct ChatEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Chat")
    static let defaultQuery = ChatEntityQuery()

    let id: String
    let name: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct ChatEntityQuery: EntityStringQuery {
    private var all: [ChatEntity] {
        SystemChatShortcutStore(file: SystemChatShortcutStore.defaultFile()).load().map { ChatEntity(id: $0.id, name: $0.name) }
    }

    func entities(for identifiers: [String]) async throws -> [ChatEntity] { all.filter { identifiers.contains($0.id) } }
    func entities(matching string: String) async throws -> [ChatEntity] { all.filter { $0.name.localizedCaseInsensitiveContains(string) } }
    func suggestedEntities() async throws -> [ChatEntity] { Array(all.prefix(10)) }
}

/// "Open <chat> in Halo". The intent only asks the app to open the chat; the room list and the router do the rest.
struct OpenChatIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Chat"
    static let description = IntentDescription("Opens a chat in Halo.")
    static let openAppWhenRun = true

    @Parameter(title: "Chat") var chat: ChatEntity

    @Dependency private var requests: OpenChatRequestBox

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let room = try? RoomID(chat.id) else { return .result() }
        requests.value.request(room)
        return .result()
    }
}

/// `AppDependencyManager` needs a class it can hold; wraps the app's one `OpenChatRequest`.
final class OpenChatRequestBox: @unchecked Sendable {  // holds a @MainActor object reference, only used on the main actor
    let value: OpenChatRequest
    init(_ value: OpenChatRequest) { self.value = value }
}

struct HaloShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: OpenChatIntent(), phrases: ["Open \(\.$chat) in \(.applicationName)"], shortTitle: "Open Chat", systemImageName: "bubble.left")
        AppShortcut(
            intent: SendMessageIntent(),
            phrases: [
                "Send a message to \(\.$chat) in \(.applicationName)",
                "Message \(\.$chat) in \(.applicationName)",
            ],
            shortTitle: "Send Message",
            systemImageName: "paperplane"
        )
    }
}
