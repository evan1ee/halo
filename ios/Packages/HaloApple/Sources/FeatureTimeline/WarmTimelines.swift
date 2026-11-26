import Foundation
import HaloFoundation

/// Timeline view models started before their screen is pushed (M19-9, D-MOT-2): the top rooms of the chat list keep one each,
/// so opening one of them draws its rows on the first frame instead of an empty message area.
///
/// A model here was started with `startAhead()` and reports nothing about what was read until its screen calls `present()`;
/// it leaves this cache then. At most `limit` exist. A room on screen is never prepared again behind it; a room that leaves the
/// top, or a screen that closed without using its model (it was opened at a message), loses its model, and everything goes on
/// sign-out and under memory pressure (`dropAll`).
@MainActor
public final class WarmTimelines {
    public static let defaultLimit = 3

    private let limit: Int
    private let refillDelay: Duration
    private let make: @MainActor (RoomID) -> TimelineViewModel
    private var models: [RoomID: TimelineViewModel] = [:]
    private var top: [RoomID] = []
    private var onScreen: Set<RoomID> = []
    private var refill: Task<Void, Never>?

    /// - Parameters:
    ///   - refillDelay: how long to wait before starting new models, so a room isn't prepared while a screen animates.
    ///   - make: builds a (not started) view model for a room, as the room screen would.
    public init(limit: Int = WarmTimelines.defaultLimit, refillDelay: Duration = .milliseconds(600), make: @escaping @MainActor (RoomID) -> TimelineViewModel) {
        self.limit = limit
        self.refillDelay = refillDelay
        self.make = make
    }

    isolated deinit { refill?.cancel() }

    /// The rooms at the top of the chat list, in order.
    public func setTop(_ rooms: [RoomID]) {
        top = rooms
        update()
    }

    /// The rooms whose screens are on the navigation stack now.
    public func screensChanged(_ rooms: Set<RoomID>) {
        // A screen that closed without taking its model (it was opened at a message, with a model of its own) leaves this one
        // with a draft and a read position from before: it is replaced.
        for room in onScreen.subtracting(rooms) { drop(room) }
        onScreen = rooms
        update()
    }

    /// The started model for `room`, if one is waiting. It stays here until its screen presents it, so a screen built twice by
    /// SwiftUI gets the same model both times.
    public func take(_ room: RoomID) -> TimelineViewModel? {
        guard let model = models[room], !model.isPresented else { return nil }
        return model
    }

    /// Lets go of every model (sign-out, memory pressure). New ones are made at the next change of the top or of the screens.
    public func dropAll() {
        refill?.cancel()
        refill = nil
        for room in Array(models.keys) { drop(room) }
    }

    /// The rooms that have a waiting model (tests).
    var waitingRooms: Set<RoomID> { Set(models.keys) }

    private var wanted: [RoomID] {
        Array(top.filter { !onScreen.contains($0) }.prefix(limit))
    }

    private func update() {
        let wanted = Set(self.wanted)
        // A model whose screen is being pushed stays until it is presented.
        for room in Array(models.keys) where !wanted.contains(room) && !onScreen.contains(room) { drop(room) }
        guard self.wanted.contains(where: { models[$0] == nil }) else { return }
        refill?.cancel()
        refill = Task { [weak self, refillDelay] in
            if refillDelay > .zero {
                try? await Task.sleep(for: refillDelay)  // best-effort: a cancelled wait only means a newer refill runs
            }
            guard !Task.isCancelled else { return }
            await self?.startMissing()
        }
    }

    private func startMissing() async {
        for room in wanted where models[room] == nil {
            guard !Task.isCancelled else { return }
            // One at a time: each opens an SDK timeline and maps its first rows on the main actor.
            await start(install(room), room)
        }
    }

    private func install(_ room: RoomID) -> TimelineViewModel {
        let model = make(room)
        // Held back from the moment it is handed out, not only once its start runs: a screen may take it before that.
        model.isPresented = false
        model.onPresented = { [weak self, weak model] in
            guard let self, let model, self.models[room] === model else { return }
            self.models[room] = nil
        }
        models[room] = model
        return model
    }

    private func start(_ model: TimelineViewModel, _ room: RoomID) async {
        await model.startAhead()
        // Let go of while it was starting: `drop` couldn't close what wasn't open yet.
        if models[room] !== model, !model.isPresented { await model.stop() }
    }

    private func drop(_ room: RoomID) {
        guard let model = models.removeValue(forKey: room) else { return }
        model.onPresented = nil
        guard !model.isPresented else { return }  // shown already: its screen owns it now
        Task { await model.stop() }
    }
}
