import CoreGraphics

/// Spacing scale in points (`docs/design/DESIGN_SYSTEM.md` §4).
public enum HaloSpacing {
    /// 2 pt
    public static let xxs: CGFloat = 2
    /// 4 pt
    public static let xs: CGFloat = 4
    /// 8 pt
    public static let s: CGFloat = 8
    /// 12 pt
    public static let m: CGFloat = 12
    /// 16 pt
    public static let l: CGFloat = 16
    /// 24 pt
    public static let xl: CGFloat = 24
    /// 32 pt
    public static let xxl: CGFloat = 32
}

/// Corner radius scale in points (`docs/design/DESIGN_SYSTEM.md` §4).
public enum HaloRadius {
    /// 6 pt — chips
    public static let small: CGFloat = 6
    /// 12 pt — cards
    public static let medium: CGFloat = 12
    /// 18 pt — message bubbles (continuous corners)
    public static let bubble: CGFloat = 18
    /// 24 pt — sheets
    public static let sheet: CGFloat = 24
}
