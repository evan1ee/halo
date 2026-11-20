#if canImport(SwiftUI)
import PhotosUI
import SwiftUI

/// Settings → Account → Profile: display name and ignored users.
struct ProfileSettingsView: View {
    @State private var model: ProfileSettingsModel

    @State private var picked: PhotosPickerItem?

    init(actions: ProfileSettingsActions) { _model = State(initialValue: ProfileSettingsModel(actions: actions)) }

    var body: some View {
        List {
            Section("Photo") {
                HStack(spacing: 16) {
                    ZStack {
                        Circle().fill(.quaternary)
                        #if canImport(UIKit)
                        if let data = model.avatar, let image = UIImage(data: data) {
                            Image(uiImage: image).resizable().scaledToFill()
                        } else { Image(systemName: "person.fill").foregroundStyle(.secondary) }
                        #endif
                    }
                    .frame(width: 64, height: 64).clipShape(Circle()).accessibilityHidden(true)
                    PhotosPicker(selection: $picked, matching: .images) { Text(model.avatar == nil ? "Choose photo" : "Change photo") }
                        .accessibilityIdentifier("avatar-picker")
                    if model.avatar != nil { Button("Remove", role: .destructive) { Task { await model.removePhoto() } } }
                }
            }
            Section("Display name") {
                TextField("Display name", text: $model.name).accessibilityIdentifier("display-name")
                Button("Save") { Task { await model.save() } }.disabled(!model.canSave)
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
