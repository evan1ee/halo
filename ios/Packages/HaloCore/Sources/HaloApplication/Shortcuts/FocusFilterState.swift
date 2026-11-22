import HaloDomain
import Observation

/// The chats the active Focus allows (M16, D90). The Focus filter intent sets it; the app reads the system's current
/// filter when it becomes active, so a missed change corrects itself. The root view hands it to the room list.
@MainActor @Observable
public final class FocusFilterState {
    public var chats: FocusChats?
    public init(chats: FocusChats? = nil) { self.chats = chats }
}
