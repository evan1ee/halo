#if canImport(UIKit) && DEBUG
import SwiftUI
import UIKit

/// Debug-only probe for the composer's real on-screen motion (docs/features/COMPOSER_PANELS.md AC-CP1).
///
/// XCUITest waits for animations to finish before it reads a frame, so it can't see a wobble during a keyboard/panel swap.
/// With the launch argument `-halo.debug.composerTrace YES`, a 1×1 marker inside the composer records its window position
/// from the *presentation* layer on every display frame (the position actually drawn, mid-animation included) and exposes
/// the last two seconds as the accessibility value of the element `composer-trace` ("y,y,y,…", newest last). Nothing is
/// recorded or shown otherwise, and Release builds don't contain it.
public struct ComposerMotionTrace: UIViewRepresentable {
    public static var isEnabled: Bool { UserDefaults.standard.bool(forKey: "halo.debug.composerTrace") }

    public init() {}

    public func makeUIView(context: Context) -> TraceView { TraceView() }
    public func updateUIView(_ uiView: TraceView, context: Context) {}

    public final class TraceView: UIView {
        private var link: CADisplayLink?
        private var samples: [Double] = []
        private static let capacity = 240

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            isAccessibilityElement = true
            accessibilityIdentifier = "composer-trace"
            accessibilityLabel = "Composer trace"
        }

        required init?(coder: NSCoder) { nil }

        override public var accessibilityValue: String? {
            get { samples.map { String(format: "%.1f", $0) }.joined(separator: ",") }
            set {}
        }

        override public func didMoveToWindow() {
            super.didMoveToWindow()
            link?.invalidate()
            link = nil
            guard window != nil else { return }
            let link = CADisplayLink(target: self, selector: #selector(tick))
            link.add(to: .main, forMode: .common)
            self.link = link
        }

        @objc private func tick() {
            guard let window, let presented = layer.presentation() else { return }
            let target = window.layer.presentation() ?? window.layer
            let y = Double(presented.convert(CGPoint.zero, to: target).y)
            samples.append(y)
            if samples.count > Self.capacity { samples.removeFirst(samples.count - Self.capacity) }
        }
    }
}
#endif
