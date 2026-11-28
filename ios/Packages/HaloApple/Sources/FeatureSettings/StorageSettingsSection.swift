#if canImport(SwiftUI)
import Foundation
import HaloApplication
import HaloDesignSystem
import HaloDomain
import HaloFoundation
import Observation
import SwiftUI

/// Callbacks connecting Settings → Storage to `StorageCoordinator` (SETTINGS §3, D55, M20-13).
public struct StorageSettingsActions: Sendable {
    public let loadSizes: @Sendable () async throws(HaloError) -> StoreSizeBreakdown
    public let clearMediaCache: @Sendable () async throws(HaloError) -> MediaCacheClearResult
    public let applyRetention: @Sendable (MediaCacheRetention) async throws(HaloError) -> Void

    public init(
        loadSizes: @escaping @Sendable () async throws(HaloError) -> StoreSizeBreakdown,
        clearMediaCache: @escaping @Sendable () async throws(HaloError) -> MediaCacheClearResult,
        applyRetention: @escaping @Sendable (MediaCacheRetention) async throws(HaloError) -> Void
    ) {
        self.loadSizes = loadSizes
        self.clearMediaCache = clearMediaCache
        self.applyRetention = applyRetention
    }
}

/// View model for Settings → Storage: store size breakdown, media cache clearing, and D55 retention policy (M20-13).
@MainActor @Observable
public final class StorageSettingsViewModel {
    public enum LoadState: Equatable {
        case loading
        case loaded(StoreSizeBreakdown)
        case failed(String)
    }

    public private(set) var state: LoadState = .loading
    public private(set) var isClearing = false
    public private(set) var isUpdatingRetention = false
    public private(set) var statusMessage: String?
    public private(set) var errorMessage: String?

    public var retention: MediaCacheRetention {
        preferences.mediaCacheRetention
    }

    private let actions: StorageSettingsActions
    private let preferences: PreferencesStore

    public init(actions: StorageSettingsActions, preferences: PreferencesStore) {
        self.actions = actions
        self.preferences = preferences
    }

    public func load() async {
        state = .loading
        errorMessage = nil
        do {
            let breakdown = try await actions.loadSizes()
            state = .loaded(breakdown)
        } catch {
            state = .failed("Storage sizes couldn't be read.")
        }
    }

    /// Clears only cached media (never keys, drafts, or unsent messages; AC-SET-3) and updates the displayed sizes.
    public func clearMediaCache() async {
        guard !isClearing else { return }
        isClearing = true
        statusMessage = nil
        errorMessage = nil
        defer { isClearing = false }
        do {
            let result = try await actions.clearMediaCache()
            state = .loaded(result.breakdown)
            if result.freedBytes > 0 {
                statusMessage = "Cleared \(Self.formatBytes(result.freedBytes)) from the media cache."
            } else {
                statusMessage = "Media cache is already empty."
            }
        } catch {
            errorMessage = "The media cache couldn't be cleared. Try again."
        }
    }

    /// Persists and applies a new media cache retention policy (D55), reverting on failure.
    public func setRetention(_ next: MediaCacheRetention) async {
        let previous = preferences.mediaCacheRetention
        guard next != previous, !isUpdatingRetention else { return }
        isUpdatingRetention = true
        statusMessage = nil
        errorMessage = nil
        preferences.mediaCacheRetention = next
        defer { isUpdatingRetention = false }
        do {
            try await actions.applyRetention(next)
        } catch {
            preferences.mediaCacheRetention = previous
            errorMessage = "That retention setting couldn't be applied. Try again."
        }
    }

    public static func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .file)
    }
}

/// Settings → Storage section (SETTINGS §3, AC-SET-3, D55, M20-13).
public struct StorageSettingsSection: View {
    @State private var model: StorageSettingsViewModel
    @State private var confirmingClear = false
    @State private var selectedMaxSize: MediaCacheSizeLimit
    @State private var selectedExpiry: MediaCacheExpiry

    public init(actions: StorageSettingsActions, preferences: PreferencesStore) {
        _model = State(initialValue: StorageSettingsViewModel(actions: actions, preferences: preferences))
        _selectedMaxSize = State(initialValue: preferences.mediaCacheRetention.maxSize)
        _selectedExpiry = State(initialValue: preferences.mediaCacheRetention.expiry)
    }

    init(model: StorageSettingsViewModel) {
        _model = State(initialValue: model)
        _selectedMaxSize = State(initialValue: model.retention.maxSize)
        _selectedExpiry = State(initialValue: model.retention.expiry)
    }

    public var body: some View {
        Section {
            sectionRows
        } header: {
            Text("Storage")
        } footer: {
            Text(footerText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .task {
            if case .loading = model.state {
                await model.load()
            }
        }
        .onChange(of: model.retention) { _, updated in
            if selectedMaxSize != updated.maxSize { selectedMaxSize = updated.maxSize }
            if selectedExpiry != updated.expiry { selectedExpiry = updated.expiry }
        }
        .alert("Clear media cache?", isPresented: $confirmingClear) {
            Button("Clear cache", role: .destructive) {
                Task { await model.clearMediaCache() }
            }
            .accessibilityIdentifier("confirm-clear-cache")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Cached photos, videos and files will be removed and downloaded again when needed. Your encryption keys, drafts and unsent messages are never touched.")
        }
    }

    @ViewBuilder
    var sectionRows: some View {
        switch model.state {
        case .loading:
            HStack(spacing: HaloSpacing.s) {
                ProgressView()
                Text("Calculating storage…")
                    .font(HaloTypography.body)
                    .foregroundStyle(HaloColor.textSecondary)
            }
            .accessibilityIdentifier("storage-loading")
        case .failed(let message):
            VStack(alignment: .leading, spacing: HaloSpacing.xs) {
                Text(message)
                    .font(HaloTypography.body)
                    .foregroundStyle(HaloColor.danger)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try again") { Task { await model.load() } }
                    .font(HaloTypography.meta.weight(.medium))
                    .accessibilityIdentifier("storage-retry")
            }
        case .loaded(let breakdown):
            sizeRow(title: "Media cache", bytes: breakdown.mediaCacheBytes, id: "storage-media-cache")
            sizeRow(title: "Messages & room state", bytes: breakdown.messagesBytes, id: "storage-messages")
            sizeRow(title: "Encryption keys", bytes: breakdown.cryptoKeysBytes, id: "storage-crypto-keys")
            sizeRow(title: "Halo database", bytes: breakdown.haloDatabaseBytes, id: "storage-halo-db")
        }

        Picker("Keep media up to", selection: $selectedMaxSize) {
            ForEach(MediaCacheSizeLimit.allCases) { limit in
                Text(limit.title).tag(limit)
            }
        }
        .disabled(model.isUpdatingRetention || model.isClearing)
        .accessibilityIdentifier("storage-retention-size")
        .onChange(of: selectedMaxSize) { _, next in
            let policy = MediaCacheRetention(maxSize: next, expiry: selectedExpiry)
            guard policy != model.retention else { return }
            Task { await model.setRetention(policy) }
        }

        Picker("Remove unused media after", selection: $selectedExpiry) {
            ForEach(MediaCacheExpiry.allCases) { expiry in
                Text(expiry.title).tag(expiry)
            }
        }
        .disabled(model.isUpdatingRetention || model.isClearing)
        .accessibilityIdentifier("storage-retention-expiry")
        .onChange(of: selectedExpiry) { _, next in
            let policy = MediaCacheRetention(maxSize: selectedMaxSize, expiry: next)
            guard policy != model.retention else { return }
            Task { await model.setRetention(policy) }
        }

        Button(role: .destructive) {
            confirmingClear = true
        } label: {
            HStack(spacing: HaloSpacing.s) {
                Text(model.isClearing ? "Clearing media cache…" : "Clear media cache")
                if model.isClearing {
                    Spacer()
                    ProgressView().controlSize(.small)
                }
            }
        }
        .disabled(model.isClearing || model.isUpdatingRetention)
        .accessibilityIdentifier("clear-cache")

        if let error = model.errorMessage {
            Text(error)
                .font(HaloTypography.caption)
                .foregroundStyle(HaloColor.danger)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("storage-error")
        } else if let status = model.statusMessage {
            Text(status)
                .font(HaloTypography.caption)
                .foregroundStyle(HaloColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("storage-status")
        }
    }

    @ViewBuilder
    private func sizeRow(title: String, bytes: Int64, id: String) -> some View {
        StorageSizeRow(title: title, formatted: StorageSettingsViewModel.formatBytes(bytes), identifier: id)
    }

    private var footerText: String {
        "Media cache holds downloaded photos, videos and files. Older or excess cached media is trimmed automatically according to your limits. Clearing the media cache never touches encryption keys, drafts or unsent messages."
    }
}

private struct StorageSizeRow: View {
    let title: String
    let formatted: String
    let identifier: String
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: HaloSpacing.xxs) {
                Text(title)
                    .font(HaloTypography.body)
                    .foregroundStyle(HaloColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(formatted)
                    .font(HaloTypography.meta)
                    .foregroundStyle(HaloColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(identifier)
        } else {
            LabeledContent(title, value: formatted)
                .accessibilityIdentifier(identifier)
        }
    }
}
#endif
