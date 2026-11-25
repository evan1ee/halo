#if canImport(SwiftUI)
import HaloDesignSystem
import SwiftUI

/// Settings → Message search (MESSAGE_SEARCH FR-14): how far reading has come, how much room it takes, pausing and starting over.
@MainActor
public struct SearchIndexSettingsActions {
    public struct Status: Sendable, Equatable {
        public let progress: String
        public let size: StorageSize
        public init(progress: String, size: StorageSize) {
            self.progress = progress
            self.size = size
        }
    }

    public let status: @Sendable () async -> Status?
    public let isPaused: () -> Bool
    public let setPaused: (Bool) -> Void
    public let usesMobileData: () -> Bool
    public let setUsesMobileData: (Bool) -> Void
    public let rebuild: () async -> Bool

    public init(
        status: @escaping @Sendable () async -> Status?, isPaused: @escaping () -> Bool, setPaused: @escaping (Bool) -> Void,
        usesMobileData: @escaping () -> Bool, setUsesMobileData: @escaping (Bool) -> Void, rebuild: @escaping () async -> Bool
    ) {
        self.status = status
        self.isPaused = isPaused
        self.setPaused = setPaused
        self.usesMobileData = usesMobileData
        self.setUsesMobileData = setUsesMobileData
        self.rebuild = rebuild
    }
}

struct SearchIndexSettingsSection: View {
    let actions: SearchIndexSettingsActions
    @State private var status: SearchIndexSettingsActions.Status?
    @State private var paused = false
    @State private var mobileData = false
    @State private var confirming = false
    @State private var rebuilding = false

    var body: some View {
        Section {
            if let status {
                LabeledContent("Progress", value: status.progress).accessibilityIdentifier("search-progress")
                LabeledContent(status.size.name, value: status.size.formatted)
            }
            Toggle("Pause reading older messages", isOn: $paused)
                .accessibilityIdentifier("search-pause")
                .onChange(of: paused) { _, value in actions.setPaused(value) }
            Toggle("Use mobile data", isOn: $mobileData)
                .accessibilityIdentifier("search-mobile-data")
                .onChange(of: mobileData) { _, value in actions.setUsesMobileData(value) }
            Button(rebuilding ? "Deleting…" : "Delete and rebuild search index", role: .destructive) { confirming = true }
                .disabled(rebuilding)
                .accessibilityIdentifier("search-rebuild")
        } header: {
            Text("Message search")
        } footer: {
            Text("Halo reads your chats back to their start so you can search them, encrypted ones included. The index stays on this device and is unreadable while it is locked.")
        }
        .task {
            paused = actions.isPaused()
            mobileData = actions.usesMobileData()
            while !Task.isCancelled {
                status = await actions.status()
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
        .confirmationDialog("Delete the search index?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Delete and rebuild", role: .destructive) {
                rebuilding = true
                Task {
                    _ = await actions.rebuild()
                    status = await actions.status()
                    rebuilding = false
                }
            }
        } message: {
            Text("Your messages stay. Halo reads them again, which can take a while.")
        }
    }
}
#endif
