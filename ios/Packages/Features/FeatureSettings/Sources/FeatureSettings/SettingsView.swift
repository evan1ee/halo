#if canImport(SwiftUI)
import SwiftUI

/// Settings v1 (docs/features/SETTINGS.md): account, about and the acknowledgements. The other sections arrive with their features.
public struct SettingsView: View {
    private let version: String
    private let build: String
    private let onSignOut: () -> Void
    private let preferences: AppPreferences
    private let onPrivateReceiptsChange: (Bool) -> Void
    @State private var confirmingSignOut = false
    @State private var privateReceipts: Bool

    /// `onPrivateReceiptsChange` applies a changed receipt privacy to the running app (the preference itself is stored here).
    public init(
        version: String, build: String, preferences: AppPreferences = AppPreferences(),
        onPrivateReceiptsChange: @escaping (Bool) -> Void = { _ in }, onSignOut: @escaping () -> Void
    ) {
        self.version = version
        self.build = build
        self.preferences = preferences
        self.onPrivateReceiptsChange = onPrivateReceiptsChange
        self.onSignOut = onSignOut
        _privateReceipts = State(initialValue: preferences.privateReceipts)
    }

    public var body: some View {
        List {
            Section("Account") {
                Button("Sign out", role: .destructive) { confirmingSignOut = true }
                    .accessibilityIdentifier("sign-out")
            }
            Section {
                Toggle("Private read receipts", isOn: $privateReceipts)
                    .accessibilityIdentifier("private-receipts")
                    .onChange(of: privateReceipts) { _, value in
                        preferences.privateReceipts = value
                        onPrivateReceiptsChange(value)
                    }
            } header: {
                Text("Privacy")
            } footer: {
                Text("When on, other people in a room can't see that you read their messages. Your own devices still stay in sync. Applies to receipts sent from now on.")
            }
            Section("About") {
                LabeledContent("Version", value: "\(version) (\(build))")
                NavigationLink("Acknowledgements") { AcknowledgementsView() }
                    .accessibilityIdentifier("acknowledgements")
            }
        }
        .navigationTitle("Settings")
        .confirmationDialog("Sign out of Halo?", isPresented: $confirmingSignOut, titleVisibility: .visible) {
            Button("Sign out", role: .destructive, action: onSignOut)
            Button("Cancel", role: .cancel) {}
        }
    }
}

/// The open-source components Halo ships and their licences, searchable.
public struct AcknowledgementsView: View {
    @State private var query = ""
    @State private var entries: [Acknowledgement] = []

    public init() {}

    public var body: some View {
        List {
            Section {
                Text("Halo is built on the Matrix Rust SDK and the open-source components below.").font(.footnote).foregroundStyle(.secondary)
            }
            Section("\(Acknowledgements.filter(entries, query: query).count) components") {
                ForEach(Acknowledgements.filter(entries, query: query)) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(entry.name) \(entry.version)")
                        Text(entry.license).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Acknowledgements")
        .searchable(text: $query)
        .task { if entries.isEmpty { entries = Acknowledgements.bundled() } }
    }
}
#endif
