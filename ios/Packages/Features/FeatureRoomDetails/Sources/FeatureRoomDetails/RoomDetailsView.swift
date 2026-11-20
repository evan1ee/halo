import HaloDomain
import SwiftUI

/// The room info sheet. Content and actions come from `RoomDetailsViewModel`; no logic here.
public struct RoomDetailsView: View {
    @State private var model: RoomDetailsViewModel
    @Environment(\.dismiss) private var dismiss

    private let onLeft: @MainActor () -> Void

    /// `onLeft` runs after the user left the room and the sheet closed (the caller closes the room's screen).
    public init(model: RoomDetailsViewModel, onLeft: @escaping @MainActor () -> Void = {}) {
        _model = State(initialValue: model)
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
                    HStack {
                        Text(member.title)
                        if member.isInvited { Text("Invited").font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        switch member.role {
                        case .administrator: Text("Admin").font(.caption).foregroundStyle(.secondary)
                        case .moderator: Text("Moderator").font(.caption).foregroundStyle(.secondary)
                        case .user: EmptyView()
                        }
                    }
                }
            }
            if let error = model.actionError { Section { Text(error).foregroundStyle(.red) } }
            Section {
                Button("Leave room", role: .destructive) { model.confirmsLeave = true }.accessibilityIdentifier("leaveRoom")
            }
        }
        .confirmationDialog("Leave this room?", isPresented: $model.confirmsLeave, titleVisibility: .visible) {
            Button("Leave", role: .destructive) { Task { await model.leave() } }
        } message: {
            Text(model.leavingStrandsRoom ? "You are the only administrator. Nobody will be able to manage the room after you leave." : "You will stop receiving its messages.")
        }
    }
}
