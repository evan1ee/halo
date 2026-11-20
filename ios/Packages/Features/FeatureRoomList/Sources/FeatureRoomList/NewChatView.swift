#if canImport(SwiftUI)
import HaloDomain
import SwiftUI

/// The "New chat" sheet. All logic lives in `NewChatViewModel`.
public struct NewChatView: View {
    @State private var model: NewChatViewModel
    @Environment(\.dismiss) private var dismiss

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
                        .accessibilityIdentifier("newChatSearch")
                    ForEach(model.candidates) { user in
                        HStack {
                            Button { Task { await model.startChat(with: user) } } label: {
                                VStack(alignment: .leading) {
                                    Text(user.title)
                                    if user.displayName != nil { Text(user.id.rawValue).font(.caption).foregroundStyle(.secondary) }
                                }
                            }
                            .foregroundStyle(.primary)
                            Spacer()
                            Button(model.invited.contains { $0.id == user.id } ? "Added" : "Add to room") { model.toggleInvite(user) }
                                .font(.caption).buttonStyle(.bordered)
                        }
                    }
                }
                Section("Or create a private room") {
                    TextField("Room name", text: $model.roomName).accessibilityIdentifier("newRoomName")
                    if !model.invited.isEmpty { Text("Inviting " + model.invited.map(\.title).joined(separator: ", ")).font(.footnote).foregroundStyle(.secondary) }
                    Button("Create room") { Task { await model.createRoom() } }.disabled(!model.canCreateRoom).accessibilityIdentifier("createRoom")
                }
                if let error = model.errorText { Section { Text(error).foregroundStyle(.red) } }
            }
            .navigationTitle("New chat")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .overlay { if model.isWorking { ProgressView() } }
        }
    }
}
#endif
