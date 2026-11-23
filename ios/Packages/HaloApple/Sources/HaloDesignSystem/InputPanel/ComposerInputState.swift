import Foundation

/// A panel that takes the system keyboard's place under the composer (docs/features/COMPOSER_PANELS.md §3, D97).
public enum ComposerPanel: String, Hashable, Sendable, CaseIterable {
    /// GIFs, stickers and emoji, switched with a tab pill.
    case expression
    /// Photos, files and the clipboard.
    case attachments
}

/// What sits under the composer: nothing, the system keyboard, or one of Halo's panels. Pure and value-typed, so every
/// transition is unit-tested; `ComposerInputController` drives it from focus changes and keyboard notifications.
///
/// The composer never knows which panel is open beyond what it needs for its toggle icon, and panels never know about
/// the composer: both only send events here.
public struct ComposerInputState: Equatable, Sendable {
    public enum Mode: Equatable, Sendable {
        case idle
        case keyboard
        case panel(ComposerPanel)
    }

    public private(set) var mode: Mode = .idle
    /// A text field inside the open panel (its search) has raised the keyboard; the panel shrinks to its search height.
    public private(set) var panelSearching = false
    /// The panel that was open just before the keyboard replaced it. It stays drawn under the rising keyboard until the
    /// keyboard covers it, so the composer never dips while the keyboard animates in.
    public private(set) var lingeringPanel: ComposerPanel?
    /// The open panel is pulled up to its tall, sheet-like height (the composer's ↑ / ↓ button).
    public private(set) var panelExpanded = false

    public init(mode: Mode = .idle) { self.mode = mode }

    /// The open panel, if any.
    public var panel: ComposerPanel? {
        if case .panel(let panel) = mode { return panel }
        return nil
    }

    /// The panel the host draws: the open one, or the one the keyboard is replacing.
    public var displayedPanel: ComposerPanel? { panel ?? lingeringPanel }

    /// Whether the composer's text field should hold focus (and so show the system keyboard).
    public var wantsFieldFocus: Bool { mode == .keyboard }

    /// `true` when the composer's toggle for `panel` should offer the keyboard instead (that panel is open).
    public func showsKeyboardToggle(for panel: ComposerPanel) -> Bool { self.panel == panel }

    // MARK: Events

    /// The user tapped the message field, or it gained focus another way.
    public mutating func fieldFocused() {
        guard mode != .keyboard else { return }
        lingeringPanel = panel
        mode = .keyboard
        panelSearching = false
        panelExpanded = false
    }

    /// The message field lost focus. Only ends keyboard mode: a panel opening unfocuses the field on purpose.
    public mutating func fieldUnfocused() {
        guard mode == .keyboard else { return }
        mode = .idle
        lingeringPanel = nil
    }

    /// The composer's button for `panel`: opens it, or swaps it back for the keyboard when it is already open.
    public mutating func toggle(_ panel: ComposerPanel) {
        if self.panel == panel {
            fieldFocused()
        } else {
            open(panel)
        }
    }

    /// Opens `panel` in place of the keyboard or another panel.
    public mutating func open(_ panel: ComposerPanel) {
        mode = .panel(panel)
        lingeringPanel = nil
        panelSearching = false
    }

    /// The composer's ↑ / ↓ button: grows the open panel to its tall height, or back. Nothing without an open panel.
    public mutating func toggleExpanded() {
        guard panel != nil else { return }
        panelExpanded.toggle()
    }

    /// The system keyboard is about to show. With a panel open it was raised by the panel's own search field.
    public mutating func keyboardWillShow() {
        if panel != nil { panelSearching = true }
    }

    /// The keyboard now covers the panel that was being replaced, so it can go.
    public mutating func keyboardCoversLingeringPanel() { lingeringPanel = nil }

    /// The system keyboard is about to hide (the user dismissed it, or a panel's search ended).
    public mutating func keyboardWillHide() {
        panelSearching = false
        lingeringPanel = nil
        if mode == .keyboard { mode = .idle }
    }

    /// Closes whatever is open: a tap or a drag on the timeline, the back gesture, or sending from a panel that closes.
    public mutating func dismiss() {
        mode = .idle
        panelSearching = false
        lingeringPanel = nil
        panelExpanded = false
    }
}

/// How tall the panel area under the composer is (pure, so the keyboard hand-over is tested without UIKit).
public enum ComposerPanelMetrics {
    /// Height of a panel while its search field has raised the keyboard: the search field plus a row of results.
    public static let searchHeight: Double = 190
    /// Smallest panel; also used before any keyboard height has been seen.
    public static let minimumHeight: Double = 250
    /// Largest panel, so a tall iPad keyboard never makes the panel cover the conversation.
    public static let maximumHeight: Double = 420

    /// The panel's full height: the docked keyboard's last height above the bottom safe area, so a panel and the
    /// keyboard put the composer at the same place. Hardware or floating keyboards report small heights; then the
    /// minimum is used.
    public static func panelHeight(lastKeyboardOverlap: Double?, estimate: Double? = nil) -> Double {
        guard let overlap = lastKeyboardOverlap ?? estimate, overlap >= minimumHeight else { return minimumHeight }
        return min(overlap, maximumHeight)
    }

    /// The docked keyboard's height above the bottom safe area before it has ever been seen at this width. Fitted to
    /// measured portrait iPhones with the suggestion bar (iPhone 16, 852 pt: 294.1; iPhone Air, 912 pt: 312.3, both with a
    /// 34 pt home-indicator inset); a fixed 38 % of the window was 4.3 pt short on the iPhone 16, which moved the message
    /// field when the first panel gave way to the keyboard. Once the keyboard has shown, its real height is remembered
    /// (`KeyboardHeightMemory`) and used instead.
    public static func estimatedKeyboardOverlap(windowHeight: Double, bottomInset: Double) -> Double {
        guard windowHeight > 0 else { return 0 }
        return max(0, windowHeight * 0.3027 + 70.2 - bottomInset)
    }

    /// The height of the area under the composer right now: Halo owns all of it, the system keyboard included (the
    /// timeline ignores the keyboard safe area, D102). While the keyboard is up the area is the keyboard's height; while a
    /// panel is shown, or the keyboard is handing over to or from one, it is the larger of the two (the keyboard plus the
    /// search strip while searching inside a panel). Panels are sized to the remembered keyboard height, so a swap doesn't
    /// change the area and the composer cannot move; the keyboard's own movement is followed with its measured curve
    /// (`ComposerInputController.keyboardAnimation`). Measured per drawn frame on an iPhone 16 (2026-11-23): letting the
    /// system move the composer with the keyboard while the panel compensated made the field dip 69–106 pt in every swap,
    /// even with the measured curve (the two animations also start at different moments); owning the space: 0.0 pt.
    public static func areaHeight(state: ComposerInputState, panelHeight: Double, expandedHeight: Double? = nil, keyboardOverlap: Double) -> Double {
        let keyboard = max(0, keyboardOverlap)
        guard state.displayedPanel != nil else { return keyboard }
        if state.panelSearching { return keyboard + searchHeight }
        if state.panelExpanded, state.panel != nil { return max(panelHeight, expandedHeight ?? panelHeight) }
        return max(panelHeight, keyboard)
    }

    /// The tall panel: the window's height less its top safe area and room for the navigation bar and composer
    /// (`reserved`), never shorter than the normal panel.
    public static func expandedHeight(windowHeight: Double, topInset: Double, panelHeight: Double, reserved: Double = 150) -> Double {
        max(panelHeight, windowHeight - topInset - reserved)
    }
}
