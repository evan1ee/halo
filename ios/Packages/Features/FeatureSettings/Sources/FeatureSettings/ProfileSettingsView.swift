#if canImport(SwiftUI)
import SwiftUI

/// Settings → Account → Profile: display name and ignored users.
struct ProfileSettingsView: View {
    @State private var model: ProfileSettingsModel

    init(actions: ProfileSettingsActions) { _model = State(initialValue: ProfileSettingsModel(actions: actions)) }

    var body: some View {
        List {
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
        .navigationTitle("Profile")
        .task { await model.load() }
    }
}
#endif
