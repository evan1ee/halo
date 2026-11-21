#if canImport(SwiftUI)
import HaloDesignSystem
import PhotosUI
import SwiftUI

/// Settings → Account → Profile: display name and ignored users.
struct ProfileSettingsView: View {
    @State private var model: ProfileSettingsModel

    @State private var picked: PhotosPickerItem?
    private let actions: ProfileSettingsActions

    init(actions: ProfileSettingsActions) {
        self.actions = actions
        _model = State(initialValue: ProfileSettingsModel(actions: actions))
    }

    var body: some View {
        List {
            Section("Photo") {
                HStack(spacing: 16) {
                    // The same round picture (or initial) others see beside your messages.
                    AvatarCircle(name: model.savedName.isEmpty ? (actions.userID ?? "?") : model.savedName, imageData: model.avatar, size: 64)
                        .accessibilityHidden(true)
                    PhotosPicker(selection: $picked, matching: .images) { Text(model.avatar == nil ? "Choose photo" : "Change photo") }
                        .accessibilityIdentifier("avatar-picker")
                    if model.avatar != nil { Button("Remove", role: .destructive) { Task { await model.removePhoto() } } }
                }
            }
            Section {
                TextField("Display name", text: $model.name).accessibilityIdentifier("display-name")
                Button("Save") { Task { await model.save() } }.disabled(!model.canSave)
            } header: {
                Text("Display name")
            } footer: {
                if let id = actions.userID { Text("Your Matrix ID is \(id). Others can find you with it.").textSelection(.enabled) }
            }
            Section {
                if model.ignored.isEmpty {
                    Text("Nobody").foregroundStyle(.secondary)
                } else {
                    ForEach(model.ignored, id: \.self) { user in
                        HStack {
                            Text(user)
                            Spacer()
                            Button("Unignore") { Task { await model.unignore(user) } }.buttonStyle(.bordered)
                        }
                    }
                }
            } header: {
                Text("Ignored users")
            }
            if let message = model.message { Section { Text(message).foregroundStyle(.secondary) } }
        }
        .onChange(of: picked) { _, item in
            guard let item else { return }
            picked = nil
            Task {
                guard let data = try? await item.loadTransferable(type: Data.self) else { return }
                await model.choosePhoto(data)
            }
        }
        .navigationTitle("Profile")
        .task { await model.load() }
    }
}
#endif
