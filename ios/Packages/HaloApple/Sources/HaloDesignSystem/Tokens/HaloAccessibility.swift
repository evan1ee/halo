import SwiftUI

/// System accessibility settings helpers for Reduce Transparency, Increase Contrast,
/// and Bold Text (`docs/design/DESIGN_SYSTEM.md` §1, §6, §9; ROADMAP M21-3).
public enum HaloAccessibility {
    /// Effective Reduce Transparency value honoring test/preview overrides when present.
    public static func reduceTransparency(environment: Bool, override: Bool?) -> Bool {
        override ?? environment
    }

    /// Effective ColorSchemeContrast value honoring test/preview overrides when present.
    public static func colorSchemeContrast(environment: ColorSchemeContrast, override: ColorSchemeContrast?) -> ColorSchemeContrast {
        override ?? environment
    }

    /// Stroke width adapted for Increase Contrast and Bold Text (`legibilityWeight == .bold`).
    public static func strokeWidth(
        base: CGFloat = 1,
        contrast: ColorSchemeContrast,
        legibilityWeight: LegibilityWeight?
    ) -> CGFloat {
        var width = base
        if contrast == .increased { width += 0.5 }
        if legibilityWeight == .bold { width += 0.5 }
        return width
    }

    /// Opacity for subtle decorative borders/rings, strengthened under Increase Contrast.
    public static func borderOpacity(base: Double = 0.45, contrast: ColorSchemeContrast) -> Double {
        contrast == .increased ? min(1, base + 0.35) : base
    }
}

private struct HaloReduceTransparencyOverrideKey: EnvironmentKey {
    static let defaultValue: Bool? = nil
}

private struct HaloColorSchemeContrastOverrideKey: EnvironmentKey {
    static let defaultValue: ColorSchemeContrast? = nil
}

public extension EnvironmentValues {
    /// Optional override for `accessibilityReduceTransparency` used by previews and visual regression tests.
    var haloReduceTransparencyOverride: Bool? {
        get { self[HaloReduceTransparencyOverrideKey.self] }
        set { self[HaloReduceTransparencyOverrideKey.self] = newValue }
    }

    /// Optional override for `colorSchemeContrast` used by previews and visual regression tests.
    var haloColorSchemeContrastOverride: ColorSchemeContrast? {
        get { self[HaloColorSchemeContrastOverrideKey.self] }
        set { self[HaloColorSchemeContrastOverrideKey.self] = newValue }
    }
}

/// Bar background that uses `.bar` normally and an opaque elevated surface with a hairline border
/// when Reduce Transparency or Increase Contrast is enabled.
private struct HaloBarBackgroundModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var systemReduceTransparency
    @Environment(\.haloReduceTransparencyOverride) private var overrideReduceTransparency
    @Environment(\.colorSchemeContrast) private var systemContrast
    @Environment(\.haloColorSchemeContrastOverride) private var overrideContrast
    @Environment(\.legibilityWeight) private var legibilityWeight

    private var contrast: ColorSchemeContrast {
        HaloAccessibility.colorSchemeContrast(environment: systemContrast, override: overrideContrast)
    }

    private var opaque: Bool {
        HaloAccessibility.reduceTransparency(environment: systemReduceTransparency, override: overrideReduceTransparency)
            || contrast == .increased
    }

    func body(content: Content) -> some View {
        let stroke = HaloAccessibility.strokeWidth(base: 0.75, contrast: contrast, legibilityWeight: legibilityWeight)
        content
            .background {
                if opaque {
                    HaloColor.bgElevated
                } else {
                    Rectangle().fill(.bar)
                }
            }
            .overlay(alignment: .bottom) {
                if opaque {
                    Rectangle()
                        .fill(HaloColor.textSecondary.opacity(HaloAccessibility.borderOpacity(base: 0.25, contrast: contrast)))
                        .frame(height: stroke)
                }
            }
    }
}

/// Capsule overlay background for dark media chrome (photo/video viewers) that degrades
/// from `.ultraThinMaterial` to an opaque high-contrast capsule under Reduce Transparency or Increase Contrast.
private struct HaloOverlayPillBackgroundModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var systemReduceTransparency
    @Environment(\.haloReduceTransparencyOverride) private var overrideReduceTransparency
    @Environment(\.colorSchemeContrast) private var systemContrast
    @Environment(\.haloColorSchemeContrastOverride) private var overrideContrast
    @Environment(\.legibilityWeight) private var legibilityWeight

    private var contrast: ColorSchemeContrast {
        HaloAccessibility.colorSchemeContrast(environment: systemContrast, override: overrideContrast)
    }

    private var opaque: Bool {
        HaloAccessibility.reduceTransparency(environment: systemReduceTransparency, override: overrideReduceTransparency)
            || contrast == .increased
    }

    func body(content: Content) -> some View {
        let stroke = HaloAccessibility.strokeWidth(base: 1, contrast: contrast, legibilityWeight: legibilityWeight)
        content
            .background {
                if opaque {
                    Capsule().fill(HaloColor.mediaBackdrop)
                } else {
                    Capsule().fill(.ultraThinMaterial)
                }
            }
            .overlay {
                if opaque {
                    Capsule().strokeBorder(
                        HaloColor.mediaOverlayForeground.opacity(HaloAccessibility.borderOpacity(base: 0.35, contrast: contrast)),
                        lineWidth: stroke
                    )
                }
            }
    }
}

/// Adds a crisp semantic border around card/banner surfaces when Increase Contrast is enabled.
private struct HaloContrastBorderModifier: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.colorSchemeContrast) private var systemContrast
    @Environment(\.haloColorSchemeContrastOverride) private var overrideContrast
    @Environment(\.legibilityWeight) private var legibilityWeight

    private var contrast: ColorSchemeContrast {
        HaloAccessibility.colorSchemeContrast(environment: systemContrast, override: overrideContrast)
    }

    func body(content: Content) -> some View {
        content.overlay {
            if contrast == .increased {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        HaloColor.textSecondary.opacity(HaloAccessibility.borderOpacity(base: 0.3, contrast: contrast)),
                        lineWidth: HaloAccessibility.strokeWidth(base: 1, contrast: contrast, legibilityWeight: legibilityWeight)
                    )
            }
        }
    }
}

public extension View {
    /// Applies a system `.bar` background that falls back to an opaque elevated surface under Reduce Transparency or Increase Contrast.
    func haloBarBackground() -> some View {
        modifier(HaloBarBackgroundModifier())
    }

    /// Applies an `.ultraThinMaterial` capsule background that falls back to an opaque high-contrast capsule under Reduce Transparency or Increase Contrast.
    func haloOverlayPillBackground() -> some View {
        modifier(HaloOverlayPillBackgroundModifier())
    }

    /// Adds a semantic border around a rounded card surface when Increase Contrast is enabled.
    func haloContrastBorder(cornerRadius: CGFloat = HaloRadius.medium) -> some View {
        modifier(HaloContrastBorderModifier(cornerRadius: cornerRadius))
    }
}
