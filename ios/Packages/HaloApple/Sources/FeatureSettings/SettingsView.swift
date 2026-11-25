#if canImport(SwiftUI)
import HaloDesignSystem
import SwiftUI

/// The account's media preview setting as the Settings screen offers it (MEDIA_ATTACHMENTS FR-7).
public enum MediaPreviewChoice: String, CaseIterable, Sendable, Identifiable {
    case always = "Always", privateRoomsOnly = "In private rooms only", never = "Never"
    public var id: String { rawValue }
}

/// Settings v1 (docs/features/SETTINGS.md): account, privacy, about and the acknowledgements. The other sections arrive with their features.
/// "Verify this device" in Settings → Security: shown while the device needs the recovery key; the app supplies the screen.
public struct VerifyDeviceAction {
    public let isNeeded: @MainActor () -> Bool
    public let makeView: @MainActor () -> AnyView

    public init(isNeeded: @escaping @MainActor () -> Bool, makeView: @escaping @MainActor () -> AnyView) {
        self.isNeeded = isNeeded
        self.makeView = makeView
    }
}

/// Configuration bundle for `SettingsView` (TD-10: replaces the 25-closure initializer with a model factory).
public struct SettingsConfiguration {
    public let version: String
    public let build: String
    public let preferences: AppPreferences
    public let onPrivateReceiptsChange: (Bool) -> Void
    public let onPreferencesChanged: (@MainActor () -> Void)?
    public let saveBotSenders: (@Sendable (_ old: [String], _ new: [String]) async -> [String]?)?
    public let loadMediaPreviews: (@Sendable () async -> MediaPreviewChoice)?
    public let saveMediaPreviews: (@Sendable (MediaPreviewChoice) async -> Bool)?
    public let makeProfileView: (@MainActor () -> AnyView)?
    public let stickerPacks: StickerPackSettingsActions?
    public let onOpenStickers: (@MainActor () -> Void)?
    public let devices: DevicesSettingsActions?
    public let changePassword: ChangePasswordActions?
    public let verifyDevice: VerifyDeviceAction?
    public let diagnostics: (@Sendable () async -> String)?
    public let exportDiagnosticsZip: (@Sendable () async -> URL?)?
    public let reconcile: (@Sendable () async -> Void)?
    public let unexplainedAuditCount: (@Sendable () async -> Int?)?
    public let storageSizes: (@Sendable () async -> [StorageSize])?
    public let clearCache: (@Sendable () async -> Bool)?
    public let searchIndex: SearchIndexSettingsActions?
    public let security: (@MainActor () -> [StorageSize])?
    public let setUpRecovery: (@MainActor () async -> Result<String, SettingsMessage>)?
    public let replaceRecovery: (@MainActor () async -> Result<String, SettingsMessage>)?
    public let notificationDefaults: NotificationDefaultsActions?
    public let notificationStatus: (@Sendable () async -> String)?
    public let openSystemSettings: (() -> Void)?
    public let onSignOut: () -> Void

    public init(
        version: String,
        build: String,
        preferences: AppPreferences = AppPreferences(),
        onPrivateReceiptsChange: @escaping (Bool) -> Void = { _ in },
        onPreferencesChanged: (@MainActor () -> Void)? = nil,
        saveBotSenders: (@Sendable (_ old: [String], _ new: [String]) async -> [String]?)? = nil,
        loadMediaPreviews: (@Sendable () async -> MediaPreviewChoice)? = nil,
        saveMediaPreviews: (@Sendable (MediaPreviewChoice) async -> Bool)? = nil,
        makeProfileView: (@MainActor () -> AnyView)? = nil,
        stickerPacks: StickerPackSettingsActions? = nil,
        onOpenStickers: (@MainActor () -> Void)? = nil,
        devices: DevicesSettingsActions? = nil,
        changePassword: ChangePasswordActions? = nil,
        verifyDevice: VerifyDeviceAction? = nil,
        diagnostics: (@Sendable () async -> String)? = nil,
        exportDiagnosticsZip: (@Sendable () async -> URL?)? = nil,
        reconcile: (@Sendable () async -> Void)? = nil,
        unexplainedAuditCount: (@Sendable () async -> Int?)? = nil,
        storageSizes: (@Sendable () async -> [StorageSize])? = nil,
        clearCache: (@Sendable () async -> Bool)? = nil,
        searchIndex: SearchIndexSettingsActions? = nil,
        security: (@MainActor () -> [StorageSize])? = nil,
        setUpRecovery: (@MainActor () async -> Result<String, SettingsMessage>)? = nil,
        replaceRecovery: (@MainActor () async -> Result<String, SettingsMessage>)? = nil,
        notificationDefaults: NotificationDefaultsActions? = nil,
        notificationStatus: (@Sendable () async -> String)? = nil,
        openSystemSettings: (() -> Void)? = nil,
        onSignOut: @escaping () -> Void
    ) {
        self.version = version
        self.build = build
        self.preferences = preferences
        self.onPrivateReceiptsChange = onPrivateReceiptsChange
        self.onPreferencesChanged = onPreferencesChanged
        self.saveBotSenders = saveBotSenders
        self.loadMediaPreviews = loadMediaPreviews
        self.saveMediaPreviews = saveMediaPreviews
        self.makeProfileView = makeProfileView
        self.stickerPacks = stickerPacks
        self.onOpenStickers = onOpenStickers
        self.devices = devices
        self.changePassword = changePassword
        self.verifyDevice = verifyDevice
        self.diagnostics = diagnostics
        self.exportDiagnosticsZip = exportDiagnosticsZip
        self.reconcile = reconcile
        self.unexplainedAuditCount = unexplainedAuditCount
        self.storageSizes = storageSizes
        self.clearCache = clearCache
        self.searchIndex = searchIndex
        self.security = security
        self.setUpRecovery = setUpRecovery
        self.replaceRecovery = replaceRecovery
        self.notificationDefaults = notificationDefaults
        self.notificationStatus = notificationStatus
        self.openSystemSettings = openSystemSettings
        self.onSignOut = onSignOut
    }
}

public struct SettingsView: View {
    private let config: SettingsConfiguration
    private var version: String { config.version }
    private var build: String { config.build }
    private var onSignOut: () -> Void { config.onSignOut }
    private var preferences: AppPreferences { config.preferences }
    private var onPrivateReceiptsChange: (Bool) -> Void { config.onPrivateReceiptsChange }
    private var saveBotSenders: (@Sendable (_ old: [String], _ new: [String]) async -> [String]?)? { config.saveBotSenders }
    private var loadMediaPreviews: (@Sendable () async -> MediaPreviewChoice)? { config.loadMediaPreviews }
    private var saveMediaPreviews: (@Sendable (MediaPreviewChoice) async -> Bool)? { config.saveMediaPreviews }
    private var diagnostics: (@Sendable () async -> String)? { config.diagnostics }
    private var exportDiagnosticsZip: (@Sendable () async -> URL?)? { config.exportDiagnosticsZip }
    private var reconcile: (@Sendable () async -> Void)? { config.reconcile }
    private var unexplainedAuditCount: (@Sendable () async -> Int?)? { config.unexplainedAuditCount }
    @State private var unexplainedCount: Int?
    private var makeProfileView: (@MainActor () -> AnyView)? { config.makeProfileView }
    private var stickerPacks: StickerPackSettingsActions? { config.stickerPacks }
    private var devices: DevicesSettingsActions? { config.devices }
    private var changePassword: ChangePasswordActions? { config.changePassword }
    @State private var canChangePassword = false
    @State private var confirmingNewRecoveryKey = false
    @State private var changingRecoveryKey = false
    private var verifyDevice: VerifyDeviceAction? { config.verifyDevice }
    @State private var verifying = false
    private var security: (@MainActor () -> [StorageSize])? { config.security }
    private var setUpRecovery: (@MainActor () async -> Result<String, SettingsMessage>)? { config.setUpRecovery }
    @State private var recoveryFailure: SettingsMessage?
    private var replaceRecovery: (@MainActor () async -> Result<String, SettingsMessage>)? { config.replaceRecovery }
    @State private var newRecoveryKey: String?
    @State private var settingUpRecovery = false
    private var notificationDefaults: NotificationDefaultsActions? { config.notificationDefaults }
    private var notificationStatus: (@Sendable () async -> String)? { config.notificationStatus }
    private var openSystemSettings: (() -> Void)? { config.openSystemSettings }
    @State private var notifications = ""
    private var storageSizes: (@Sendable () async -> [StorageSize])? { config.storageSizes }
    private var clearCache: (@Sendable () async -> Bool)? { config.clearCache }
    @State private var storage: [StorageSize] = []
    @State private var clearingCache = false
    @AppStorage(AppPreferences.appearanceKey) private var appearance = Appearance.system.rawValue
    @State private var mediaPreviews: MediaPreviewChoice = .always
    @State private var mediaPreviewsLoaded = false
    @State private var mediaPreviewsFailed = false
    @State private var confirmingSignOut = false
    @State private var showingFeedback = false
    @State private var showingWhatsNew = false
    @State private var privateReceipts: Bool
    @State private var sendTypingNotices: Bool
    @State private var privacyBlur: Bool
    @State private var chatsInSystemSearch: Bool
    @State private var followFocusFilter: Bool

    public init(config: SettingsConfiguration) {
        self.config = config
        _privateReceipts = State(initialValue: config.preferences.privateReceipts)
        _sendTypingNotices = State(initialValue: config.preferences.sendTypingNotices)
        _privacyBlur = State(initialValue: config.preferences.privacyBlur)
        _chatsInSystemSearch = State(initialValue: config.preferences.chatsInSystemSearch)
        _followFocusFilter = State(initialValue: config.preferences.followFocusFilter)
    }

    public var body: some View {
        List {
            if let makeProfileView {
                Section("Account") {
                    NavigationLink { makeProfileView() } label: { Label("Profile", systemImage: "person.crop.circle") }
                        .accessibilityIdentifier("profile")
                    if let devices {
                        NavigationLink { DevicesSettingsView(actions: devices) } label: { Label("Sessions", systemImage: "iphone.and.arrow.forward") }
                            .accessibilityIdentifier("sessions")
                    }
                    if let changePassword, canChangePassword {
                        NavigationLink { ChangePasswordView(actions: changePassword) } label: { Label("Change password", systemImage: "key") }
                            .accessibilityIdentifier("change-password")
                    }
                }
            }
            if let onOpenStickers = config.onOpenStickers {
                Section("Stickers") {
                    Button(action: onOpenStickers) {
                        Label("Sticker library", systemImage: "sparkles.rectangle.stack")
                    }
                    .accessibilityIdentifier("settings-sticker-library")
                }
            }
            Section {
                Toggle("Private read receipts", isOn: $privateReceipts)
                    .accessibilityIdentifier("private-receipts")
                    .onChange(of: privateReceipts) { _, value in
                        preferences.privateReceipts = value
                        onPrivateReceiptsChange(value)
                        config.onPreferencesChanged?()
                    }
                Toggle("Typing notices", isOn: $sendTypingNotices)
                    .accessibilityIdentifier("typing-notices")
                    .onChange(of: sendTypingNotices) { _, value in
                        preferences.sendTypingNotices = value
                    }
                Toggle("Hide content in app switcher", isOn: $privacyBlur)
                    .accessibilityIdentifier("privacy-blur")
                    .onChange(of: privacyBlur) { _, value in
                        preferences.privacyBlur = value
                        config.onPreferencesChanged?()
                    }
                Toggle("Chats in Siri and Spotlight", isOn: $chatsInSystemSearch)
                    .accessibilityIdentifier("chats-in-system-search")
                    .onChange(of: chatsInSystemSearch) { _, value in
                        preferences.chatsInSystemSearch = value
                        config.onPreferencesChanged?()
                    }
            } header: {
                Text("Privacy")
            } footer: {
                Text("Private read receipts hide that you read messages from others while keeping your devices in sync (applies from now on). Typing notices let others see when you're writing. App-switcher blur hides your chats when switching apps. Chats in Siri and Spotlight lets you open a chat by name; the chat names (not messages) are shared with the system and removed when you turn it off or sign out.")
            }
            Section {
                Toggle("Follow Focus filters", isOn: $followFocusFilter)
                    .accessibilityIdentifier("follow-focus-filter")
                    .onChange(of: followFocusFilter) { _, value in
                        preferences.followFocusFilter = value
                        config.onPreferencesChanged?()
                    }
            } header: {
                Text("Focus")
            } footer: {
                Text("When on, a Focus with a Halo filter (Settings → Focus → Halo) shows only the chats it picks while that Focus is on. When off, Halo always shows every chat.")
            }
            Section("Appearance") {
                Picker("Theme", selection: $appearance) {
                    ForEach(Appearance.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .accessibilityIdentifier("appearance")
                // The picker stores to UserDefaults; the root view reads `PreferencesStore`, so refresh it.
                .onChange(of: appearance) { config.onPreferencesChanged?() }
            }
            if config.onOpenStickers == nil, let stickerPacks {
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
                    if let verifyDevice, verifyDevice.isNeeded() {
                        Button { verifying = true } label: {
                            HStack {
                                Label("Verify this device", systemImage: "lock.shield")
                                Spacer()
                                Circle().fill(HaloColor.warning).frame(width: 10, height: 10)
                            }
                        }
                        .accessibilityIdentifier("verify-device")
                    }
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
                    if replaceRecovery != nil, security().contains(where: { $0.name == "Recovery key" && $0.text.hasPrefix("On") }) {
                        let deviceHasKey = security().contains(where: { $0.name == "Recovery key" && $0.text == "On" })
                        Button { confirmingNewRecoveryKey = true } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(changingRecoveryKey ? "Creating a new key…" : "Change recovery key")
                                if !deviceHasKey {
                                    Text("Verify this device first: only a verified device can replace the key.")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .disabled(!deviceHasKey || changingRecoveryKey)
                        .accessibilityIdentifier("change-recovery-key")
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
                    if let clearCache {
                        Button(clearingCache ? "Clearing cache…" : "Clear media cache") {
                            clearingCache = true
                            Task {
                                _ = await clearCache()
                                storage = await storageSizes()
                                clearingCache = false
                            }
                        }
                        .disabled(clearingCache)
                        .accessibilityIdentifier("clear-cache")
                    }
                } header: {
                    Text("Storage")
                } footer: {
                    Text("What Halo keeps on this device: the synced messages and keys, and its own settings database.")
                }
                .task { storage = await storageSizes() }
            }
            if let searchIndex = config.searchIndex { SearchIndexSettingsSection(actions: searchIndex) }
            if let diagnostics {
                Section {
                    NavigationLink { DiagnosticsView(report: diagnostics, exportZip: exportDiagnosticsZip, reconcile: reconcile) } label: {
                        HStack {
                            Label("Diagnostics", systemImage: "stethoscope")
                            Spacer()
                            if let count = unexplainedCount {
                                if count > 0 {
                                    Text("\(count) unexplained")
                                        .font(HaloTypography.captionEmphasis)
                                        .padding(.horizontal, 7).padding(.vertical, HaloSpacing.xxs)
                                        .background(HaloColor.attention, in: Capsule())
                                        .foregroundStyle(HaloColor.onAttention)
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
                Button { showingWhatsNew = true } label: { Label("What's New", systemImage: "sparkles") }
                    .accessibilityIdentifier("whats-new")
                Button { showingFeedback = true } label: { Label("Send feedback", systemImage: "envelope") }
                    .accessibilityIdentifier("send-feedback")
                if let privacyURL = URL(string: "https://halo.mbm.one/privacy") {
                    Link(destination: privacyURL) { Label("Privacy policy", systemImage: "hand.raised") }
                }
                if let supportURL = URL(string: "https://halo.mbm.one/support") {
                    Link(destination: supportURL) { Label("Support", systemImage: "questionmark.circle") }
                }
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
        .scrollEdgeEffectHidden(true, for: .top)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("Settings")
                    .font(HaloTypography.headline)
                    .foregroundStyle(HaloColor.textPrimary)
                    .lineLimit(1)
                    .padding(.horizontal, HaloSpacing.m)
                    .frame(height: 44)
                    .glassEffect(.regular, in: .capsule)
            }
            .sharedBackgroundVisibility(.hidden)
        }
        .task { if let changePassword { canChangePassword = await changePassword.isAvailable() } }
        .sheet(isPresented: $verifying) { verifyDevice?.makeView() }
        .onChange(of: verifyDevice?.isNeeded() ?? false) { _, needed in if !needed { verifying = false } }
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
        .alert("Change the recovery key?", isPresented: $confirmingNewRecoveryKey) {
            Button("Create a new key", role: .destructive) {
                guard let replaceRecovery else { return }
                changingRecoveryKey = true
                Task {
                    switch await replaceRecovery() {
                    case .success(let key): newRecoveryKey = key
                    case .failure(let message): recoveryFailure = SettingsMessage(message.text)
                    }
                    changingRecoveryKey = false
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your current key will stop working, and messages only in the old backup can't be restored with the new key. Save the new key as soon as it appears.")
        }
        .alert("Sign out of Halo?", isPresented: $confirmingSignOut) {
            Button("Sign out", role: .destructive, action: onSignOut)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Synced data on this device will be removed. You can sign back in anytime.")
        }
        .sheet(isPresented: $showingFeedback) {
            FeedbackSheetView(version: version, build: build, exportDiagnosticsZip: exportDiagnosticsZip)
        }
        .sheet(isPresented: $showingWhatsNew) {
            WhatsNewView(version: version) { showingWhatsNew = false }
        }
    }
}

/// Settings → Bots: the accounts whose recognised messages show as cards (synced via `one.mbm.halo.bot_allowlist`).
private struct BotsSection: View {
    @State private var editor: BotListEditor
    @State private var newBot = ""

    init(preferences: AppPreferences, sync: (@Sendable (_ old: [String], _ new: [String]) async -> [String]?)? = nil) {
        _editor = State(initialValue: BotListEditor(senders: preferences.botSenders, store: { preferences.botSenders = $0 }, sync: sync))
    }

    static func looksLikeUserID(_ text: String) -> Bool {
        text.hasPrefix("@") && text.contains(":") && !text.contains(" ") && text.count > 3 && !text.hasSuffix(":")
    }

    var body: some View {
        Section {
            ForEach(editor.senders, id: \.self) { Text($0).font(.callout) }
                .onDelete { editor.remove(atOffsets: $0) }
            HStack {
                field
                Button("Add", action: add).buttonStyle(.borderless).disabled(!canAdd)
            }
        } header: {
            Text("Bots")
        } footer: {
            Text(editor.syncFailed
                ? "Saved on this device, but couldn't sync to your account. Check your connection and try again."
                : "Messages from these accounts that Halo recognises are shown as cards, with the original one tap away. Synced across your Halo devices.")
        }
    }

    private var trimmed: String { newBot.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canAdd: Bool { Self.looksLikeUserID(trimmed) && !editor.senders.contains(trimmed) }

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
        editor.add(trimmed)
        newBot = ""
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

/// A plain-text status report (versions, device, read-state audit counts) to read or share, plus manual unread reconciliation
/// and `.zip` diagnostics archive export (ROOM_LIST FR-8, SETTINGS §3, LOGGING_AND_DIAGNOSTICS §3).
public struct DiagnosticsView: View {
    private let report: @Sendable () async -> String
    private let exportZip: (@Sendable () async -> URL?)?
    private let reconcile: (@Sendable () async -> Void)?
    @State private var text = ""
    @State private var zipURL: URL?
    @State private var reconciling = false
    @State private var reconciled = false
    @State private var copied = false

    public init(
        report: @escaping @Sendable () async -> String,
        exportZip: (@Sendable () async -> URL?)? = nil,
        reconcile: (@Sendable () async -> Void)? = nil
    ) {
        self.report = report
        self.exportZip = exportZip
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
                if let zipURL {
                    ShareLink(item: zipURL) {
                        Label("Export diagnostics (.zip)", systemImage: "archivebox")
                    }
                    .accessibilityIdentifier("export-diagnostics-zip")
                }
            }
            if let reconcile {
                Section {
                    Button {
                        reconciling = true
                        reconciled = false
                        Task {
                            await reconcile()
                            text = await report()
                            if let exportZip { zipURL = await exportZip() }
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
            if let zipURL {
                ToolbarItem(placement: .primaryAction) { ShareLink(item: zipURL) }
            } else if !text.isEmpty {
                ToolbarItem(placement: .primaryAction) { ShareLink(item: text) }
            }
        }
        .task {
            text = await report()
            if let exportZip { zipURL = await exportZip() }
        }
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
        .scrollEdgeEffectHidden(true, for: .top)
        .overlay {
            if !rustCrates.isEmpty, !hasMatches { ContentUnavailableView.search(text: query) }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("Acknowledgements")
                    .font(HaloTypography.headline)
                    .foregroundStyle(HaloColor.textPrimary)
                    .lineLimit(1)
                    .padding(.horizontal, HaloSpacing.m)
                    .frame(height: 44)
                    .glassEffect(.regular, in: .capsule)
            }
            .sharedBackgroundVisibility(.hidden)
        }
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
