import Foundation
import HaloApplication
import HaloDomain
import HaloFoundation
import Observation

/// View model for message search across all rooms (M8 Search + Saved, V-SEARCH-1).
@MainActor @Observable
public final class MessageSearchViewModel: Identifiable {
    public let id = UUID()

    public struct ResultRow: Equatable, Identifiable, Sendable {
        public let id: String
        public let roomID: RoomID
        public let eventID: EventID
        public let roomName: String
        public let sender: String
        public let body: String
        public let timestamp: Date
    }

    public var query = ""
    public private(set) var rows: [ResultRow] = []
    public private(set) var isLoading = false
    public private(set) var hasMore = false
    public private(set) var errorMessage: String?

    private let coordinator: SearchCoordinator
    private let roomName: @MainActor (RoomID) -> String
    private var observation: Task<Void, Never>?

    public init(coordinator: SearchCoordinator, roomName: @escaping @MainActor (RoomID) -> String) {
        self.coordinator = coordinator
        self.roomName = roomName
    }

    isolated deinit { observation?.cancel() }

    public func start() async {
        guard observation == nil else { return }
        await coordinator.begin()
        let stream = await coordinator.snapshots()
        observation = Task { [weak self] in
            for await snap in stream {
                self?.apply(snap)
            }
        }
    }

    public func submit() async {
        await coordinator.search(query)
    }

    public func loadMore() async {
        await coordinator.loadMore()
    }

    public func clear() async {
        query = ""
        await coordinator.clear()
    }

    private func apply(_ snap: SearchCoordinator.Snapshot) {
        isLoading = snap.isLoading
        hasMore = snap.hasMore
        errorMessage = snap.error.map { error in
            error == .network(retryable: true) ? "Can't reach the server. Check your connection." : "Search couldn't complete."
        }
        rows = snap.hits.map { hit in
            ResultRow(
                id: hit.id,
                roomID: hit.roomID,
                eventID: hit.eventID,
                roomName: roomName(hit.roomID),
                sender: hit.senderName ?? hit.senderID,
                body: hit.body,
                timestamp: hit.timestamp)
        }
    }
}

#if canImport(SwiftUI)
import SwiftUI

/// Sheet for searching messages across rooms and jumping to a matching event (M8 Search + Saved).
public struct MessageSearchView: View {
    @Bindable private var model: MessageSearchViewModel
    private let onSelect: (RoomID, EventID) -> Void
    @Environment(\.dismiss) private var dismiss

    public init(model: MessageSearchViewModel, onSelect: @escaping (RoomID, EventID) -> Void) {
        self.model = model
        self.onSelect = onSelect
    }

    public var body: some View {
        NavigationStack {
            List {
                if let error = model.errorMessage {
                    Text(error).foregroundStyle(.red).font(.footnote)
                }
                ForEach(model.rows) { row in
                    Button {
                        onSelect(row.roomID, row.eventID)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(row.roomName).font(.caption.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
                                Spacer()
                                Text(ActivityTime.text(row.timestamp)).font(.caption2).foregroundStyle(.secondary)
                            }
                            Text(row.sender).font(.subheadline.weight(.medium)).lineLimit(1)
                            Text(row.body).font(.subheadline).foregroundStyle(.primary).lineLimit(2)
                        }
                        .padding(.vertical, 2)
                    }
                    .foregroundStyle(.primary)
                }
                if model.hasMore {
                    Button(model.isLoading ? "Loading…" : "Load more results") {
                        Task { await model.loadMore() }
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .disabled(model.isLoading)
                }
            }
            .overlay {
                if model.isLoading && model.rows.isEmpty {
                    ProgressView()
                } else if model.rows.isEmpty && !model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && model.errorMessage == nil {
                    ContentUnavailableView.search(text: model.query)
                } else if model.rows.isEmpty && model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ContentUnavailableView("Search messages", systemImage: "magnifyingglass", description: Text("Find messages across your rooms."))
                }
            }
            .navigationTitle("Search")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .searchable(text: $model.query, prompt: "Search messages")
            .onSubmit(of: .search) { Task { await model.submit() } }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await model.start() }
        }
    }
}
#endif
