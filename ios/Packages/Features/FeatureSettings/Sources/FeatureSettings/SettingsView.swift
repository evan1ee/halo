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
    private let saveBotSenders: (@Sendable ([String]) async -> Bool)?
    private let loadMediaPreviews: (@Sendable () async -> MediaPreviewChoice)?
    private let saveMediaPreviews: (@Sendable (MediaPreviewChoice) async -> Bool)?
    private let diagnostics: (@Sendable () async -> String)?
    private let reconcile: (@Sendable () async -> Void)?
    private let unexplainedAuditCount: (@Sendable () async -> Int?)?
    @State private var unexplainedCount: Int?
    private let profile: ProfileSettingsActions?
    private let stickerPacks: StickerPackSettingsActions?
    private let devices: DevicesSettingsActions?
    private let security: (@MainActor () -> [StorageSize])?
    private let setUpRecovery: (@MainActor () async -> Result<String, SettingsMessage>)?
    @State private var recoveryFailure: SettingsMessage?
    private let replaceRecovery: (@MainActor () async -> Result<String, SettingsMessage>)?
    @State private var newRecoveryKey: String?
    @State private var settingUpRecovery = false
    private let notificationDefaults: NotificationDefaultsActions?
    private let notificationStatus: (@Sendable () async -> String)?
    private let openSystemSettings: (() -> Void)?
    @State private var notifications = ""
    private let storageSizes: (@Sendable () async -> [StorageSize])?
    @State private var storage: [StorageSize] = []
    @AppStorage(AppPreferences.appearanceKey) private var appearance = Appearance.system.rawValue
    @State private var mediaPreviews: MediaPreviewChoice = .always
    @State private var mediaPreviewsLoaded = false
    @State private var mediaPreviewsFailed = false
    @State private var confirmingSignOut = false
    @State private var privateReceipts: Bool
    @State private var sendTypingNotices: Bool

    /// `onPrivateReceiptsChange` applies a changed receipt privacy to the running app (the preference itself is stored here).
    public init(
        version: String, build: String, preferences: AppPreferences = AppPreferences(),
        onPrivateReceiptsChange: @escaping (Bool) -> Void = { _ in },
        saveBotSenders: (@Sendable ([String]) async -> Bool)? = nil,
        loadMediaPreviews: (@Sendable () async -> MediaPreviewChoice)? = nil,
        saveMediaPreviews: (@Sendable (MediaPreviewChoice) async -> Bool)? = nil,
        profile: ProfileSettingsActions? = nil, stickerPacks: StickerPackSettingsActions? = nil, devices: DevicesSettingsActions? = nil, diagnostics: (@Sendable () async -> String)? = nil,
        reconcile: (@Sendable () async -> Void)? = nil, unexplainedAuditCount: (@Sendable () async -> Int?)? = nil,
        storageSizes: (@Sendable () async -> [StorageSize])? = nil,
        security: (@MainActor () -> [StorageSize])? = nil, setUpRecovery: (@MainActor () async -> Result<String, SettingsMessage>)? = nil,
        replaceRecovery: (@MainActor () async -> Result<String, SettingsMessage>)? = nil, notificationDefaults: NotificationDefaultsActions? = nil, notificationStatus: (@Sendable () async -> String)? = nil, openSystemSettings: (() -> Void)? = nil, onSignOut: @escaping () -> Void
    ) {
        self.diagnostics = diagnostics
        self.reconcile = reconcile
        self.unexplainedAuditCount = unexplainedAuditCount
        self.profile = profile
        self.stickerPacks = stickerPacks
        self.devices = devices
        self.storageSizes = storageSizes
        self.notificationStatus = notificationStatus
        self.notificationDefaults = notificationDefaults
        self.security = security
        self.setUpRecovery = setUpRecovery
        self.replaceRecovery = replaceRecovery
        self.openSystemSettings = openSystemSettings
        self.loadMediaPreviews = loadMediaPreviews
        self.saveMediaPreviews = saveMediaPreviews
        self.version = version
        self.build = build
        self.preferences = preferences
        self.onPrivateReceiptsChange = onPrivateReceiptsChange
        self.saveBotSenders = saveBotSenders
        self.onSignOut = onSignOut
        _privateReceipts = State(initialValue: preferences.privateReceipts)
        _sendTypingNotices = State(initialValue: preferences.sendTypingNotices)
    }

    public var body: some View {
        List {
            if let profile {
                Section("Account") {
                    NavigationLink { ProfileSettingsView(actions: profile) } label: { Label("Profile", systemImage: "person.crop.circle") }
                        .accessibilityIdentifier("profile")
                    if let devices {
                        NavigationLink { DevicesSettingsView(actions: devices) } label: { Label("Sessions", systemImage: "iphone.and.arrow.forward") }
                            .accessibilityIdentifier("sessions")
                    }
                }
            }
            Section {
                Toggle("Private read receipts", isOn: $privateReceipts)
                    .accessibilityIdentifier("private-receipts")
                    .onChange(of: privateReceipts) { _, value in
                        preferences.privateReceipts = value
                        onPrivateReceiptsChange(value)
                    }
                Toggle("Typing notices", isOn: $sendTypingNotices)
                    .accessibilityIdentifier("typing-notices")
                    .onChange(of: sendTypingNotices) { _, value in
                        preferences.sendTypingNotices = value
                    }
            } header: {
                Text("Privacy")
            } footer: {
                Text("Private read receipts hide that you read messages from others while keeping your devices in sync (applies from now on). Typing notices let others see when you're writing.")
            }
            Section("Appearance") {
                Picker("Theme", selection: $appearance) {
                    ForEach(Appearance.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .accessibilityIdentifier("appearance")
            }
            if let stickerPacks {
                Section("Stickers") {
                    NavigationLink { StickerPackSettingsView(actions: stickerPacks) } label: { Label("Sticker packs", systemImage: "face.smiling") }
                }
            }
            BotsSection(preferences: preferences, sync: saveBotSenders)
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
            if let security {
                Section {
                    ForEach(security()) { LabeledContent($0.name, value: $0.text) }
                    if let setUpRecovery, security().contains(where: { $0.name == "Recovery key" && $0.text == "Not set up" }) {
                        Button(settingUpRecovery ? "Setting up…" : "Set up recovery key") {
                            settingUpRecovery = true
                            Task {
                                switch await setUpRecovery() {
                                case .success(let key): newRecoveryKey = key
                                case .failure(let message): recoveryFailure = message
                                }
                                settingUpRecovery = false
                            }
                        }
                        .disabled(settingUpRecovery)
                        .accessibilityIdentifier("set-up-recovery")
                    }
                } header: {
                    Text("Security")
                } footer: {
                    Text("A verified device can read your encrypted history. The recovery key restores it on a new device.")
                }
            }
            if let notificationStatus {
                Section {
                    LabeledContent("Notifications", value: notifications)
                    if let openSystemSettings { Button("Open iOS Settings", action: openSystemSettings) }
                } header: {
                    Text("Notifications")
                } footer: {
                    Text("Alerts, sounds and the badge are allowed or turned off in iOS Settings.")
                }
                .task { notifications = await notificationStatus() }
            }
            if let notificationDefaults { NotificationDefaultsSection(actions: notificationDefaults) }
            if let storageSizes {
                Section {
                    ForEach(storage) { LabeledContent($0.name, value: $0.formatted) }
                } header: {
                    Text("Storage")
                } footer: {
                    Text("What Halo keeps on this device: the synced messages and keys, and its own settings database.")
                }
                .task { storage = await storageSizes() }
            }
            if let diagnostics {
                Section {
                    NavigationLink { DiagnosticsView(report: diagnostics, reconcile: reconcile) } label: {
                        HStack {
                            Label("Diagnostics", systemImage: "stethoscope")
                            Spacer()
                            if let count = unexplainedCount {
                                if count > 0 {
                                    Text("\(count) unexplained")
                                        .font(.caption.bold())
                                        .padding(.horizontal, 7).padding(.vertical, 2)
                                        .background(.orange, in: Capsule())
                                        .foregroundStyle(.white)
                                } else {
                                    Text("0 unexplained").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .accessibilityIdentifier("diagnostics")
                } footer: {
                    Text("A short report you can share when something looks wrong. It holds no messages, names or account IDs.")
                }
                .task {
                    if let unexplainedAuditCount { unexplainedCount = await unexplainedAuditCount() }
                }
            }
            Section("About") {
                LabeledContent("Version", value: "\(version) (\(build))")
                NavigationLink { AcknowledgementsView() } label: { Label("Acknowledgements", systemImage: "doc.text") }
                    .accessibilityIdentifier("acknowledgements")
            }
            // Last and on its own, away from everyday settings, so it isn't tapped by accident (it still asks first).
            Section {
                Button("Sign out", role: .destructive) { confirmingSignOut = true }
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("sign-out")
            }
        }
        .navigationTitle("Settings")
        .alert("Recovery key", isPresented: Binding(get: { recoveryFailure != nil }, set: { if !$0 { recoveryFailure = nil } })) {
            if recoveryFailure?.offersReplace == true, let replaceRecovery {
                Button("Replace backup", role: .destructive) {
                    Task {
                        switch await replaceRecovery() {
                        case .success(let key): newRecoveryKey = key
                        case .failure(let message): recoveryFailure = SettingsMessage(message.text)
                        }
                    }
                }
            }
            Button(recoveryFailure?.offersReplace == true ? "Cancel" : "OK", role: .cancel) {}
        } message: { Text(recoveryFailure?.text ?? "") }
        .sheet(item: Binding(get: { newRecoveryKey.map(RecoveryKeyItem.init) }, set: { if $0 == nil { newRecoveryKey = nil } })) { item in
            RecoveryKeySheet(key: item.key) { newRecoveryKey = nil }
        }
        .confirmationDialog("Sign out of Halo?", isPresented: $confirmingSignOut, titleVisibility: .visible) {
            Button("Sign out", role: .destructive, action: onSignOut)
            Button("Cancel", role: .cancel) {}
        }
    }
}

/// Settings → Bots: the accounts whose recognised messages show as cards (synced via `one.mbm.halo.bot_allowlist`).
private struct BotsSection: View {
    let preferences: AppPreferences
    let sync: (@Sendable ([String]) async -> Bool)?
    @State private var senders: [String]
    @State private var newBot = ""
    @State private var syncFailed = false

    init(preferences: AppPreferences, sync: (@Sendable ([String]) async -> Bool)? = nil) {
        self.preferences = preferences
        self.sync = sync
        _senders = State(initialValue: preferences.botSenders)
    }

    static func looksLikeUserID(_ text: String) -> Bool {
        text.hasPrefix("@") && text.contains(":") && !text.contains(" ") && text.count > 3 && !text.hasSuffix(":")
    }

    var body: some View {
        Section {
            ForEach(senders, id: \.self) { Text($0).font(.callout) }
                .onDelete { offsets in
                    senders.remove(atOffsets: offsets)
                    persist(senders)
                }
            HStack {
                field
                Button("Add", action: add).buttonStyle(.borderless).disabled(!canAdd)
            }
        } header: {
            Text("Bots")
        } footer: {
            Text(syncFailed
                ? "Saved on this device, but couldn't sync to your account. Check your connection and try again."
                : "Messages from these accounts that Halo recognises are shown as cards, with the original one tap away. Synced across your Halo devices.")
        }
    }

    private var trimmed: String { newBot.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canAdd: Bool { Self.looksLikeUserID(trimmed) && !senders.contains(trimmed) }

    @ViewBuilder private var field: some View {
        #if os(iOS)
        TextField("@bot:server.org", text: $newBot)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .submitLabel(.done)
            .onSubmit(add)
        #else
        TextField("@bot:server.org", text: $newBot).onSubmit(add)
        #endif
    }

    private func add() {
        guard canAdd else { return }
        senders.append(trimmed)
        persist(senders)
        newBot = ""
    }

    private func persist(_ list: [String]) {
        preferences.botSenders = list
        guard let sync else { return }
        Task { syncFailed = !(await sync(list)) }
    }
}

/// A user-facing failure text passed from the app into Settings.
public struct SettingsMessage: Error, Sendable, Equatable {
    public let text: String
    /// Offer "Replace" after this message (an existing key backup would be lost).
    public let offersReplace: Bool
    public init(_ text: String, offersReplace: Bool = false) { self.text = text; self.offersReplace = offersReplace }
}

private struct RecoveryKeyItem: Identifiable { let key: String; var id: String { key } }

/// Shows a new recovery key once. It lives only in this sheet's state; closing the sheet drops it.
private struct RecoveryKeySheet: View {
    let key: String
    let done: () -> Void
    @State private var copied = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("Your recovery key").font(.title2.bold())
                Text("Keep this key somewhere safe, like a password manager. It is the only way to read your encrypted history on a new device. Halo can't show it again.")
                Text(key)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityIdentifier("recovery-key")
                HStack(spacing: 16) {
                    #if canImport(UIKit)
                    Button {
                        UIPasteboard.general.string = key
                        copied = true
                    } label: {
                        Label(copied ? "Copied" : "Copy key", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    #endif
                    ShareLink("Share", item: key)
                }
                Spacer()
                Button { done() } label: { Text("I've saved it").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).controlSize(.large)
            }
            .padding()
        }
        .interactiveDismissDisabled()
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }
}

/// One name/value line of Settings → Storage or Security.
public struct StorageSize: Sendable, Identifiable, Equatable {
    public let name: String
    public let text: String
    public var id: String { name }
    public init(name: String, bytes: Int64) { self.init(name: name, text: ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) }
    public init(name: String, text: String) { self.name = name; self.text = text }
    public var formatted: String { text }
}

/// A plain-text status report (versions, device, read-state audit counts) to read or share, plus manual unread reconciliation (ROOM_LIST FR-8, SETTINGS §3).
public struct DiagnosticsView: View {
    private let report: @Sendable () async -> String
    private let reconcile: (@Sendable () async -> Void)?
    @State private var text = ""
    @State private var reconciling = false
    @State private var reconciled = false
    @State private var copied = false

    public init(report: @escaping @Sendable () async -> String, reconcile: (@Sendable () async -> Void)? = nil) {
        self.report = report
        self.reconcile = reconcile
    }

    public var body: some View {
        List {
            Section("Report") {
                Text(text.isEmpty ? "Collecting…" : text)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .accessibilityIdentifier("diagnostics-report")
                #if canImport(UIKit)
                Button {
                    UIPasteboard.general.string = text
                    copied = true
                } label: {
                    Label(copied ? "Copied" : "Copy report", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .disabled(text.isEmpty)
                #endif
            }
            if let reconcile {
                Section {
                    Button {
                        reconciling = true
                        reconciled = false
                        Task {
                            await reconcile()
                            text = await report()
                            reconciling = false
                            reconciled = true
                        }
                    } label: {
                        Label(reconciling ? "Reconciling…" : "Reconcile now", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(reconciling)
                    .accessibilityIdentifier("reconcile-now")
                } footer: {
                    Text(reconciled ? "Unread state and badge reconciled." : "Flushes pending read receipts and re-evaluates unread state and the app badge.")
                }
            }
        }
        .navigationTitle("Diagnostics")
        .toolbar {
            if !text.isEmpty { ToolbarItem(placement: .primaryAction) { ShareLink(item: text) } }
        }
        .task { text = await report() }
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }
}

/// The open-source components Halo ships and their licences, searchable.
public struct AcknowledgementsView: View {
    @State private var query = ""
    @State private var rustCrates: [Acknowledgement] = []

    public init() {}

    public var body: some View {
        let filteredSwift = Acknowledgements.filter(Acknowledgements.swiftPackages, query: query)
        let filteredRust = Acknowledgements.filter(rustCrates, query: query)
        let hasMatches = !filteredSwift.isEmpty || !filteredRust.isEmpty
        List {
            if hasMatches || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Section {
                    Text("Halo is built on the Matrix Rust SDK, GRDB and the open-source components below.").font(.footnote).foregroundStyle(.secondary)
                }
                if !filteredSwift.isEmpty {
                    Section("Swift packages (\(filteredSwift.count))") {
                        ForEach(filteredSwift) { row($0) }
                    }
                }
                if !filteredRust.isEmpty || rustCrates.isEmpty {
                    Section("Rust crates (\(filteredRust.count))") {
                        ForEach(filteredRust) { row($0) }
                    }
                }
            }
        }
        .overlay {
            if !rustCrates.isEmpty, !hasMatches { ContentUnavailableView.search(text: query) }
        }
        .navigationTitle("Acknowledgements")
        .searchable(text: $query)
        .task { if rustCrates.isEmpty { rustCrates = Acknowledgements.bundled() } }
    }

    private func row(_ entry: Acknowledgement) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(entry.name) \(entry.version)")
            Text(entry.license).font(.caption).foregroundStyle(.secondary)
        }
    }
}
#endif
