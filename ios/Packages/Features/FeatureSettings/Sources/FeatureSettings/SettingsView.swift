#if canImport(SwiftUI)
import SwiftUI

/// The account's media preview setting as the Settings screen offers it (MEDIA_ATTACHMENTS FR-7).
public enum MediaPreviewChoice: String, CaseIterable, Sendable, Identifiable {
    case always = "Always", privateRoomsOnly = "In private rooms only", never = "Never"
    public var id: String { rawValue }
}

/// Settings v1 (docs/features/SETTINGS.md): account, privacy, about and the acknowledgements. The other sections arrive with their features.
public struct SettingsView: View {
    private let version: String
    private let build: String
    private let onSignOut: () -> Void
    private let preferences: AppPreferences
    private let onPrivateReceiptsChange: (Bool) -> Void
    private let loadMediaPreviews: (@Sendable () async -> MediaPreviewChoice)?
    private let saveMediaPreviews: (@Sendable (MediaPreviewChoice) async -> Bool)?
    @State private var mediaPreviews: MediaPreviewChoice = .always
    @State private var mediaPreviewsLoaded = false
    @State private var mediaPreviewsFailed = false
    @State private var confirmingSignOut = false
    @State private var privateReceipts: Bool

    /// `onPrivateReceiptsChange` applies a changed receipt privacy to the running app (the preference itself is stored here).
    public init(
        version: String, build: String, preferences: AppPreferences = AppPreferences(),
        onPrivateReceiptsChange: @escaping (Bool) -> Void = { _ in },
        loadMediaPreviews: (@Sendable () async -> MediaPreviewChoice)? = nil,
        saveMediaPreviews: (@Sendable (MediaPreviewChoice) async -> Bool)? = nil, onSignOut: @escaping () -> Void
    ) {
        self.loadMediaPreviews = loadMediaPreviews
        self.saveMediaPreviews = saveMediaPreviews
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
            if loadMediaPreviews != nil, saveMediaPreviews != nil {
                Section {
                    Picker("Show photos", selection: $mediaPreviews) {
                        ForEach(MediaPreviewChoice.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .accessibilityIdentifier("media-previews")
                    .disabled(!mediaPreviewsLoaded)
                    .onChange(of: mediaPreviews) { old, new in
                        guard mediaPreviewsLoaded, old != new, let saveMediaPreviews else { return }
                        Task {
                            if await saveMediaPreviews(new) { mediaPreviewsFailed = false } else {
                                mediaPreviewsFailed = true
                                mediaPreviewsLoaded = false  // the revert below must not save again
                                mediaPreviews = old
                                mediaPreviewsLoaded = true
                            }
                        }
                    }
                } header: {
                    Text("Media")
                } footer: {
                    Text(mediaPreviewsFailed ? "That couldn't be saved. Check your connection and try again." : "Photos that aren't shown wait for a tap. Applies to rooms you open from now on, on all your devices.")
                }
                .task {
                    guard let loadMediaPreviews, !mediaPreviewsLoaded else { return }
                    mediaPreviews = await loadMediaPreviews()
                    mediaPreviewsLoaded = true
                }
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
