#if canImport(SwiftUI)
import HaloDomain
import HaloFoundation
import SwiftUI

public struct RoomListView: View {
    @Bindable private var model: RoomListViewModel
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
                VStack(spacing: 0) {
                filterBar
                List {
                    Section("Rooms: \(count)") {
                        ForEach(rows) { row in
                            if row.isInvite {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(row.name).fontWeight(.bold)
                                    Text("Invitation").font(.caption).foregroundStyle(.secondary)
                                    HStack {
                                        Button("Accept") { Task { await model.acceptInvite(row.id) } }.buttonStyle(.borderedProminent)
                                        Button("Decline", role: .destructive) { Task { await model.declineInvite(row.id) } }.buttonStyle(.bordered)
                                    }
                                }
                                .accessibilityIdentifier("invite-\(row.name)")
                            } else {
                            Button { onSelect(row.id) } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    if row.isFavourite { Image(systemName: "star.fill").foregroundStyle(.yellow).imageScale(.small).accessibilityLabel("Favourite") }
                                    Text(row.name).fontWeight(row.hasUnread ? .bold : .regular)
                                    if row.isMuted { Image(systemName: "bell.slash").foregroundStyle(.secondary).imageScale(.small).accessibilityLabel("Muted") }
                                    Spacer()
                                    if let when = row.lastActivity { Text(Self.activityText(when)).font(.caption).foregroundStyle(.secondary) }
                                    indicator(row.display)
                                }
                                if let preview = row.preview {
                                    Text(preview).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                                        .accessibilityIdentifier("preview-\(row.name)")
                                }
                                }
                            }
                            .foregroundStyle(.primary)
                                .swipeActions(edge: .leading) {
                                    Button("Read") { Task { await model.markRead(row.id) } }.tint(.blue)
                                    Button(row.isFavourite ? "Unfavourite" : "Favourite") { Task { await model.toggleFavourite(row) } }.tint(.yellow)
                                }
                                .swipeActions(edge: .trailing) {
                                    Button("Unread") { Task { await model.markUnread(row.id) } }.tint(.orange)
                                    Button(row.isMuted ? "Unmute" : "Mute") { Task { await model.toggleMute(row) } }.tint(.gray)
                                }
                            }
                        }
                    }
                }
                .accessibilityIdentifier("room-list")
                .safeAreaInset(edge: .bottom) {
                    if let message = model.actionError { Text(message).font(.footnote).foregroundStyle(.red).padding() }
                }
                }
            case .failed(let message):
                Text(message).foregroundStyle(.red)
            }
        }
        .task { await model.start() }
    }

    private static let filters: [(RoomListFilter, String)] = [(.all, "All"), (.unread, "Unread"), (.people, "People"), (.rooms, "Rooms"), (.favourites, "Favourites"), (.invites, "Invites")]

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack {
                ForEach(Self.filters, id: \.1) { filter, title in
                    Button(title) { model.filter = filter }
                        .buttonStyle(.bordered)
                        .tint(model.filter == filter ? .accentColor : .secondary)
                        .accessibilityIdentifier("filter-\(title)")
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
        }
    }

    /// Today: the time; otherwise the date.
    private static func activityText(_ date: Date) -> String {
        Calendar.current.isDateInToday(date) ? date.formatted(date: .omitted, time: .shortened) : date.formatted(date: .abbreviated, time: .omitted)
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
