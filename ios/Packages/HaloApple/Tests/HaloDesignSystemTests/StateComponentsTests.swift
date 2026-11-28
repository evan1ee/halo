#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import HaloDesignSystem
import SwiftUI
import Testing
import UIKit

@Suite("State Components (M21-1)")
@MainActor
struct StateComponentsTests {
    @Test("LoadingState styles are equatable across list, timeline, rows, grid and detail")
    func loadingStateStyles() {
        #expect(LoadingState.Style.roomList() == .roomList(count: 8))
        #expect(LoadingState.Style.timeline() == .timeline(count: 6))
        #expect(LoadingState.Style.rows() == .rows(count: 5))
        #expect(LoadingState.Style.grid() == .grid(columns: 3, count: 9))
        #expect(LoadingState.Style.detail() == .detail(rows: 4))
        #expect(LoadingState.Style.rows(count: 3) != .grid(columns: 3, count: 9))
    }

    @Test("ErrorState inline and HaloBanner adapt vertically at AX5 and render cleanly in Light, Dark and AX5")
    func stateMatrixSnapshots() throws {
        let board = stateBoard()
        let light = try render(board, width: 390, scheme: .light, typeSize: .large)
        let dark = try render(board, width: 390, scheme: .dark, typeSize: .large)
        let ax5 = try render(board, width: 390, scheme: .light, typeSize: .accessibility5)

        #expect(light.width > 0 && light.height > 0)
        #expect(dark.width > 0 && dark.height > 0)
        #expect(ax5.width > 0 && ax5.height > 0)
        #expect(ax5.height > light.height)

        let inlineStandard = try render(
            ErrorState(layout: .inline, title: "Couldn't load earlier messages", message: "Check your connection and try again.", onRetry: {}),
            width: 358,
            scheme: .light,
            typeSize: .large
        )
        let inlineAX5 = try render(
            ErrorState(layout: .inline, title: "Couldn't load earlier messages", message: "Check your connection and try again.", onRetry: {}),
            width: 358,
            scheme: .light,
            typeSize: .accessibility5
        )
        #expect(inlineAX5.height > inlineStandard.height)

        let bannerStandard = try render(
            HaloBanner(tone: .warning, icon: "wifi.slash", message: "Offline — messages will send when you reconnect.", actionTitle: "Retry", onAction: {}, onDismiss: {}),
            width: 390,
            scheme: .light,
            typeSize: .large
        )
        let bannerAX5 = try render(
            HaloBanner(tone: .warning, icon: "wifi.slash", message: "Offline — messages will send when you reconnect.", actionTitle: "Retry", onAction: {}, onDismiss: {}),
            width: 390,
            scheme: .light,
            typeSize: .accessibility5
        )
        #expect(bannerAX5.height > bannerStandard.height)

        if let dir = ProcessInfo.processInfo.environment["HALO_SNAPSHOT_DIR"] {
            try savePNG(light, to: URL(fileURLWithPath: dir).appendingPathComponent("state-matrix-light.png"))
            try savePNG(dark, to: URL(fileURLWithPath: dir).appendingPathComponent("state-matrix-dark.png"))
            try savePNG(ax5, to: URL(fileURLWithPath: dir).appendingPathComponent("state-matrix-ax5.png"))
        }
    }

    @ViewBuilder
    private func stateBoard() -> some View {
        VStack(alignment: .leading, spacing: HaloSpacing.l) {
            HaloBanner(
                tone: .warning,
                icon: "wifi.slash",
                message: "Offline — messages will send when you reconnect.",
                actionTitle: "Retry",
                onAction: {},
                onDismiss: {}
            )
            ErrorState(
                layout: .inline,
                title: "Couldn't load earlier messages",
                message: "Check your connection and try again.",
                onRetry: {}
            )
            LoadingState(.rows(count: 2))
            LoadingState(.grid(columns: 3, count: 3))
            LoadingState(.detail(rows: 2))
            LoadingState(.timeline(count: 2))
        }
        .padding(HaloSpacing.m)
        .background(HaloColor.bgPrimary)
    }

    private func render<V: View>(
        _ view: V,
        width: CGFloat,
        scheme: ColorScheme,
        typeSize: DynamicTypeSize
    ) throws -> CGImage {
        let styled = view
            .frame(width: width)
            .fixedSize(horizontal: false, vertical: true)
            .environment(\.colorScheme, scheme)
            .environment(\.dynamicTypeSize, typeSize)
        let renderer = ImageRenderer(content: styled)
        renderer.scale = 2
        return try #require(renderer.cgImage)
    }

    private func savePNG(_ image: CGImage, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try #require(UIImage(cgImage: image).pngData())
        try data.write(to: url)
    }
}
#endif
