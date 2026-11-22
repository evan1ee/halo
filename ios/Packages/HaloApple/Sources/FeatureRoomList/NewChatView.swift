#if canImport(SwiftUI)
import HaloDesignSystem
import HaloDomain
import SwiftUI

/// The "New chat" sheet. All logic lives in `NewChatViewModel`.
public struct NewChatView: View {
    @State private var model: NewChatViewModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var searchFocused: Bool

    public init(model: NewChatViewModel) { _model = State(initialValue: model) }

    public var body: some View {
        NavigationStack {
            List {
                Section("Find a person") {
                    HStack(spacing: 8) {
                        TextField("Name or @user:server", text: $model.query)
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                            .autocorrectionDisabled()
                            .focused($searchFocused)
                            .accessibilityIdentifier("newChatSearch")
                        if !model.query.isEmpty {
                            Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Clear search")
                        }
                    }
                    if model.isSearching && model.candidates.isEmpty {
                        HStack(spacing: 8) { ProgressView(); Text("Searching…").foregroundStyle(.secondary) }
                    } else if model.foundNobody {
                        Text("No one found. To reach someone the directory doesn't list, type their full ID, like @name:server.")
                            .font(.footnote).foregroundStyle(.secondary)
                            .accessibilityIdentifier("newChatNoResults")
                    }
                    ForEach(model.candidates) { user in
                        HStack {
                            Button { Task { await model.startChat(with: user) } } label: {
                                HStack(spacing: 10) {
                                    AvatarCircle(name: user.title, imageData: nil, size: 32)
                                    VStack(alignment: .leading) {
                                        Text(user.title)
                                        if user.displayName != nil { Text(user.id.rawValue).font(.caption).foregroundStyle(.secondary) }
                                    }
                                }
                            }
                            .foregroundStyle(.primary)
                            Spacer()
                            Button(model.invited.contains { $0.id == user.id } ? "Added" : "Add to room") { model.toggleInvite(user) }
                                .font(.caption).buttonStyle(.bordered)
                        }
                    }
                }
                Section {
                    TextField("Room name", text: $model.roomName).accessibilityIdentifier("newRoomName")
                        .submitLabel(.done).onSubmit { if model.canCreateRoom { Task { await model.createRoom() } } }
                    if !model.invited.isEmpty { Text("Inviting " + model.invited.map(\.title).joined(separator: ", ")).font(.footnote).foregroundStyle(.secondary) }
                    Button { Task { await model.createRoom() } } label: {
                        // A list row drops the disabled look of a Label: grey it out explicitly until there's a name.
                        Label("Create room", systemImage: "plus.circle.fill")
                            .foregroundStyle(model.canCreateRoom ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                    }.disabled(!model.canCreateRoom).accessibilityIdentifier("createRoom")
                } header: {
                    Text("Or create a private room")
                } footer: {
                    Text("Name the room, then create it. To invite people, find them above and tap \"Add to room\". Messages are encrypted.")
                }
                Section {
                    TextField("#room:server or !id:server", text: $model.roomAddress)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                        .submitLabel(.join)
                        .onSubmit { if model.canJoinRoom { Task { await model.joinRoom() } } }
                        .accessibilityIdentifier("joinRoomAddress")
                    Button { Task { await model.joinRoom() } } label: {
                        Label("Join room", systemImage: "arrow.right.circle.fill")
                            .foregroundStyle(model.canJoinRoom ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                    }
                    .disabled(!model.canJoinRoom)
                    .accessibilityIdentifier("joinRoomButton")
                } header: {
                    Text("Or join a room by address")
                } footer: {
                    Text("Enter a Matrix room alias (#room:server) or room ID (!id:server) to join directly.")
                }
                if let error = model.errorText { Section { Text(error).foregroundStyle(HaloColor.danger) } }
            }
            .navigationTitle("New chat")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(model.isWorking) } }
            .overlay { if model.isWorking { ProgressView() } }
            .onAppear { searchFocused = true }  // the sheet is opened to type a name: the keyboard is up at once
        }
        .interactiveDismissDisabled(model.isWorking)
    }
}
#endif
