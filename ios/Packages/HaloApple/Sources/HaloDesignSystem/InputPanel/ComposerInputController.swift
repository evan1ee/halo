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
    public var panelHeight: Double { ComposerPanelMetrics.panelHeight(lastKeyboardOverlap: lastKeyboardOverlap) }

    /// The height the panel area under the composer has right now.
    public var areaHeight: Double {
        ComposerPanelMetrics.areaHeight(state: state, panelHeight: panelHeight, keyboardOverlap: keyboardOverlap)
    }

    // MARK: Events from the composer, the panels and the timeline

    public func fieldFocusChanged(_ focused: Bool) {
        if focused {
            guard state.mode != .keyboard else { return }
            withAnimation(Self.keyboardAnimation(duration: 0.25)) { state.fieldFocused() }
            armLingerTimeout()
        } else {
            state.fieldUnfocused()
        }
    }

    /// The composer's button for `panel`.
    public func toggle(_ panel: ComposerPanel) {
        let opening = state.panel != panel
        withAnimation(Self.keyboardAnimation(duration: 0.25)) { state.toggle(panel) }
        if !opening { armLingerTimeout() }
    }

    public func open(_ panel: ComposerPanel) {
        withAnimation(Self.keyboardAnimation(duration: 0.25)) { state.open(panel) }
    }

    /// Closes the keyboard or panel (a tap or drag on the conversation).
    public func dismiss() {
        guard state.mode != .idle || state.displayedPanel != nil else { return }
        withAnimation(Self.keyboardAnimation(duration: 0.25)) { state.dismiss() }
        #if canImport(UIKit)
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        #endif
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
        withAnimation(animation) {
            if isHiding || overlap <= 0 {
                keyboardOverlap = 0
                state.keyboardWillHide()
            } else {
                // A docked keyboard of usual size becomes the panel size; a hardware keyboard's shortcut bar does not.
                if overlap >= ComposerPanelMetrics.minimumHeight, !state.panelSearching, state.panel == nil {
                    lastKeyboardOverlap = overlap
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
            withAnimation(Self.keyboardAnimation(duration: 0.25)) { self.state.keyboardCoversLingeringPanel() }
        }
    }

    /// The system keyboard's curve (UIKit's undocumented curve 7), so panel changes move together with the keyboard.
    public static func keyboardAnimation(duration: Double) -> Animation {
        duration <= 0 ? .linear(duration: 0) : .interpolatingSpring(mass: 3, stiffness: 1000, damping: 500, initialVelocity: 0)
    }

}
#endif
