import SwiftUI

/// Motion tokens with Reduce Motion fallbacks (`docs/design/DESIGN_SYSTEM.md` §6).
public enum HaloMotion {
    /// Standard spring (`response: 0.35, dampingFraction: 0.85`), or a cross-fade when Reduce Motion is enabled.
    public static func standard(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.35, dampingFraction: 0.85)
    }

    /// Sticker panel spring (`response: 0.3, dampingFraction: 0.9`), or a cross-fade when Reduce Motion is enabled.
    public static func stickerPanel(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.3, dampingFraction: 0.9)
    }

    /// Badge appearance and count change animation (0.15 s).
    public static func badge(reduceMotion: Bool) -> Animation {
        reduceMotion ? .linear(duration: 0.1) : .easeInOut(duration: 0.15)
    }

    /// Message bubble insertion animation (0.2 s).
    public static func bubbleAppear(reduceMotion: Bool) -> Animation {
        reduceMotion ? .linear(duration: 0.12) : .easeOut(duration: 0.2)
    }
}
