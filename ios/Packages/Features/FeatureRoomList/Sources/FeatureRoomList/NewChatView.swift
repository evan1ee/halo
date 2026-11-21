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
                    TextField("Name or @user:server", text: $model.query)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                        .focused($searchFocused)
                        .accessibilityIdentifier("newChatSearch")
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
                    if !model.invited.isEmpty { Text("Inviting " + model.invited.map(\.title).joined(separator: ", ")).font(.footnote).foregroundStyle(.secondary) }
                    Button("Create room") { Task { await model.createRoom() } }.disabled(!model.canCreateRoom).accessibilityIdentifier("createRoom")
                } header: {
                    Text("Or create a private room")
                } footer: {
                    Text("Give it a name to create it. People you tap \"Add to room\" on above are invited. Messages are encrypted.")
                }
                if let error = model.errorText { Section { Text(error).foregroundStyle(.red) } }
            }
            .navigationTitle("New chat")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .overlay { if model.isWorking { ProgressView() } }
            .onAppear { searchFocused = true }  // the sheet is opened to type a name: the keyboard is up at once
        }
    }
}
#endif
