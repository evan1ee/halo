import HaloDomain
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

    private let onLeft: @MainActor () -> Void
    private let profile: (@MainActor (RoomMemberInfo) -> UserProfileViewModel?)?
    @State private var shownProfile: UserProfileViewModel?

    /// `onLeft` runs after the user left the room and the sheet closed (the caller closes the room's screen).
    /// `profile` makes the profile sheet of a tapped member; without it members aren't tappable.
    public init(model: RoomDetailsViewModel, profile: (@MainActor (RoomMemberInfo) -> UserProfileViewModel?)? = nil, onLeft: @escaping @MainActor () -> Void = {}) {
        _model = State(initialValue: model)
        self.profile = profile
        self.onLeft = onLeft
    }

    public var body: some View {
        NavigationStack {
            Group {
                switch model.content {
                case .loading: ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                case .failed(let text): ContentUnavailableView("Couldn't load the room", systemImage: "exclamationmark.triangle", description: Text(text))
                case .loaded(let details, let members): list(details, members)
                }
            }
            .navigationTitle("Room info")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .task { await model.load() }
        .onChange(of: model.hasLeft) { _, left in if left { dismiss(); onLeft() } }
    }

    private func list(_ details: RoomDetails, _ members: [RoomMemberInfo]) -> some View {
        List {
            Section {
                Text(details.name ?? "Unnamed room").font(.headline)
                if let topic = details.topic, !topic.isEmpty { Text(topic).foregroundStyle(.secondary) }
                Label(details.isEncrypted ? "Encrypted" : "Not encrypted", systemImage: details.isEncrypted ? "lock.fill" : "lock.open")
                Label("\(model.joinedMemberCount) members", systemImage: "person.2")
            }
            if details.canEditDetails || details.canInvite {
                Section {
                    if details.canEditDetails {
                        Button("Edit name and topic") { draftName = details.name ?? ""; draftTopic = details.topic ?? ""; editing = true }.accessibilityIdentifier("editRoom")
                    }
                    if details.canInvite {
                        Button("Invite someone") { inviteText = ""; inviting = true }.accessibilityIdentifier("inviteToRoom")
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
            Section("Members") {
                ForEach(members) { member in
                    Button { if let profile { shownProfile = profile(member) } } label: { HStack {
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
                    .disabled(profile == nil)
                }
            }
            if let error = model.actionError { Section { Text(error).foregroundStyle(.red) } }
            Section {
                Button("Leave room", role: .destructive) { model.confirmsLeave = true }.accessibilityIdentifier("leaveRoom")
            }
        }
        .sheet(item: $shownProfile) { UserProfileView(model: $0) }
        .alert("Edit room", isPresented: $editing) {
            TextField("Name", text: $draftName)
            TextField("Topic", text: $draftTopic)
            Button("Save") { Task { _ = await model.saveDetails(name: draftName, topic: draftTopic) } }
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
