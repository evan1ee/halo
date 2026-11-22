import Foundation
import HaloDomain

/// Follows a room timeline to see whether items just sent have reached the server (M16, D92). The share extension must not
/// close before they have: iOS may stop the process, and an unconfirmed upload would wait for the app. Pure; fed with the
/// timeline's diffs.
///
/// The first diff is the baseline: echoes already there (earlier unsent messages) are ignored. After that, every own event
/// seen unsent is an echo of ours; it is confirmed when the same item shows `.sent`, and failed when it shows `.failed`.
public struct SendConfirmation: Sendable {
    public enum State: Sendable, Equatable { case waiting, confirmed, failed }

    private var items: [TimelineItem] = []
    private var baseline: Set<TimelineItemID> = []
    private var started = false
    private var echoes: Set<TimelineItemID> = []
    private var confirmed: Set<TimelineItemID> = []
    private var failedEcho = false
    private let expected: Int

    /// `expected`: how many messages the caller sent.
    public init(expected: Int) { self.expected = expected }

    public mutating func apply(_ diff: TimelineDiff) {
        guard (try? ListReducer.apply(diff, to: &items)) != nil else { return }
        if !started {
            started = true
            baseline = Set(items.compactMap { Self.isUnsent($0) ? $0.id : nil })
        }
        for item in items {
            guard case .event(let event) = item.content, event.isOwn, !baseline.contains(item.id) else { continue }
            switch event.sendState {
            case .sending: echoes.insert(item.id)
            case .failed:
                echoes.insert(item.id)
                failedEcho = true
            case .sent:
                if echoes.contains(item.id) { confirmed.insert(item.id) }
            }
        }
    }

    public var state: State {
        if failedEcho { return .failed }
        return confirmed.count >= expected ? .confirmed : .waiting
    }

    private static func isUnsent(_ item: TimelineItem) -> Bool {
        if case .event(let event) = item.content, event.isOwn, event.sendState != .sent { return true }
        return false
    }
}
