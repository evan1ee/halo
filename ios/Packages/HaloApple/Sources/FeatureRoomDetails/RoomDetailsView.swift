import HaloDesignSystem
import HaloDomain
import HaloFoundation
import PhotosUI
import SwiftUI

/// The room info page. Content and actions come from `RoomDetailsViewModel`; no logic here.
public struct RoomDetailsView: View {
    @State private var model: RoomDetailsViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var editing = false
    @State private var inviting = false
    @State private var draftName = ""
    @State private var draftTopic = ""
    @State private var inviteText = ""
    @State private var picked: PhotosPickerItem?
    @State private var pendingModeration: PendingModeration?
    @State private var moderationReason = ""

    private struct PendingModeration: Identifiable {
        let member: RoomMemberInfo
        let action: RoomModerationPolicy.Action
        var id: String { "\(member.userID)-\(action)" }
    }

    private let onLeft: (@MainActor () -> Void)?
    private let onOpenSuccessor: (@MainActor (RoomID) -> Void)?
    private let onSearchInRoom: (@MainActor () -> Void)?
    private let onRenamed: @MainActor (String) -> Void
    private let profileSheet: (@MainActor (RoomMemberInfo, @escaping @MainActor () -> Void) -> AnyView?)?
    @State private var shownMember: RoomMemberInfo?

    /// `onLeft` runs after the user left the room (the caller pops the room and info pages from the stack).
    /// `onOpenSuccessor` opens or previews the replacement room when this room was upgraded (GA-23, M20-8).
    /// `onSearchInRoom` opens in-room message search for this room (M20-11).
    /// `onRenamed` runs when the user saves a new room name so the caller can update its navigation title at once.
    /// `profileSheet` builds the profile view for a tapped member (wired by the composition root so features don't import each other).
    public init(
        model: RoomDetailsViewModel,
        profileSheet: (@MainActor (RoomMemberInfo, @escaping @MainActor () -> Void) -> AnyView?)? = nil,
        onRenamed: @escaping @MainActor (String) -> Void = { _ in },
        onOpenSuccessor: (@MainActor (RoomID) -> Void)? = nil,
        onSearchInRoom: (@MainActor () -> Void)? = nil,
        onLeft: (@MainActor () -> Void)? = nil
    ) {
        _model = State(initialValue: model)
        self.profileSheet = profileSheet
        self.onRenamed = onRenamed
        self.onOpenSuccessor = onOpenSuccessor
        self.onSearchInRoom = onSearchInRoom
        self.onLeft = onLeft
    }

    public var body: some View {
        Group {
            switch model.content {
            case .loading: ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let text):
                ContentUnavailableView {
                    Label("Couldn't load the room", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(text)
                } actions: {
                    Button("Try again") { Task { await model.load() } }.buttonStyle(.borderedProminent)
                }
            case .loaded(let details, let members): list(details, members)
            }
        }
        .accessibilityIdentifier("roomDetailsPage")
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
        .task { await model.load() }
        .onChange(of: picked) { _, item in
            guard let item else { return }
            picked = nil
            Task {
                guard let data = try? await item.loadTransferable(type: Data.self) else { return }  // best-effort: an item the picker can't read is skipped
                await model.changePhoto(data)
            }
        }
        .onChange(of: model.hasLeft) { _, left in
            guard left else { return }
            if let onLeft {
                onLeft()
            } else {
                dismiss()
            }
        }
    }

    private func list(_ details: RoomDetails, _ members: [RoomMemberInfo]) -> some View {
        listBody(details, members)
            .refreshable { await model.refresh() }
            .scrollEdgeEffectHidden(true, for: .top)
    }

    private func listBody(_ details: RoomDetails, _ members: [RoomMemberInfo]) -> some View {
        List {
            Section {
                VStack(spacing: 8) {
                    if let local = model.localAvatar {
                        AvatarCircle(name: details.name ?? "?", imageData: local, size: 80)
                    } else {
                        AvatarLoader(name: details.name ?? "?", ref: details.avatar, size: 80) { await model.avatarData($0) }
                    }
                    Text(details.name ?? "Unnamed room").font(.title3.bold()).multilineTextAlignment(.center)
                    if let topic = details.topic, !topic.isEmpty {
                        Text(topic).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                Label(details.isEncrypted ? "Encrypted" : "Not encrypted", systemImage: details.isEncrypted ? "lock.fill" : "lock.open")
                Label(model.memberCountText, systemImage: "person.2")
            }
            if let successor = details.successor {
                Section("Upgraded room") {
                    Text(successor.reason ?? "This room has been replaced by a newer version.")
                        .font(HaloTypography.meta)
                        .foregroundStyle(HaloColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let onOpenSuccessor {
                        Button {
                            onOpenSuccessor(successor.roomID)
                        } label: {
                            Label("Go to new room", systemImage: "arrow.up.circle.fill")
                        }
                        .accessibilityIdentifier("roomDetailsOpenSuccessor")
                    }
                }
            }
            if details.canEditDetails || details.canInvite {
                Section {
                    if details.canEditDetails {
                        let photoLabel = model.hasAvatar ? "Change photo" : "Choose photo"
                        Button { draftName = details.name ?? ""; draftTopic = details.topic ?? ""; editing = true } label: {
                            Label("Edit name and topic", systemImage: "pencil")
                        }
                        .accessibilityIdentifier("editRoom")
                        PhotosPicker(selection: $picked, matching: .images) {
                            Label(photoLabel, systemImage: "photo")
                        }
                        .accessibilityIdentifier("changeRoomPhoto")
                        if model.hasAvatar {
                            Button(role: .destructive) { Task { await model.removePhoto() } } label: {
                                Label("Remove photo", systemImage: "trash")
                            }
                            .accessibilityIdentifier("removeRoomPhoto")
                        }
                    }
                    if details.canInvite {
                        Button { inviteText = ""; inviting = true } label: {
                            Label("Invite someone", systemImage: "person.badge.plus")
                        }
                        .accessibilityIdentifier("inviteToRoom")
                    }
                }
            }
            Section("Notifications") {
                Picker("Notify me for", selection: Binding(get: { details.notificationMode }, set: { mode in Task { await model.setNotificationMode(mode) } })) {
                    Text("All messages").tag(RoomNotificationChoice.allMessages)
                    Text("Mentions and keywords").tag(RoomNotificationChoice.mentionsAndKeywords)
                    Text("Mute").tag(RoomNotificationChoice.mute)
                }
                .accessibilityIdentifier("roomNotificationMode")
            }
            Section("Media & Files") {
                if let onSearchInRoom {
                    Button(action: onSearchInRoom) {
                        Label("Search in chat", systemImage: "magnifyingglass")
                    }
                    .accessibilityIdentifier("roomDetailsSearch")
                }
                NavigationLink {
                    RoomMediaGalleryView(model: model)
                } label: {
                    Label("Photos, videos & files", systemImage: "photo.on.rectangle.angled")
                }
                .accessibilityIdentifier("roomMediaGallery")
                if model.canExportEncryptedRoom {
                    NavigationLink {
                        RoomEncryptedExportView(model: model)
                    } label: {
                        Label("Export encrypted history", systemImage: "lock.doc")
                    }
                    .accessibilityIdentifier("roomEncryptedExport")
                }
            }
            Section("Members") {
                ForEach(members) { member in
                    memberRow(member)
                }
                if model.hasMoreMembers {
                    Button("Show more members") { Task { await model.loadMoreMembers() } }
                        .accessibilityIdentifier("roomMoreMembers")
                }
            }
            if !model.bannedMembers.isEmpty {
                Section("Banned") {
                    ForEach(model.bannedMembers) { banned in
                        bannedRow(banned)
                    }
                }
            }
            if let error = model.actionError {
                Section {
                    HStack(spacing: HaloSpacing.s) {
                        Text(error).foregroundStyle(HaloColor.danger)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("roomActionError")
                        Spacer()
                        Button { model.dismissActionError() } label: { Image(systemName: "xmark").font(HaloTypography.caption.weight(.semibold)) }
                            .buttonStyle(.plain)
                            .foregroundStyle(HaloColor.textSecondary)
                            .accessibilityLabel("Dismiss")
                    }
                }
            }
            Section {
                Button("Leave room", role: .destructive) { model.confirmsLeave = true }.accessibilityIdentifier("leaveRoom")
            }
        }
        .sheet(item: $shownMember) { member in
            if let view = profileSheet?(member, { shownMember = nil }) { view }
        }
        .alert(
            moderationAlertTitle,
            isPresented: Binding(get: { pendingModeration != nil }, set: { if !$0 { pendingModeration = nil; moderationReason = "" } }),
            presenting: pendingModeration
        ) { pending in
            TextField("Reason (optional)", text: $moderationReason)
            Button(moderationConfirmLabel(pending), role: pending.action == .unban ? nil : .destructive) {
                let reason = moderationReason
                pendingModeration = nil
                moderationReason = ""
                Task {
                    switch pending.action {
                    case .remove: _ = await model.removeMember(pending.member, reason: reason)
                    case .ban: _ = await model.banMember(pending.member, reason: reason)
                    case .unban: _ = await model.unbanMember(pending.member, reason: reason)
                    }
                }
            }
            .accessibilityIdentifier("confirmModeration")
            Button("Cancel", role: .cancel) {
                pendingModeration = nil
                moderationReason = ""
            }
        } message: { pending in
            Text(moderationAlertMessage(pending))
        }
        .alert("Edit room", isPresented: $editing) {
            TextField("Name", text: $draftName)
            TextField("Topic", text: $draftTopic)
            Button("Save") {
                let saved = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
                Task { if await model.saveDetails(name: draftName, topic: draftTopic) { onRenamed(saved) } }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Invite someone", isPresented: $inviting) {
            TextField("@name:server", text: $inviteText)
            Button("Invite") { Task { _ = await model.invite(inviteText) } }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Leave this room?", isPresented: $model.confirmsLeave) {
            Button("Leave", role: .destructive) { Task { await model.leave() } }
            Button("Leave and forget", role: .destructive) { Task { await model.leaveAndForget() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(model.leavingStrandsRoom ? "You are the only administrator. Nobody will be able to manage the room after you leave." : "You will stop receiving its messages.")
        }
    }

    @ViewBuilder
    func memberRow(_ member: RoomMemberInfo) -> some View {
        let actions = model.moderationActions(for: member)
        let roleLabel = RoomModerationPolicy.roleLabel(for: member)
        let isBusy = model.moderatingUserID == member.userID

        HStack(spacing: HaloSpacing.s) {
            if profileSheet != nil {
                Button { shownMember = member } label: {
                    memberIdentity(member, roleLabel: roleLabel)
                }
                .buttonStyle(.plain)
                .foregroundStyle(HaloColor.textPrimary)
            } else {
                memberIdentity(member, roleLabel: roleLabel)
                    .foregroundStyle(HaloColor.textPrimary)
            }

            if isBusy {
                ProgressView().controlSize(.small)
                    .accessibilityLabel("Updating membership")
            } else if !actions.isEmpty {
                Menu {
                    if actions.canRemove {
                        Button(role: .destructive) {
                            moderationReason = ""
                            pendingModeration = PendingModeration(member: member, action: .remove)
                        } label: {
                            Label(member.isInvited ? "Cancel invitation" : "Remove from room", systemImage: "person.badge.minus")
                        }
                    }
                    if actions.canBan {
                        Button(role: .destructive) {
                            moderationReason = ""
                            pendingModeration = PendingModeration(member: member, action: .ban)
                        } label: {
                            Label("Ban from room", systemImage: "hand.raised.slash")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(HaloTypography.body)
                        .foregroundStyle(HaloColor.textSecondary)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(model.moderatingUserID != nil)
                .accessibilityLabel("Moderate \(member.title)")
                .accessibilityIdentifier("moderate-\(member.userID)")
            }
        }
        .contextMenu {
            if actions.canRemove {
                Button(role: .destructive) {
                    moderationReason = ""
                    pendingModeration = PendingModeration(member: member, action: .remove)
                } label: {
                    Label(member.isInvited ? "Cancel invitation" : "Remove from room", systemImage: "person.badge.minus")
                }
            }
            if actions.canBan {
                Button(role: .destructive) {
                    moderationReason = ""
                    pendingModeration = PendingModeration(member: member, action: .ban)
                } label: {
                    Label("Ban from room", systemImage: "hand.raised.slash")
                }
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if actions.canBan {
                Button("Ban", role: .destructive) {
                    moderationReason = ""
                    pendingModeration = PendingModeration(member: member, action: .ban)
                }
            }
            if actions.canRemove {
                Button(member.isInvited ? "Cancel" : "Remove", role: .destructive) {
                    moderationReason = ""
                    pendingModeration = PendingModeration(member: member, action: .remove)
                }
                .tint(HaloColor.warning)
            }
        }
    }

    @ViewBuilder
    private func memberIdentity(_ member: RoomMemberInfo, roleLabel: String?) -> some View {
        MemberIdentityRow(member: member, roleLabel: roleLabel) { await model.avatarData($0) }
    }

    @ViewBuilder
    func bannedRow(_ member: RoomMemberInfo) -> some View {
        let actions = model.moderationActions(for: member)
        let isBusy = model.moderatingUserID == member.userID
        BannedMemberRow(
            member: member,
            canUnban: actions.canUnban,
            isBusy: isBusy,
            isDisabled: model.moderatingUserID != nil,
            loadAvatar: { await model.avatarData($0) },
            onUnban: {
                moderationReason = ""
                pendingModeration = PendingModeration(member: member, action: .unban)
            }
        )
    }

    private var moderationAlertTitle: String {
        guard let pending = pendingModeration else { return "" }
        switch pending.action {
        case .remove:
            return pending.member.isInvited ? "Cancel invitation?" : "Remove \(pending.member.title)?"
        case .ban:
            return "Ban \(pending.member.title)?"
        case .unban:
            return "Unban \(pending.member.title)?"
        }
    }

    private func moderationConfirmLabel(_ pending: PendingModeration) -> String {
        switch pending.action {
        case .remove: pending.member.isInvited ? "Cancel invitation" : "Remove"
        case .ban: "Ban"
        case .unban: "Unban"
        }
    }

    private func moderationAlertMessage(_ pending: PendingModeration) -> String {
        switch pending.action {
        case .remove:
            return pending.member.isInvited
                ? "\(pending.member.title) will no longer be invited to this room."
                : "\(pending.member.title) will be removed from the room and can rejoin only if invited or permitted."
        case .ban:
            return "\(pending.member.title) will be removed and prevented from rejoining until unbanned."
        case .unban:
            return "\(pending.member.title) will be allowed to rejoin this room if invited or permitted."
        }
    }
}

/// Member identity row with AX5-adaptive role badge placement.
private struct MemberIdentityRow: View {
    let member: RoomMemberInfo
    let roleLabel: String?
    let loadAvatar: @MainActor (MediaRef) async -> Data?
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        HStack(spacing: HaloSpacing.s) {
            AvatarLoader(name: member.title, ref: member.avatar, size: 32, load: loadAvatar)
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: HaloSpacing.xxs) {
                    Text(member.title)
                        .font(HaloTypography.body)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: HaloSpacing.xs) {
                        if member.isInvited {
                            Text("Invited").font(HaloTypography.caption).foregroundStyle(HaloColor.textSecondary)
                        }
                        if let roleLabel {
                            roleBadge(roleLabel)
                        }
                    }
                }
                Spacer(minLength: 0)
            } else {
                Text(member.title)
                    .font(HaloTypography.body)
                    .lineLimit(1)
                if member.isInvited {
                    Text("Invited").font(HaloTypography.caption).foregroundStyle(HaloColor.textSecondary)
                }
                Spacer(minLength: HaloSpacing.xs)
                if let roleLabel {
                    roleBadge(roleLabel)
                }
            }
        }
        .contentShape(.rect)
    }

    private func roleBadge(_ label: String) -> some View {
        Text(label)
            .font(HaloTypography.caption.weight(.medium))
            .foregroundStyle(HaloColor.textSecondary)
            .padding(.horizontal, HaloSpacing.xs)
            .padding(.vertical, 2)
            .background(HaloColor.bgSecondary, in: .capsule)
    }
}

/// Banned member row with AX5-adaptive Unban button placement.
private struct BannedMemberRow: View {
    let member: RoomMemberInfo
    let canUnban: Bool
    let isBusy: Bool
    let isDisabled: Bool
    let loadAvatar: @MainActor (MediaRef) async -> Data?
    let onUnban: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: HaloSpacing.xs) {
                identity
                trailingControl
            }
        } else {
            HStack(spacing: HaloSpacing.s) {
                identity
                Spacer(minLength: HaloSpacing.xs)
                trailingControl
            }
        }
    }

    private var identity: some View {
        HStack(spacing: HaloSpacing.s) {
            AvatarLoader(name: member.title, ref: member.avatar, size: 32, load: loadAvatar)
            VStack(alignment: .leading, spacing: HaloSpacing.xxs) {
                Text(member.title)
                    .font(HaloTypography.body)
                    .foregroundStyle(HaloColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if let reason = member.banReason, !reason.isEmpty {
                    Text(reason)
                        .font(HaloTypography.caption)
                        .foregroundStyle(HaloColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder
    private var trailingControl: some View {
        if isBusy {
            ProgressView().controlSize(.small)
                .accessibilityLabel("Unbanning")
        } else if canUnban {
            Button("Unban", action: onUnban)
                .font(HaloTypography.meta.weight(.medium))
                .foregroundStyle(HaloColor.accent)
                .frame(minHeight: 44)
                .disabled(isDisabled)
                .accessibilityLabel("Unban \(member.title)")
                .accessibilityIdentifier("unban-\(member.userID)")
        }
    }
}

/// Loads the avatar bytes for `ref`, then shows `AvatarCircle`.
private struct AvatarLoader: View {
    let name: String
    let ref: MediaRef?
    let size: CGFloat
    let load: @MainActor (MediaRef) async -> Data?
    @State private var data: Data?

    var body: some View {
        AvatarCircle(name: name, imageData: data, size: size)
            .task(id: ref) {
                data = nil
                guard let ref else { return }
                data = await load(ref)
            }
    }
}
