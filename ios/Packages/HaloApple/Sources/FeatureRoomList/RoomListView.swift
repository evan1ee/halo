#if canImport(SwiftUI)
import HaloDesignSystem
import HaloDomain
import HaloFoundation
import SwiftUI

public struct RoomListView<SearchResults: View>: View {
    @Bindable private var model: RoomListViewModel
    private let searchQuery: String
    private let onSelect: (RoomID) -> Void
    private let onRoomInfo: ((RoomID) -> Void)?
    private let onMediaGallery: (() -> Void)?
    private let searchResults: SearchResults

    /// `onSelect` is called when a room is tapped; `onRoomInfo` opens the room info sheet from a row's context menu;
    /// `onMediaGallery` opens the preset non-Matrix Global Media Gallery entry (D83);
    /// `searchQuery` filters rooms by name while typing and `searchResults` embeds a "Messages" section (D85).
    /// Navigation itself belongs to the composition root.
    public init(
        model: RoomListViewModel,
        searchQuery: String = "",
        onRoomInfo: ((RoomID) -> Void)? = nil,
        onMediaGallery: (() -> Void)? = nil,
        onSelect: @escaping (RoomID) -> Void = { _ in },
        @ViewBuilder searchResults: () -> SearchResults
    ) {
        self.model = model
        self.searchQuery = searchQuery
        self.onRoomInfo = onRoomInfo
        self.onMediaGallery = onMediaGallery
        self.onSelect = onSelect
        self.searchResults = searchResults()
    }

    public init(
        model: RoomListViewModel,
        searchQuery: String = "",
        onRoomInfo: ((RoomID) -> Void)? = nil,
        onMediaGallery: (() -> Void)? = nil,
        onSelect: @escaping (RoomID) -> Void = { _ in }
    ) where SearchResults == EmptyView {
        self.init(
            model: model,
            searchQuery: searchQuery,
            onRoomInfo: onRoomInfo,
            onMediaGallery: onMediaGallery,
            onSelect: onSelect,
            searchResults: { EmptyView() }
        )
    }

    public var body: some View {
        Group {
            switch model.content {
            case .idle, .loading:
                LoadingState(.roomList())
            case .loaded(_, let rows):
                let trimmedQuery = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
                let visibleRows = trimmedQuery.isEmpty
                    ? rows
                    : rows.filter { $0.name.localizedCaseInsensitiveContains(trimmedQuery) }
                let showMediaGallery = onMediaGallery != nil
                    && model.effectiveFilter == .all
                    && (trimmedQuery.isEmpty || "Media Gallery".localizedCaseInsensitiveContains(trimmedQuery))
                VStack(spacing: 0) {
                focusBanner
                syncIndicator
                List {
                    Section {
                        if let onMediaGallery, showMediaGallery {
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
                        ForEach(visibleRows) { row in
                            if row.isInvite {
                                HStack(alignment: .top, spacing: 12) {
                                    AvatarView(name: row.name, ref: model.invitePreviews[row.id]?.avatar ?? row.avatar) { [model] in await model.avatarData($0) }
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
                                joinedRoomRow(row)
                            }
                        }
                        if model.canShowMore && trimmedQuery.isEmpty {
                            Button("Show more rooms") {
                                Task { await model.showMore() }
                            }
                            .frame(maxWidth: .infinity, alignment: .center)
                            .accessibilityIdentifier("show-more-rooms")
                            .onAppear { Task { await model.showMore() } }
                        }
                    }
                    searchResults
                }
                .contentMargins(.top, 8, for: .scrollContent)
                .refreshable { await model.refresh() }
                .accessibilityIdentifier("room-list")
                .overlay {
                    if trimmedQuery.isEmpty && visibleRows.isEmpty && !showMediaGallery {
                        EmptyState(icon: "bubble.left.and.bubble.right", title: Self.emptyTitle(model.effectiveFilter))
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

    @ViewBuilder private var focusBanner: some View {
        if model.isFocusFiltering, let chats = model.focusChats {
            HStack(spacing: 8) {
                Image(systemName: "moon.fill").font(.footnote).foregroundStyle(.secondary).accessibilityHidden(true)
                Text("Focus: showing \(chats.title.lowercased()) only").font(.footnote).foregroundStyle(.secondary)
                Spacer()
                Button("Show all chats") { model.suspendFocusFilter() }
                    .font(.footnote)
                    .accessibilityIdentifier("focus-show-all")
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
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

    @ViewBuilder
    private func joinedRoomRow(_ row: RoomListViewModel.Row) -> some View {
        let content = Button { onSelect(row.id) } label: {
            RoomRow(
                name: row.name,
                preview: row.preview,
                timestamp: row.lastActivity.map { ActivityTime.text($0) },
                hasUnread: row.hasUnread,
                isMuted: row.isMuted,
                isFavourite: row.isFavourite,
                indicator: Self.indicatorStyle(row.display),
                previewIdentifier: "preview-\(row.name)"
            ) {
                AvatarView(name: row.name, ref: row.avatar) { [model] in await model.avatarData($0) }
            }
        }
        .foregroundStyle(HaloColor.textPrimary)

        content
            .accessibilityAction(named: row.hasUnread ? "Mark read" : "Mark unread") {
                Task {
                    if row.hasUnread {
                        await model.markRead(row.id)
                    } else {
                        await model.markUnread(row.id)
                    }
                }
            }
            .accessibilityAction(named: row.isMuted ? "Unmute" : "Mute") {
                Task { await model.toggleMute(row) }
            }
            .accessibilityAction(named: row.isFavourite ? "Unfavourite" : "Favourite") {
                Task { await model.toggleFavourite(row) }
            }
            .swipeActions(edge: .leading) {
                Button { Task { await model.markRead(row.id) } } label: {
                    Label("Read", systemImage: "envelope.open")
                }
                .tint(HaloColor.accent)
                Button { Task { await model.toggleFavourite(row) } } label: {
                    Label(row.isFavourite ? "Unfavourite" : "Favourite", systemImage: row.isFavourite ? "star.slash" : "star.fill")
                }
                .tint(HaloColor.warning)
            }
            .swipeActions(edge: .trailing) {
                Button { Task { await model.markUnread(row.id) } } label: {
                    Label("Unread", systemImage: "envelope.badge")
                }
                .tint(HaloColor.attention)
                Button { Task { await model.toggleMute(row) } } label: {
                    Label(row.isMuted ? "Unmute" : "Mute", systemImage: row.isMuted ? "bell" : "bell.slash")
                }
                .tint(HaloColor.textSecondary)
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
