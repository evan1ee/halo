#if canImport(SwiftUI)
import HaloDomain
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
                            Button { onSelect(row.id) } label: {
                                HStack {
                                    Text(row.name).fontWeight(row.hasUnread ? .bold : .regular)
                                    Spacer()
                                    indicator(row.display)
                                }
                            }
                            .foregroundStyle(.primary)
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

    @ViewBuilder private func indicator(_ display: DisplayCount) -> some View {
        switch display {
        case .none: EmptyView()
        case .dot: Circle().fill(.blue).frame(width: 10, height: 10).accessibilityLabel("Unread")
        case .count(let n): Text("\(n)").font(.caption.bold()).padding(.horizontal, 7).background(.blue, in: Capsule()).foregroundStyle(.white)
        case .mentions(let n): Text("@\(n)").font(.caption.bold()).padding(.horizontal, 7).background(.red, in: Capsule()).foregroundStyle(.white)
        }
    }
}
#endif
