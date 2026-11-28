#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import HaloDesignSystem
import SwiftUI
import Testing
import UIKit

@Suite("Motion & System Accessibility Settings (M21-3, AC-MOT-2)")
@MainActor
struct MotionAndAccessibilityTests {
    @Test("HaloMotion scroll returns nil under Reduce Motion and animate runs synchronously without waiting")
    func motionReduceMotionPolicies() {
        #expect(HaloMotion.scroll(reduceMotion: true) == nil)
        #expect(HaloMotion.scroll(reduceMotion: false) != nil)

        var ran = false
        let result = HaloMotion.animate(HaloMotion.scroll(reduceMotion: true)) {
            ran = true
            return 42
        }
        #expect(ran)
        #expect(result == 42)

        #expect(HaloMotion.standard(reduceMotion: true) != HaloMotion.standard(reduceMotion: false))
        #expect(HaloMotion.stickerPanel(reduceMotion: true) != HaloMotion.stickerPanel(reduceMotion: false))
        #expect(HaloMotion.snappy(reduceMotion: true) != HaloMotion.snappy(reduceMotion: false))
        #expect(HaloMotion.panelExpand(reduceMotion: true) != HaloMotion.panelExpand(reduceMotion: false))
        #expect(HaloMotion.keyboard(duration: 0.25, reduceMotion: true) != HaloMotion.keyboard(duration: 0.25, reduceMotion: false))
        #expect(HaloMotion.keyboard(duration: 0, reduceMotion: false) == .linear(duration: 0))
    }

    @Test("HaloAccessibility strengthens stroke width and opacity for Increase Contrast and Bold Text")
    func accessibilityMetrics() {
        #expect(HaloAccessibility.reduceTransparency(environment: false, override: nil) == false)
        #expect(HaloAccessibility.reduceTransparency(environment: false, override: true) == true)
        #expect(HaloAccessibility.reduceTransparency(environment: true, override: false) == false)

        let regular = HaloAccessibility.strokeWidth(base: 1, contrast: .standard, legibilityWeight: .regular)
        let increased = HaloAccessibility.strokeWidth(base: 1, contrast: .increased, legibilityWeight: .regular)
        let bold = HaloAccessibility.strokeWidth(base: 1, contrast: .standard, legibilityWeight: .bold)
        let both = HaloAccessibility.strokeWidth(base: 1, contrast: .increased, legibilityWeight: .bold)
        #expect(regular == 1.0)
        #expect(increased > regular)
        #expect(bold > regular)
        #expect(both > increased)

        let standardOpacity = HaloAccessibility.borderOpacity(base: 0.45, contrast: .standard)
        let highContrastOpacity = HaloAccessibility.borderOpacity(base: 0.45, contrast: .increased)
        #expect(highContrastOpacity > standardOpacity)
    }

    @Test("System accessibility settings render distinct, crisp visuals for Light, Dark, Increase Contrast, Reduce Transparency, and Bold Text")
    func perSettingSnapshots() throws {
        let light = try render(showcaseView(), scheme: .light, contrast: .standard, reduceTransparency: false, legibility: .regular)
        let dark = try render(showcaseView(), scheme: .dark, contrast: .standard, reduceTransparency: false, legibility: .regular)
        let highContrast = try render(showcaseView(), scheme: .light, contrast: .increased, reduceTransparency: false, legibility: .regular)
        let reduceTransparency = try render(showcaseView(), scheme: .light, contrast: .standard, reduceTransparency: true, legibility: .regular)
        let boldText = try render(showcaseView(), scheme: .light, contrast: .standard, reduceTransparency: false, legibility: .bold)

        for img in [light, dark, highContrast, reduceTransparency, boldText] {
            #expect(img.width > 0 && img.height > 0)
        }

        // Increase Contrast and Reduce Transparency must visibly change rendered pixels compared to standard Light.
        #expect(try pngData(highContrast) != pngData(light))
        #expect(try pngData(reduceTransparency) != pngData(light))
        #expect(try pngData(boldText) != pngData(light))

        if let dir = ProcessInfo.processInfo.environment["HALO_SNAPSHOT_DIR"] {
            let base = URL(fileURLWithPath: dir)
            try savePNG(light, to: base.appendingPathComponent("a11y-light.png"))
            try savePNG(dark, to: base.appendingPathComponent("a11y-dark.png"))
            try savePNG(highContrast, to: base.appendingPathComponent("a11y-increase-contrast.png"))
            try savePNG(reduceTransparency, to: base.appendingPathComponent("a11y-reduce-transparency.png"))
            try savePNG(boldText, to: base.appendingPathComponent("a11y-bold-text.png"))
        }
    }

    @ViewBuilder
    private func showcaseView() -> some View {
        VStack(alignment: .leading, spacing: HaloSpacing.m) {
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
                title: "Couldn't load messages",
                message: "Check your connection and try again.",
                onRetry: {}
            )
            HStack(spacing: HaloSpacing.l) {
                UnreadIndicator(.dot)
                UnreadIndicator(.approximate)
                UnreadIndicator(.count(7))
                UnreadIndicator(.mentions(2))
            }
            .padding(HaloSpacing.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(HaloColor.bgSecondary, in: RoundedRectangle(cornerRadius: HaloRadius.medium, style: .continuous))
            .haloContrastBorder(cornerRadius: HaloRadius.medium)

            ZStack {
                HaloColor.mediaBackdrop
                Text("Saved to Photos")
                    .font(HaloTypography.captionEmphasis)
                    .foregroundStyle(HaloColor.mediaOverlayForeground)
                    .padding(.horizontal, HaloSpacing.m)
                    .padding(.vertical, HaloSpacing.s)
                    .haloOverlayPillBackground()
            }
            .frame(height: 64)
            .clipShape(RoundedRectangle(cornerRadius: HaloRadius.medium, style: .continuous))
        }
        .padding(HaloSpacing.m)
        .background(HaloColor.bgPrimary)
    }

    private func render<V: View>(
        _ view: V,
        scheme: ColorScheme,
        contrast: ColorSchemeContrast,
        reduceTransparency: Bool,
        legibility: LegibilityWeight
    ) throws -> CGImage {
        let styled = view
            .frame(width: 390)
            .fixedSize(horizontal: false, vertical: true)
            .environment(\.colorScheme, scheme)
            .environment(\.haloColorSchemeContrastOverride, contrast)
            .environment(\.haloReduceTransparencyOverride, reduceTransparency)
            .environment(\.legibilityWeight, legibility)
        let renderer = ImageRenderer(content: styled)
        renderer.scale = 2
        return try #require(renderer.cgImage)
    }

    private func pngData(_ image: CGImage) throws -> Data {
        try #require(UIImage(cgImage: image).pngData())
    }

    private func savePNG(_ image: CGImage, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try pngData(image).write(to: url)
    }
}
#endif
