#if canImport(SwiftUI)
import HaloFoundation
import SwiftUI

public struct RoomListView: View {
    private let model: RoomListViewModel
    private let onSelect: (RoomID) -> Void

    /// `onSelect` is called when a room is tapped; navigation itself belongs to the composition root.
    public init(model: RoomListViewModel, onSelect: @escaping (RoomID) -> Void = { _ in }) {
        self.model = model
        self.onSelect = onSelect
    }

    public var body: some View {
        Group {
            switch model.content {
            case .idle, .loading:
                ProgressView()
            case .loaded(let count, let rows):
                List {
                    Section("Rooms: \(count)") {
                        ForEach(rows) { row in
                            Button(row.name) { onSelect(row.id) }.foregroundStyle(.primary)
                                .swipeActions(edge: .leading) {
                                    Button("Read") { Task { await model.markRead(row.id) } }.tint(.blue)
                                }
                                .swipeActions(edge: .trailing) {
                                    Button("Unread") { Task { await model.markUnread(row.id) } }.tint(.orange)
                                }
                        }
                    }
                }
                .accessibilityIdentifier("room-list")
                .safeAreaInset(edge: .bottom) {
                    if let message = model.actionError { Text(message).font(.footnote).foregroundStyle(.red).padding() }
                }
            case .failed(let message):
                Text(message).foregroundStyle(.red)
            }
        }
        .task { await model.start() }
    }
}
#endif
