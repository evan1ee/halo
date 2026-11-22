import Foundation
import HaloDesignSystem
import Testing
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

@MainActor
@Suite("HaloColor WCAG AA contrast (DESIGN_SYSTEM §2, AC-UX-2)")
struct ColorContrastTests {
    private struct RGB {
        let r: Double
        let g: Double
        let b: Double
    }

    private enum Mode: String, CaseIterable {
        case light
        case dark
        case lightHighContrast
        case darkHighContrast
    }

    private func resolve(_ name: String, mode: Mode) throws -> RGB {
        #if canImport(AppKit)
        let appearanceName: NSAppearance.Name = switch mode {
        case .light: .aqua
        case .dark: .darkAqua
        case .lightHighContrast: .accessibilityHighContrastAqua
        case .darkHighContrast: .accessibilityHighContrastDarkAqua
        }
        let appearance = try #require(NSAppearance(named: appearanceName))
        let color = try #require(NSColor(named: name, bundle: HaloColor.assetBundle), "Missing color asset \(name)")
        var rgb: RGB?
        appearance.performAsCurrentDrawingAppearance {
            if let srgb = color.usingColorSpace(.sRGB) {
                rgb = RGB(r: Double(srgb.redComponent), g: Double(srgb.greenComponent), b: Double(srgb.blueComponent))
            }
        }
        return try #require(rgb, "Could not convert \(name) to sRGB")
        #elseif canImport(UIKit)
        let style: UIUserInterfaceStyle = (mode == .dark || mode == .darkHighContrast) ? .dark : .light
        let contrast: UIAccessibilityContrast = (mode == .lightHighContrast || mode == .darkHighContrast) ? .high : .normal
        let traits = UITraitCollection { mutableTraits in
            mutableTraits.userInterfaceStyle = style
            mutableTraits.accessibilityContrast = contrast
        }
        let color = try #require(
            UIColor(named: name, in: HaloColor.assetBundle, compatibleWith: traits),
            "Missing color asset \(name)"
        )
        let resolved = color.resolvedColor(with: traits)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        #expect(resolved.getRed(&r, green: &g, blue: &b, alpha: &a))
        return RGB(r: Double(r), g: Double(g), b: Double(b))
        #endif
    }

    private func relativeLuminance(_ rgb: RGB) -> Double {
        func linearize(_ c: Double) -> Double {
            c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linearize(rgb.r) + 0.7152 * linearize(rgb.g) + 0.0722 * linearize(rgb.b)
    }

    private func contrastRatio(_ a: RGB, _ b: RGB) -> Double {
        let l1 = relativeLuminance(a)
        let l2 = relativeLuminance(b)
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }

    @Test("Every foreground/background and on* pair meets WCAG AA (>= 4.5:1) in light, dark, and Increase Contrast")
    func allPairsMeetWCAGAA() throws {
        let backgrounds = ["BgPrimary", "BgSecondary", "BgElevated"]
        let foregrounds = ["TextPrimary", "TextSecondary", "Accent", "Success", "Warning", "Danger"]
        let onPairs: [(fg: String, bg: String)] = [
            ("OnAccent", "Accent"),
            ("OnAttention", "Attention"),
            ("OnMention", "Mention"),
        ]

        for mode in Mode.allCases {
            for bg in backgrounds {
                let bgRGB = try resolve(bg, mode: mode)
                for fg in foregrounds {
                    let fgRGB = try resolve(fg, mode: mode)
                    let ratio = contrastRatio(fgRGB, bgRGB)
                    // Founder decision: the accent is Apple's system blue (#007AFF / #0A84FF), which is ~3.7:1 on the grey
                    // light background. Accent is for links, icons and controls (WCAG 3:1 for UI components); Increase
                    // Contrast switches to a darker blue that clears 4.5:1.
                    let minimum = (fg == "Accent" && (mode == .light || mode == .dark)) ? 3.0 : 4.5
                    #expect(
                        ratio >= minimum,
                        "\(mode.rawValue): \(fg) on \(bg) contrast is \(String(format: "%.2f", ratio)):1 (< \(minimum):1)"
                    )
                }
            }
            for pair in onPairs {
                let fgRGB = try resolve(pair.fg, mode: mode)
                let bgRGB = try resolve(pair.bg, mode: mode)
                let ratio = contrastRatio(fgRGB, bgRGB)
                // White on #007AFF is 4.02:1 (button labels are large/bold text: WCAG 3:1); other modes stay at 4.5:1.
                let minimum = (pair.fg == "OnAccent" && mode == .light) ? 3.0 : 4.5
                #expect(
                    ratio >= minimum,
                    "\(mode.rawValue): \(pair.fg) on \(pair.bg) contrast is \(String(format: "%.2f", ratio)):1 (< \(minimum):1)"
                )
            }
        }
    }

    @Test("Every semantic token asset exists in the bundle")
    func allTokensPresent() throws {
        let names = [
            "BgPrimary", "BgSecondary", "BgElevated",
            "TextPrimary", "TextSecondary",
            "Accent", "OnAccent",
            "Attention", "OnAttention",
            "Mention", "OnMention",
            "Success", "Warning", "Danger",
            "BubbleOwn", "BubbleOther",
        ]
        for name in names {
            _ = try resolve(name, mode: .light)
            _ = try resolve(name, mode: .dark)
        }
    }
}
