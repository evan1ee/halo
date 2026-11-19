#if canImport(SwiftUI)
import SwiftUI

public struct RoomListView: View {
    private let model: RoomListViewModel

    public init(model: RoomListViewModel) { self.model = model }

    public var body: some View {
        Group {
            switch model.content {
            case .idle, .loading:
                ProgressView()
            case .loaded(let count, let names):
                List {
                    Section("Rooms: \(count)") {
                        ForEach(Array(names.enumerated()), id: \.offset) { Text($0.element) }
                    }
                }
                .accessibilityIdentifier("room-list")
            case .failed(let message):
                Text(message).foregroundStyle(.red)
            }
        }
        .task { await model.start() }
    }
}
#endif
