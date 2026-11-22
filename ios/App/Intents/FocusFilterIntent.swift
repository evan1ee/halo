import AppIntents
import HaloApplication
import HaloDomain

/// Which chats a Focus lets Halo show (M16, D90).
enum FocusChatsOption: String, AppEnum {
    case people, rooms, favourites, unread

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Chats")
    static let caseDisplayRepresentations: [FocusChatsOption: DisplayRepresentation] = [
        .people: "People", .rooms: "Rooms", .favourites: "Favourites", .unread: "Unread",
    ]

    var domain: FocusChats {
        switch self {
        case .people: .people
        case .rooms: .rooms
        case .favourites: .favourites
        case .unread: .unread
        }
    }
}

/// Settings → Focus → Halo: "Show only People / Rooms / Favourites / Unread" while the Focus is on. It narrows Halo's chat
/// list only; which notifications arrive stays with the Focus itself.
struct HaloFocusFilter: SetFocusFilterIntent {
    static let title: LocalizedStringResource = "Set Chats Shown"
    static let description = IntentDescription("Choose which chats Halo shows while this Focus is on.")

    @Parameter(title: "Show only", default: .people) var chats: FocusChatsOption

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "Show \(chats.rawValue) only") }

    @Dependency private var state: FocusFilterStateBox

    @MainActor
    func perform() async throws -> some IntentResult {
        state.value.chats = chats.domain
        return .result()
    }
}

/// `AppDependencyManager` needs a class it can hold; wraps the app's one `FocusFilterState`.
final class FocusFilterStateBox: @unchecked Sendable {  // holds a @MainActor object reference, only used on the main actor
    let value: FocusFilterState
    init(_ value: FocusFilterState) { self.value = value }
}
