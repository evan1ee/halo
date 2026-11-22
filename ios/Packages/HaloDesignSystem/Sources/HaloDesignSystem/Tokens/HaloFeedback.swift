import SwiftUI

/// App-level haptic events mapped to SwiftUI's native `.sensoryFeedback` (`docs/design/DESIGN_SYSTEM.md` §11).
///
/// System haptics settings (e.g. Sound & Haptics → System Haptics off) are respected automatically by SwiftUI.
public enum HaloFeedbackEvent: Sendable, Equatable {
    case send
    case reaction
    case swipeThreshold
    case success
    case failure

    public var sensoryFeedback: SensoryFeedback {
        switch self {
        case .send: .impact(weight: .light)
        case .reaction: .selection
        case .swipeThreshold: .impact(weight: .medium)
        case .success: .success
        case .failure: .error
        }
    }
}

public extension View {
    /// Triggers the semantic haptic for `event` whenever `trigger` changes.
    func haloFeedback<T: Equatable>(_ event: HaloFeedbackEvent, trigger: T) -> some View {
        sensoryFeedback(event.sensoryFeedback, trigger: trigger)
    }
}
