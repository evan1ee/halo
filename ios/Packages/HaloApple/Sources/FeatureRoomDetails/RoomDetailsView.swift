import HaloDesignSystem
import HaloDomain
import PhotosUI
import SwiftUI

/// The room info sheet. Content and actions come from `RoomDetailsViewModel`; no logic here.
public struct RoomDetailsView: View {
    @State private var model: RoomDetailsViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var editing = false
    @State private var inviting = false
    @State private var draftName = ""
    @State private var draftTopic = ""
    @State private var inviteText = ""
    @State private var picked: PhotosPickerItem?

    private let onLeft: @MainActor () -> Void
    private let onRenamed: @MainActor (String) -> Void
    private let profileSheet: (@MainActor (RoomMemberInfo) -> AnyView?)?
    @State private var shownMember: RoomMemberInfo?

    /// `onLeft` runs after the user left the room and the sheet closed (the caller closes the room's screen).
    /// `onRenamed` runs when the user saves a new room name so the caller can update its navigation title at once.
    /// `profileSheet` builds the profile view for a tapped member (wired by the composition root so features don't import each other).
    public init(
        model: RoomDetailsViewModel, profileSheet: (@MainActor (RoomMemberInfo) -> AnyView?)? = nil,
        onRenamed: @escaping @MainActor (String) -> Void = { _ in }, onLeft: @escaping @MainActor () -> Void = {}
    ) {
        _model = State(initialValue: model)
        self.profileSheet = profileSheet
        self.onRenamed = onRenamed
        self.onLeft = onLeft
    }

    public var body: some View {
        NavigationStack {
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
            .navigationTitle("Room info")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .task { await model.load() }
        .onChange(of: picked) { _, item in
            guard let item else { return }
            picked = nil
            Task {
                guard let data = try? await item.loadTransferable(type: Data.self) else { return }
                await model.changePhoto(data)
            }
        }
        .onChange(of: model.hasLeft) { _, left in if left { dismiss(); onLeft() } }
    }

    private func list(_ details: RoomDetails, _ members: [RoomMemberInfo]) -> some View {
        listBody(details, members)
            .refreshable { await model.refresh() }
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
                    Button { if profileSheet != nil { shownMember = member } } label: { HStack {
                        AvatarLoader(name: member.title, ref: member.avatar, size: 32) { await model.avatarData($0) }
                        Text(member.title)
                        if member.isInvited { Text("Invited").font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        switch member.role {
                        case .administrator: Text("Admin").font(.caption).foregroundStyle(.secondary)
                        case .moderator: Text("Moderator").font(.caption).foregroundStyle(.secondary)
                        case .user: EmptyView()
                        }
                    } }
                    .foregroundStyle(.primary)
                    .disabled(profileSheet == nil)
                }
                if model.hasMoreMembers {
                    Button("Show more members") { Task { await model.loadMoreMembers() } }
                        .accessibilityIdentifier("roomMoreMembers")
                }
            }
            if let error = model.actionError {
                Section {
                    HStack(spacing: 10) {
                        Text(error).foregroundStyle(HaloColor.danger)
                        Spacer()
                        Button { model.dismissActionError() } label: { Image(systemName: "xmark").font(.footnote.weight(.semibold)) }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Dismiss")
                    }
                }
            }
            Section {
                Button("Leave room", role: .destructive) { model.confirmsLeave = true }.accessibilityIdentifier("leaveRoom")
            }
        }
        .sheet(item: $shownMember) { member in
            if let view = profileSheet?(member) { view }
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
        .confirmationDialog("Leave this room?", isPresented: $model.confirmsLeave, titleVisibility: .visible) {
            Button("Leave", role: .destructive) { Task { await model.leave() } }
        } message: {
            Text(model.leavingStrandsRoom ? "You are the only administrator. Nobody will be able to manage the room after you leave." : "You will stop receiving its messages.")
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
