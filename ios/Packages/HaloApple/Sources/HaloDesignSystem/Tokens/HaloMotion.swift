import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Motion tokens, transitions, and `withAnimation` wrapper with Reduce Motion fallbacks
/// (`docs/design/DESIGN_SYSTEM.md` §6, AC-MOT-2, M21-3).
///
/// Every animation in Halo goes through `HaloMotion` so Reduce Motion replaces springs,
/// slides, scales, and smooth scrolls with calm cross-fades or instant jumps, and no
/// user interaction ever waits for an animation.
public enum HaloMotion {
    /// Reads the system Reduce Motion setting for non-View controllers (such as `ComposerInputController`).
    @MainActor
    public static var systemReduceMotion: Bool {
        #if canImport(UIKit)
        UIAccessibility.isReduceMotionEnabled
        #else
        false
        #endif
    }

    /// Standard spring (`response: 0.35, dampingFraction: 0.85`), or a cross-fade when Reduce Motion is enabled.
    public static func standard(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.35, dampingFraction: 0.85)
    }

    /// Sticker panel spring (`response: 0.3, dampingFraction: 0.9`), or a cross-fade when Reduce Motion is enabled.
    public static func stickerPanel(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.3, dampingFraction: 0.9)
    }

    /// Quick state/control transition (0.2 s snappy), or a calm cross-fade under Reduce Motion.
    public static func snappy(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.12) : .snappy(duration: 0.2)
    }

    /// Gentle appearance/dismissal (banners, toasts, media chrome), or a short cross-fade under Reduce Motion.
    public static func gentle(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.15) : .easeOut(duration: 0.25)
    }

    /// Jumped-message highlight fade.
    public static func highlightFade(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.2) : .easeOut(duration: 0.4)
    }

    /// Badge appearance and count change animation (0.15 s).
    public static func badge(reduceMotion: Bool) -> Animation {
        reduceMotion ? .linear(duration: 0.1) : .easeInOut(duration: 0.15)
    }

    /// Message bubble insertion animation (0.2 s).
    public static func bubbleAppear(reduceMotion: Bool) -> Animation {
        reduceMotion ? .linear(duration: 0.12) : .easeOut(duration: 0.2)
    }

    /// Composer panel expand/collapse curve (`smooth`), or a short cross-fade under Reduce Motion.
    public static func panelExpand(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.15) : .smooth(duration: 0.35)
    }

    /// System keyboard motion matching the measured iOS keyboard spring (D102),
    /// or a short cross-fade under Reduce Motion.
    public static func keyboard(duration: Double, reduceMotion: Bool) -> Animation {
        guard duration > 0 else { return .linear(duration: 0) }
        if reduceMotion {
            return .easeInOut(duration: min(duration, 0.15))
        }
        return .interpolatingSpring(mass: 1, stiffness: 484, damping: 44, initialVelocity: 0)
    }

    /// Programmatic scroll animation (`nil` under Reduce Motion so `scrollTo` lands without sliding).
    public static func scroll(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.25)
    }

    /// Runs `body` inside `SwiftUI.withAnimation` using a `HaloMotion` animation.
    /// When `animation` is `nil`, executes `body` synchronously without animation.
    @discardableResult
    public static func animate<Result>(_ animation: Animation?, _ body: () throws -> Result) rethrows -> Result {
        if let animation {
            return try withAnimation(animation, body)
        }
        return try body()
    }

    /// Edge-slide transition that degrades to pure cross-fade under Reduce Motion (AC-MOT-2).
    public static func slide(from edge: Edge, reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .move(edge: edge))
    }

    /// Scale-and-fade transition that degrades to pure cross-fade under Reduce Motion (AC-MOT-2).
    public static func scalePop(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .scale.combined(with: .opacity)
    }

    /// Pure opacity transition (always safe under Reduce Motion).
    public static var fade: AnyTransition { .opacity }
}

public extension View {
    /// Replaces SF Symbols with `.symbolEffect(.replace)` unless Reduce Motion is enabled.
    @ViewBuilder
    func haloSymbolReplace(reduceMotion: Bool) -> some View {
        if reduceMotion {
            self.contentTransition(.identity)
        } else {
            self.contentTransition(.symbolEffect(.replace))
        }
    }

    /// Applies `.symbolEffect(.pulse)` only when Reduce Motion is disabled.
    func haloSymbolPulse(reduceMotion: Bool) -> some View {
        self.symbolEffect(.pulse, isActive: !reduceMotion)
    }

    /// Applies `.contentTransition(.numericText())` only when Reduce Motion is disabled.
    @ViewBuilder
    func haloNumericTextTransition(reduceMotion: Bool) -> some View {
        if reduceMotion {
            self.contentTransition(.identity)
        } else {
            self.contentTransition(.numericText())
        }
    }
}
