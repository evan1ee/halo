import SwiftUI

/// Semantic colour tokens from `docs/design/DESIGN_SYSTEM.md` §2.
///
/// Backed by `Colors.xcassets` in `HaloDesignSystem` with Light, Dark, and Increase Contrast variants.
/// Feature views and the app composition root use these tokens instead of raw system colours (AC-UX-1).
public enum HaloColor {
    /// Primary screen background (`bg.primary`).
    public static let bgPrimary = Color("BgPrimary", bundle: .module)
    /// Grouped backgrounds and composer (`bg.secondary`).
    public static let bgSecondary = Color("BgSecondary", bundle: .module)
    /// Sheets and panels (`bg.elevated`).
    public static let bgElevated = Color("BgElevated", bundle: .module)

    /// Body text (`text.primary`).
    public static let textPrimary = Color("TextPrimary", bundle: .module)
    /// Metadata and timestamps (`text.secondary`).
    public static let textSecondary = Color("TextSecondary", bundle: .module)

    /// Primary actions, own bubbles, links (`accent`, Halo indigo).
    public static let accent = Color("Accent", bundle: .module)
    /// Text and glyphs on an `accent` fill (`onAccent`).
    public static let onAccent = Color("OnAccent", bundle: .module)

    /// Unread badge fill (`attention`, burnt orange).
    public static let attention = Color("Attention", bundle: .module)
    /// Count on the unread badge (`onAttention`).
    public static let onAttention = Color("OnAttention", bundle: .module)

    /// Mention badge fill (`mention`).
    public static let mention = Color("Mention", bundle: .module)
    /// Count on the mention badge (`onMention`).
    public static let onMention = Color("OnMention", bundle: .module)

    /// Bot completed, sent (`success`).
    public static let success = Color("Success", bundle: .module)
    /// Pending, unverified (`warning`, amber — distinct from `attention`).
    public static let warning = Color("Warning", bundle: .module)
    /// Failed, destructive (`danger`).
    public static let danger = Color("Danger", bundle: .module)

    /// Own message bubble fill (`bubble.own`).
    public static let bubbleOwn = Color("BubbleOwn", bundle: .module)
    /// Others' message bubble fill (`bubble.other`).
    public static let bubbleOther = Color("BubbleOther", bundle: .module)

    /// Full-screen media viewer backdrop (always dark for photo/video legibility).
    public static let mediaBackdrop = Color.black
    /// Translucent dark scrim behind media chrome and duration badges.
    public static let mediaOverlayBackground = Color.black.opacity(0.62)
    /// High-contrast foreground on media overlays and dark viewer chrome.
    public static let mediaOverlayForeground = Color.white

    /// Asset names for every semantic colour token (used by contrast tests, AC-UX-2).
    public static let assetBundle: Bundle = .module
}
