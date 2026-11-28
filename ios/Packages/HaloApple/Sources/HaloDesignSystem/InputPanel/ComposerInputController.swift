#if canImport(SwiftUI)
import Observation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Owns the composer's input state (keyboard vs. panels) for one conversation and keeps it in step with the system
/// keyboard (docs/features/COMPOSER_PANELS.md §3, D97).
///
/// The keyboard's frame notifications tell how much of the window it covers and how its animation runs; panel changes are
/// animated with the same curve, so when a panel replaces the keyboard (or the other way round) the panel area grows by
/// exactly what the keyboard gives up and the composer stays where it is.
@MainActor @Observable
public final class ComposerInputController {
    public private(set) var state = ComposerInputState()
    /// How much of the window's bottom (above its safe area) the keyboard covers now.
    public private(set) var keyboardOverlap: Double = 0
    /// The docked keyboard's last overlap, which sizes the panels.
    public private(set) var lastKeyboardOverlap: Double?

    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var lingerTimeout: Task<Void, Never>?
    /// When a panel last took the keyboard's place: a focus gain right after it is the field taking focus back, not the user.
    @ObservationIgnored private var panelOpenedAt: ContinuousClock.Instant?
    /// How long after a panel opens a focus gain is treated as the field taking focus back.
    static let refocusGuard: Duration = .milliseconds(500)

    public init() {
        #if canImport(UIKit)
        let center = NotificationCenter.default
        let names = [UIResponder.keyboardWillShowNotification, UIResponder.keyboardWillHideNotification, UIResponder.keyboardWillChangeFrameNotification]
        for name in names {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                // Only Sendable values cross into the main actor.
                let hideNote = note.name == UIResponder.keyboardWillHideNotification
                let duration = (note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
                let end = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
                MainActor.assumeIsolated { self?.keyboardChanged(KeyboardChange(hideNote: hideNote, endFrame: end, duration: duration)) }
            })
        }
        #endif
    }

    isolated deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        lingerTimeout?.cancel()
    }

    /// The panels' full height.
    public var panelHeight: Double {
        #if canImport(UIKit)
        let window = Self.keyWindow
        let width = Double(window?.bounds.width ?? 0)
        let estimate = ComposerPanelMetrics.estimatedKeyboardOverlap(
            windowHeight: Double(window?.bounds.height ?? 0), bottomInset: Double(window?.safeAreaInsets.bottom ?? 0))
        return ComposerPanelMetrics.panelHeight(lastKeyboardOverlap: lastKeyboardOverlap ?? KeyboardHeightMemory.overlap(forWidth: width), estimate: estimate)
        #else
        return ComposerPanelMetrics.panelHeight(lastKeyboardOverlap: lastKeyboardOverlap)
        #endif
    }

    #if canImport(UIKit)
    static var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first(where: \.isKeyWindow)
    }
    #endif

    /// The tall height the ↑ button pulls a panel up to.
    public var expandedHeight: Double {
        #if canImport(UIKit)
        let window = Self.keyWindow
        let height = Double(window?.bounds.height ?? 0) - Double(window?.safeAreaInsets.bottom ?? 0)
        return ComposerPanelMetrics.expandedHeight(windowHeight: height, topInset: Double(window?.safeAreaInsets.top ?? 0), panelHeight: panelHeight)
        #else
        return panelHeight
        #endif
    }

    /// The height the panel area under the composer has right now.
    public var areaHeight: Double {
        ComposerPanelMetrics.areaHeight(state: state, panelHeight: panelHeight, expandedHeight: expandedHeight, keyboardOverlap: keyboardOverlap)
    }

    /// The composer's ↑ / ↓ button. The panel's content is laid out at the taller of its two heights while the area
    /// animates, so it slides rather than redraws: no flash.
    public func toggleExpanded() {
        HaloMotion.animate(HaloMotion.panelExpand(reduceMotion: HaloMotion.systemReduceMotion)) { state.toggleExpanded() }
    }

    // MARK: Events from the composer, the panels and the timeline

    public func fieldFocusChanged(_ focused: Bool) {
        if focused {
            guard state.mode != .keyboard else { return }
            // Resigning first responder for a panel sometimes loses a race with SwiftUI's focus or the button tap, and the
            // field takes focus back by itself a moment later: keep the panel the user just opened.
            if state.panel != nil, let openedAt = panelOpenedAt, ContinuousClock.now - openedAt < Self.refocusGuard {
                resignKeyboard()
                return
            }
            HaloMotion.animate(Self.keyboardAnimation(duration: 0.25)) { state.fieldFocused() }
            armLingerTimeout()
        } else {
            state.fieldUnfocused()
        }
    }

    /// The composer's button for `panel`.
    public func toggle(_ panel: ComposerPanel) {
        let opening = state.panel != panel
        HaloMotion.animate(Self.keyboardAnimation(duration: 0.25)) { state.toggle(panel) }
        if opening {
            panelOpenedAt = .now
            resignKeyboard()
        } else {
            panelOpenedAt = nil
            armLingerTimeout()
        }
    }

    public func open(_ panel: ComposerPanel) {
        HaloMotion.animate(Self.keyboardAnimation(duration: 0.25)) { state.open(panel) }
        panelOpenedAt = .now
        resignKeyboard()
    }

    /// A panel takes the keyboard's place: the field must let go of first responder now. Clearing the SwiftUI focus
    /// binding alone sometimes lost a race with the button tap and left the keyboard up over the panel.
    private func resignKeyboard() {
        #if canImport(UIKit)
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        #endif
    }

    /// Closes the keyboard or panel (a tap or drag on the conversation).
    public func dismiss() {
        guard state.mode != .idle || state.displayedPanel != nil else { return }
        HaloMotion.animate(Self.keyboardAnimation(duration: 0.25)) { state.dismiss() }
        resignKeyboard()
    }

    // MARK: Keyboard

    /// A keyboard notification, reduced to what the panels need: whether it hides, how much of the key window's bottom
    /// (above its safe area) it will cover, and how long it animates.
    struct KeyboardChange: Sendable {
        var isHiding: Bool
        var overlap: Double
        var duration: Double

        init(isHiding: Bool, overlap: Double, duration: Double) {
            self.isHiding = isHiding
            self.overlap = overlap
            self.duration = duration
        }

        #if canImport(UIKit)
        @MainActor init(hideNote: Bool, endFrame end: CGRect?, duration: Double) {
            self.duration = duration
            let measured = hideNote ? 0 : end.map(Self.windowOverlap) ?? 0
            overlap = measured
            isHiding = hideNote || measured <= 0
        }

        /// How far the keyboard's end frame (screen coordinates) reaches into the key window above its bottom safe area.
        /// Converting through the window handles iPad split views and floating keyboards; an off-screen frame gives 0.
        @MainActor private static func windowOverlap(_ frame: CGRect) -> Double {
            guard let window = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .flatMap(\.windows)
                .first(where: \.isKeyWindow)
            else { return Double(frame.height) }
            let local = window.convert(frame, from: window.screen.coordinateSpace)
            let covered = window.bounds.maxY - local.minY
            return max(0, Double(covered - window.safeAreaInsets.bottom))
        }
        #endif
    }

    func keyboardChanged(_ change: KeyboardChange) {
        apply(isHiding: change.isHiding, overlap: change.overlap, duration: change.duration)
    }

    /// Applies a keyboard change; `overlap` is already measured against the window's bottom safe area.
    func apply(isHiding: Bool, overlap: Double, duration: Double) {
        let animation = Self.keyboardAnimation(duration: duration)
        HaloMotion.animate(animation) {
            if isHiding || overlap <= 0 {
                keyboardOverlap = 0
                state.keyboardWillHide()
            } else {
                // A docked keyboard of usual size becomes the panel size; a hardware keyboard's shortcut bar does not.
                if overlap >= ComposerPanelMetrics.minimumHeight, !state.panelSearching, state.panel == nil {
                    lastKeyboardOverlap = overlap
                    #if canImport(UIKit)
                    KeyboardHeightMemory.remember(overlap, forWidth: Double(Self.keyWindow?.bounds.width ?? 0))
                    #endif
                }
                keyboardOverlap = overlap
                state.keyboardWillShow()
            }
        }
        if !isHiding, overlap > 0, state.lingeringPanel != nil {
            // The panel being replaced is fully covered once the keyboard animation ends.
            lingerTimeout?.cancel()
            lingerTimeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(max(duration, 0.05)))
                guard !Task.isCancelled else { return }
                self?.state.keyboardCoversLingeringPanel()
            }
        }
    }

    /// If no keyboard arrives (a hardware keyboard, or focus failed), the panel being replaced still goes.
    private func armLingerTimeout() {
        lingerTimeout?.cancel()
        lingerTimeout = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, let self, self.state.lingeringPanel != nil else { return }
            HaloMotion.animate(Self.keyboardAnimation(duration: 0.25)) { self.state.keyboardCoversLingeringPanel() }
        }
    }

    /// The system keyboard's motion, so the area under the composer moves with the keyboard (D102). Measured from the
    /// composer's drawn position while iOS moved it with the keyboard on an iPhone 16 (iOS 27, 60 Hz, 2026-11-23,
    /// `ComposerMotionTrace`): fraction moved per frame .02 .13 .27 .41 .54 .64 .73 .80 .85 .89, which a critically damped
    /// spring with ω ≈ 22/s matches within a frame. The often-quoted "mass 3, stiffness 1000, damping 500" is strongly
    /// overdamped and creeps in over half a second.
    public static func keyboardAnimation(duration: Double) -> Animation {
        HaloMotion.keyboard(duration: duration, reduceMotion: HaloMotion.systemReduceMotion)
    }

}

/// The docked keyboard's height, remembered for the whole app and across launches, per window width (portrait, landscape,
/// iPad split sizes). Each conversation's composer is new, so without this a panel opened before typing used a guess and
/// the message field moved when the real keyboard replaced it.
@MainActor
enum KeyboardHeightMemory {
    static let defaultsKey = "halo.composer.keyboardOverlaps"

    static func overlap(forWidth width: Double) -> Double? {
        guard width > 0 else { return nil }
        return load()[key(width)].flatMap { $0 > 0 ? $0 : nil }
    }

    static func remember(_ overlap: Double, forWidth width: Double) {
        guard width > 0, overlap > 0 else { return }
        var all = load()
        guard all[key(width)] != overlap else { return }
        all[key(width)] = overlap
        UserDefaults.standard.set(all, forKey: defaultsKey)
    }

    private static func key(_ width: Double) -> String { String(Int(width.rounded())) }

    private static func load() -> [String: Double] {
        UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: Double] ?? [:]
    }
}
#endif
