#if canImport(SwiftUI)
import HaloDesignSystem
import HaloDomain
import HaloFoundation
import SwiftUI

public struct RoomListView: View {
    @Bindable private var model: RoomListViewModel
    private let onSelect: (RoomID) -> Void
    private let onRoomInfo: ((RoomID) -> Void)?
    private let onMediaGallery: (() -> Void)?

    /// `onSelect` is called when a room is tapped; `onRoomInfo` opens the room info sheet from a row's context menu;
    /// `onMediaGallery` opens the preset non-Matrix Global Media Gallery entry (D83).
    /// Navigation itself belongs to the composition root.
    public init(
        model: RoomListViewModel,
        onRoomInfo: ((RoomID) -> Void)? = nil,
        onMediaGallery: (() -> Void)? = nil,
        onSelect: @escaping (RoomID) -> Void = { _ in }
    ) {
        self.model = model
        self.onRoomInfo = onRoomInfo
        self.onMediaGallery = onMediaGallery
        self.onSelect = onSelect
    }

    public var body: some View {
        Group {
            switch model.content {
            case .idle, .loading:
                LoadingState(.roomList())
            case .loaded(_, let rows):
                VStack(spacing: 0) {
                syncIndicator
                List {
                    Section {
                        if let onMediaGallery, model.filter == .all {
                            Button { onMediaGallery() } label: {
                                HStack(spacing: HaloSpacing.m) {
                                    Image(systemName: "photo.on.rectangle.angled")
                                        .font(HaloTypography.headline)
                                        .foregroundStyle(HaloColor.onAccent)
                                        .frame(width: 44, height: 44)
                                        .background(HaloColor.accent, in: Circle())
                                    VStack(alignment: .leading, spacing: HaloSpacing.xxs) {
                                        HStack {
                                            Text("Media Gallery")
                                                .font(HaloTypography.bodyEmphasis)
                                                .lineLimit(1)
                                            Spacer()
                                            Image(systemName: "chevron.right")
                                                .font(HaloTypography.captionEmphasis)
                                                .foregroundStyle(.tertiary)
                                        }
                                        Text("Photos, videos & files across rooms")
                                            .font(HaloTypography.meta)
                                            .foregroundStyle(HaloColor.textSecondary)
                                            .lineLimit(1)
                                    }
                                }
                            }
                            .foregroundStyle(HaloColor.textPrimary)
                            .accessibilityIdentifier("preset-media-gallery")
                        }
                        ForEach(rows) { row in
                            if row.isInvite {
                                HStack(alignment: .top, spacing: 12) {
                                    AvatarView(name: row.name, ref: model.invitePreviews[row.id]?.avatar ?? row.avatar) { await model.avatarData($0) }
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(row.name).fontWeight(.bold).lineLimit(1)
                                        Text(row.inviter.map { "Invitation from \($0)" } ?? "Invitation").font(.caption).foregroundStyle(.secondary)
                                        if let preview = model.invitePreviews[row.id] {
                                            if let topic = preview.topic, !topic.isEmpty { Text(topic).font(.caption) }
                                            if let members = preview.memberCount {
                                                Text(members == 1 ? "1 member" : "\(members) members").font(.caption).foregroundStyle(.secondary)
                                            }
                                        } else {
                                            Button("Show details") { Task { await model.previewInvite(row.id) } }.font(.caption)
                                                .accessibilityIdentifier("previewInvite-\(row.name)")
                                        }
                                        HStack {
                                            Button("Accept") { Task { await model.acceptInvite(row.id) } }.buttonStyle(.borderedProminent)
                                            Button("Decline", role: .destructive) { Task { await model.declineInvite(row.id) } }.buttonStyle(.bordered)
                                        }
                                    }
                                }
                                .accessibilityIdentifier("invite-\(row.name)")
                            } else {
                            Button { onSelect(row.id) } label: {
                                RoomRow(
                                    name: row.name,
                                    preview: row.preview,
                                    timestamp: row.lastActivity.map(ActivityTime.text),
                                    hasUnread: row.hasUnread,
                                    isMuted: row.isMuted,
                                    isFavourite: row.isFavourite,
                                    indicator: Self.indicatorStyle(row.display),
                                    previewIdentifier: "preview-\(row.name)"
                                ) {
                                    AvatarView(name: row.name, ref: row.avatar) { await model.avatarData($0) }
                                }
                            }
                            .foregroundStyle(HaloColor.textPrimary)
                                .swipeActions(edge: .leading) {
                                    Button("Read") { Task { await model.markRead(row.id) } }.tint(HaloColor.accent)
                                    Button(row.isFavourite ? "Unfavourite" : "Favourite") { Task { await model.toggleFavourite(row) } }.tint(HaloColor.warning)
                                }
                                .swipeActions(edge: .trailing) {
                                    Button("Unread") { Task { await model.markUnread(row.id) } }.tint(HaloColor.attention)
                                    Button(row.isMuted ? "Unmute" : "Mute") { Task { await model.toggleMute(row) } }.tint(HaloColor.textSecondary)
                                }
                                .contextMenu {
                                    if let onRoomInfo {
                                        Button("Room info", systemImage: "info.circle") { onRoomInfo(row.id) }
                                    }
                                    Button("Mark as read", systemImage: "envelope.open") { Task { await model.markRead(row.id) } }
                                    Button("Mark as unread", systemImage: "envelope.badge") { Task { await model.markUnread(row.id) } }
                                    Button(row.isFavourite ? "Unfavourite" : "Favourite", systemImage: row.isFavourite ? "star.slash" : "star") {
                                        Task { await model.toggleFavourite(row) }
                                    }
                                    Button(row.isMuted ? "Unmute" : "Mute", systemImage: row.isMuted ? "bell" : "bell.slash") {
                                        Task { await model.toggleMute(row) }
                                    }
                                }
                            }
                        }
                        if model.canShowMore {
                            Button("Show more rooms") {
                                Task { await model.showMore() }
                            }
                            .frame(maxWidth: .infinity, alignment: .center)
                            .accessibilityIdentifier("show-more-rooms")
                            .onAppear { Task { await model.showMore() } }
                        }
                    }
                }
                .contentMargins(.top, 8, for: .scrollContent)
                .accessibilityIdentifier("room-list")
                .overlay {
                    if rows.isEmpty && !(onMediaGallery != nil && model.filter == .all) {
                        EmptyState(icon: "bubble.left.and.bubble.right", title: Self.emptyTitle(model.filter))
                    }
                }
                .safeAreaInset(edge: .bottom) {
                    if let message = model.actionError {
                        HaloBanner(
                            tone: .danger,
                            icon: "exclamationmark.triangle.fill",
                            message: message,
                            onDismiss: { model.dismissActionError() }
                        )
                    }
                }
                }
            case .failed(let message):
                ErrorState(title: "Couldn't load rooms", message: message) {
                    Task { await model.retry() }
                }
            }
        }
        .task { await model.start() }
        .onAppear { Task { await model.refresh() } }
    }

    /// What an empty list says: no rooms at all, or nothing matching the chosen filter.
    static func emptyTitle(_ filter: RoomListFilter) -> String {
        switch filter {
        case .all: "No rooms yet"
        case .unread: "All caught up"
        case .people: "No direct chats"
        case .rooms: "No group rooms"
        case .favourites: "No favourites"
        case .invites: "No invitations"
        }
    }

    @ViewBuilder private var syncIndicator: some View {
        if let notice = model.syncNotice {
            HStack(spacing: 8) {
                Image(systemName: notice.isOffline ? "wifi.slash" : "arrow.triangle.2.circlepath")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(notice.text).font(.footnote).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 2)
            #if os(iOS)
            .background(Color(uiColor: .systemGroupedBackground), ignoresSafeAreaEdges: [])
            #endif
            .accessibilityIdentifier("sync-indicator")
        }
    }

    private static func indicatorStyle(_ display: DisplayCount) -> UnreadIndicator.Style {
        switch display {
        case .none: .none
        case .dot: .dot
        case .count(let n): .count(n)
        case .mentions(let n): .mentions(n)
        }
    }
}

/// Toolbar filter icon (`line.3.horizontal.decrease.circle`) that opens the room-list filter menu
/// (All, Unread, People, Rooms, Favourites, Invites) with a checkmark on the active filter.
public struct RoomListFilterMenu: View {
    @Bindable private var model: RoomListViewModel

    private static let options: [(filter: RoomListFilter, title: String, symbol: String)] = [
        (.all, "All", "tray.full"),
        (.unread, "Unread", "envelope.badge"),
        (.people, "People", "person.2"),
        (.rooms, "Rooms", "bubble.left.and.bubble.right"),
        (.favourites, "Favourites", "star"),
        (.invites, "Invites", "envelope.open"),
    ]

    public init(model: RoomListViewModel) { self.model = model }

    public var body: some View {
        Menu {
            ForEach(Self.options, id: \.title) { option in
                Button {
                    model.filter = option.filter
                } label: {
                    if model.filter == option.filter {
                        Label(option.title, systemImage: "checkmark")
                    } else {
                        Label(option.title, systemImage: option.symbol)
                    }
                }
                .accessibilityIdentifier("filter-\(option.title)")
            }
        } label: {
            Image(systemName: model.filter == .all ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
        }
        .accessibilityLabel("Filter rooms")
        .accessibilityIdentifier("room-filter-menu")
    }
}

/// Loads the avatar bytes for a row, then shows `AvatarCircle`.
struct AvatarView: View {
    let name: String
    let ref: MediaRef?
    let load: @Sendable (MediaRef) async -> Data?
    @State private var data: Data?

    var body: some View {
        AvatarCircle(name: name, imageData: data)
            .task(id: ref) {
                data = nil
                guard let ref else { return }
                data = await load(ref)
            }
    }
}
#endif
