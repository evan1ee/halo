import Foundation
import HaloApplication
import HaloDesignSystem
import HaloDomain
import HaloFoundation
import HaloTestSupport
import SwiftUI
import Testing
@testable import FeatureSettings

@MainActor
@Suite("StorageSettingsViewModel & StorageSettingsSection (SETTINGS §3, AC-SET-3, D55, M20-13)")
struct StorageSettingsTests {
    private func makeSubject(port: FakeStoragePort = FakeStoragePort()) -> (StorageSettingsViewModel, PreferencesStore, FakeStoragePort) {
        let prefs = PreferencesStore(port: FakePreferencesPort())
        let coordinator = StorageCoordinator(port: port, currentRetention: { await MainActor.run { prefs.mediaCacheRetention } })
        let actions = StorageSettingsActions(
            loadSizes: { () async throws(HaloError) in try await coordinator.sizes() },
            clearMediaCache: { () async throws(HaloError) in try await coordinator.clearMediaCache() },
            applyRetention: { retention throws(HaloError) in try await coordinator.applyRetention(retention) }
        )
        let vm = StorageSettingsViewModel(actions: actions, preferences: prefs)
        return (vm, prefs, port)
    }

    @Test("load, clearMediaCache reports freed bytes and keeps keys/messages/db intact, and empty clear says so")
    func loadAndClearMediaCache() async {
        let initial = StoreSizeBreakdown(
            mediaCacheBytes: 120 * 1_048_576,
            messagesBytes: 42 * 1_048_576,
            cryptoKeysBytes: 6 * 1_048_576,
            haloDatabaseBytes: 2 * 1_048_576
        )
        let (vm, _, port) = makeSubject(port: FakeStoragePort(breakdown: initial, remainingMediaAfterClear: 0))

        await vm.load()
        #expect(vm.state == .loaded(initial))

        await vm.clearMediaCache()
        #expect(port.clearCalls == [.defaultPolicy])
        #expect(vm.state == .loaded(StoreSizeBreakdown(
            mediaCacheBytes: 0,
            messagesBytes: initial.messagesBytes,
            cryptoKeysBytes: initial.cryptoKeysBytes,
            haloDatabaseBytes: initial.haloDatabaseBytes
        )))
        #expect(vm.statusMessage?.contains("Cleared") == true)
        #expect(vm.errorMessage == nil)

        // Second clear when already 0 gives honest feedback.
        await vm.clearMediaCache()
        #expect(vm.statusMessage == "Media cache is already empty.")
    }

    @Test("retention updates persist through PreferencesStore and revert with an error on failure (D55)")
    func retentionUpdateAndRevertOnFailure() async {
        let (vm, prefs, port) = makeSubject()
        #expect(vm.retention == .defaultPolicy)

        let next = MediaCacheRetention(maxSize: .mb250, expiry: .days7)
        await vm.setRetention(next)
        #expect(prefs.mediaCacheRetention == next)
        #expect(port.appliedRetentions == [next])
        #expect(vm.errorMessage == nil)

        port.failNext(with: .storage(.corrupted))
        await vm.setRetention(MediaCacheRetention(maxSize: .gb2, expiry: .days90))
        #expect(prefs.mediaCacheRetention == next, "preference must revert on apply failure")
        #expect(vm.errorMessage != nil)
    }

    @Test("load failure shows failed state and retries cleanly")
    func loadFailureAndRetry() async {
        let port = FakeStoragePort()
        let (vm, _, _) = makeSubject(port: port)
        port.failNext(with: .unauthorized(soft: false))

        await vm.load()
        if case .failed = vm.state {} else { Issue.record("expected failed state") }

        await vm.load()
        if case .loaded = vm.state {} else { Issue.record("expected loaded state after retry") }
    }

    #if canImport(UIKit)
    @Test("StorageSettingsSection renders cleanly in Light, Dark, and AX5")
    func storageLightDarkAX5Snapshots() async throws {
        let initial = StoreSizeBreakdown(
            mediaCacheBytes: 128 * 1_048_576,
            messagesBytes: 42 * 1_048_576,
            cryptoKeysBytes: 6 * 1_048_576,
            haloDatabaseBytes: 2 * 1_048_576
        )
        let (vm, _, _) = makeSubject(port: FakeStoragePort(breakdown: initial))
        await vm.load()

        let outDir = ProcessInfo.processInfo.environment["HALO_STORAGE_SNAPSHOT_DIR"]
        let variants: [(String, ColorScheme, DynamicTypeSize)] = [
            ("light", .light, .large),
            ("dark", .dark, .large),
            ("ax5", .light, .accessibility5),
        ]
        for (name, scheme, size) in variants {
            let preview = VStack(alignment: .leading, spacing: HaloSpacing.s) {
                Text("STORAGE")
                    .font(HaloTypography.caption.weight(.semibold))
                    .foregroundStyle(HaloColor.textSecondary)
                VStack(alignment: .leading, spacing: HaloSpacing.s) {
                    StorageSettingsSection(model: vm).sectionRows
                }
                .padding(HaloSpacing.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(HaloColor.bgElevated, in: .rect(cornerRadius: HaloRadius.medium))
            }
            .padding(HaloSpacing.m)
            .frame(width: 393, alignment: .topLeading)
            .background(HaloColor.bgPrimary)
            .environment(\.colorScheme, scheme)
            .environment(\.dynamicTypeSize, size)

            let host = UIHostingController(rootView: preview)
            host.overrideUserInterfaceStyle = scheme == .dark ? .dark : .light
            let fitted = host.sizeThatFits(in: CGSize(width: 393, height: 1800))
            #expect(fitted.width > 0 && fitted.height > 0)
            if let outDir {
                let renderer = ImageRenderer(content: preview)
                renderer.scale = 2
                let image = try #require(renderer.uiImage)
                let png = try #require(image.pngData())
                try png.write(to: URL(fileURLWithPath: outDir).appendingPathComponent("storage-\(name).png"))
            }
        }
    }
    #endif
}
