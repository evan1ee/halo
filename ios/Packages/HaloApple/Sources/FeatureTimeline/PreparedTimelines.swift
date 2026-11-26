import Foundation
import HaloFoundation

/// The timeline of a room chosen in the chat list, started before its screen is pushed (M19-9, D-MOT-2): the tap starts the
/// room's view model, the screen is pushed once that model has its rows (or after `openingWait`), and the screen's first frame
/// draws them instead of an empty message area.
///
/// At most one model waits here: the room being opened. It was started with `startAhead()` and reports nothing about what was
/// read until its screen calls `present()`; it leaves this holder then. A newer choice, a room that was never pushed (`abandon`),
/// sign-out and memory pressure (`dropAll`) let go of it. Nothing is started for rooms that weren't chosen: a room that isn't
/// open holds no view model (the adapter alone keeps the SDK timelines of the top rooms ready, `TimelinePort.warm`).
@MainActor
public final class PreparedTimelines {
    /// How long a tap waits for the chosen room's rows before its screen is pushed anyway. Opening from the device's store takes
    /// a few tens of ms when the main actor is free (MOTION_AUDIT); this bound keeps a slow open (no local events, a poor network)
    /// from delaying the push noticeably: the screen then shows its rows when they come, as before.
    public static let openingWait: Duration = .milliseconds(150)

    private let make: @MainActor (RoomID) -> TimelineViewModel
    private let wait: @Sendable (Duration) async -> Void
    private var waiting: (room: RoomID, model: TimelineViewModel)?
    private var onScreen: Set<RoomID> = []

    /// - Parameters:
    ///   - wait: sleeps for the given time (tests replace it); `prepare` waits no longer than its limit.
    ///   - make: builds a (not started) view model for a room, as the room screen would.
    public init(
        wait: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },  // a cancelled wait ends early, that's all
        make: @escaping @MainActor (RoomID) -> TimelineViewModel
    ) {
        self.wait = wait
        self.make = make
    }

    /// Starts the model of `room`, chosen in the chat list, and returns once a screen pushed now would draw its rows (or its
    /// failure) on the first frame, or after `limit`. The screen built next takes that model (`take`). A second `prepare`
    /// replaces the first; `abandon` lets go of one that was never pushed.
    public func prepare(_ room: RoomID, within limit: Duration = PreparedTimelines.openingWait) async {
        guard !onScreen.contains(room) else { return }  // already open: nothing is pushed
        let model: TimelineViewModel
        if let waiting, waiting.room == room {
            model = waiting.model
        } else {
            dropWaiting()
            model = make(room)
            // Held back from the moment it is handed out, not only once its start runs: a screen may take it before that.
            model.isPresented = false
            model.onPresented = { [weak self, weak model] in
                guard let self, let model, self.waiting?.model === model else { return }
                self.waiting = nil
            }
            waiting = (room, model)
            Task { await start(model) }
        }
        let wait = self.wait
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            let once = Once(done)
            model.whenShowable { once.resume() }
            Task { await wait(limit); once.resume() }
        }
    }

    /// The room `prepare` started was not pushed after all (another room was chosen meanwhile).
    public func abandon(_ room: RoomID) {
        guard waiting?.room == room, !onScreen.contains(room) else { return }
        dropWaiting()
    }

    /// The rooms whose screens are on the navigation stack now.
    public func screensChanged(_ rooms: Set<RoomID>) {
        // A screen that closed without showing the waiting model (it was opened at a message, with a model of its own) leaves
        // that model with a draft and a read position from before: it goes.
        if let room = waiting?.room, onScreen.contains(room), !rooms.contains(room) { dropWaiting() }
        onScreen = rooms
    }

    /// The started model for `room`, if one is waiting. It stays here until its screen presents it, so a screen built twice by
    /// SwiftUI gets the same model both times.
    public func take(_ room: RoomID) -> TimelineViewModel? {
        guard let waiting, waiting.room == room, !waiting.model.isPresented else { return nil }
        return waiting.model
    }

    /// Lets go of the waiting model (sign-out, memory pressure).
    public func dropAll() { dropWaiting() }

    /// The room whose model is waiting (tests).
    var waitingRoom: RoomID? { waiting?.room }

    private func start(_ model: TimelineViewModel) async {
        await model.startAhead()
        // Let go of while it was starting: `dropWaiting` couldn't close what wasn't open yet.
        if waiting?.model !== model, !model.isPresented { await model.stop() }
    }

    private func dropWaiting() {
        guard let model = waiting?.model else { return }
        waiting = nil
        model.onPresented = nil
        guard !model.isPresented else { return }  // shown already: its screen owns it now
        Task { await model.stop() }
    }

    /// Resumes a continuation the first time only (the rows and the time limit race).
    private final class Once {
        private var continuation: CheckedContinuation<Void, Never>?
        init(_ continuation: CheckedContinuation<Void, Never>) { self.continuation = continuation }
        func resume() {
            continuation?.resume()
            continuation = nil
        }
    }
}
