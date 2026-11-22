import SwiftUI

/// Dynamic Type text styles (`docs/design/DESIGN_SYSTEM.md` §3).
///
/// Every text style scales with Dynamic Type; no fixed font sizes are used in feature views (AC-UX-1).
public enum HaloTypography {
    public static let title: Font = .title2.weight(.semibold)
    public static let headline: Font = .headline
    public static let body: Font = .body
    public static let bodyEmphasis: Font = .body.weight(.semibold)
    public static let meta: Font = .footnote
    public static let caption: Font = .caption
    public static let captionEmphasis: Font = .caption.weight(.semibold)
    public static let code: Font = .body.monospaced()
    public static let codeMeta: Font = .caption.monospaced()
}
