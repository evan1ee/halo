#if canImport(UIKit)
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Lets the message field take a pasted image (the keyboard's "Paste from Screenshots" suggestion, the edit menu's Paste).
///
/// SwiftUI's `TextField` is a plain-text `UITextView` that ignores images, so pasting one did nothing (founder: "Can not
/// sent the paste image"). Placed as the field's background, this finds that text view, lets it accept images, and hands
/// every pasted image to `onImages` as data; the image's placeholder character (U+FFFC) is then removed from the draft
/// by the caller (`ComposerImagePaste.placeholder`). The images join the composer's pending photos, so they are sent
/// like a picked photo (encrypted in encrypted rooms).
struct ComposerImagePaste: UIViewRepresentable {
    /// The character a text view puts where an image attachment is.
    static let placeholder: Character = "\u{FFFC}"

    let onImages: @MainActor ([Data]) -> Void

    func makeUIView(context: Context) -> Probe {
        let probe = Probe()
        probe.onImages = onImages
        return probe
    }

    func updateUIView(_ probe: Probe, context: Context) {
        probe.onImages = onImages
        probe.attachSoon()
    }

    final class Probe: UIView {
        var onImages: (@MainActor ([Data]) -> Void)?
        private weak var textView: UITextView?

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            isAccessibilityElement = false
        }

        required init?(coder: NSCoder) { nil }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            attachSoon()
        }

        /// The text view is created by SwiftUI next to this view; look for it once layout has run.
        func attachSoon() {
            guard textView == nil else { return }
            DispatchQueue.main.async { [weak self] in self?.attach() }
        }

        private func attach() {
            guard textView == nil, let window else { return }
            let frame = convert(bounds, to: window)
            var ancestor = superview
            for _ in 0..<6 {
                guard let current = ancestor else { break }
                if let found = Self.textView(in: current, overlapping: frame, window: window) {
                    configure(found)
                    return
                }
                ancestor = current.superview
            }
        }

        private static func textView(in view: UIView, overlapping frame: CGRect, window: UIWindow) -> UITextView? {
            if let textView = view as? UITextView, textView.convert(textView.bounds, to: window).intersects(frame) {
                return textView
            }
            for subview in view.subviews {
                if let found = textView(in: subview, overlapping: frame, window: window) { return found }
            }
            return nil
        }

        private func configure(_ textView: UITextView) {
            self.textView = textView
            // Plain text stays plain (the draft is a String); this only lets the paste command accept images.
            textView.allowsEditingTextAttributes = true
            textView.pasteConfiguration = UIPasteConfiguration(
                acceptableTypeIdentifiers: [UTType.image.identifier, UTType.plainText.identifier, UTType.utf8PlainText.identifier]
            )
            // Selector-based: removed with this view.
            NotificationCenter.default.addObserver(self, selector: #selector(collectImages), name: UITextView.textDidChangeNotification, object: textView)
        }

        @objc private func collectImages() {
            guard let text = textView?.attributedText, text.length > 0 else { return }
            var images: [Data] = []
            text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, _, _ in
                guard let attachment = value as? NSTextAttachment, let data = Self.data(of: attachment) else { return }
                images.append(data)
            }
            guard !images.isEmpty else { return }
            // Drop the attachments from the view at once; the caller strips the placeholder from the bound draft.
            let plain = NSMutableAttributedString(attributedString: text)
            plain.enumerateAttribute(.attachment, in: NSRange(location: 0, length: plain.length), options: .reverse) { value, range, _ in
                if value != nil { plain.deleteCharacters(in: range) }
            }
            textView?.attributedText = plain
            onImages?(images)
        }

        private static func data(of attachment: NSTextAttachment) -> Data? {
            if let contents = attachment.contents { return contents }
            if let file = attachment.fileWrapper?.regularFileContents { return file }
            let image = attachment.image ?? attachment.image(forBounds: attachment.bounds, textContainer: nil, characterIndex: 0)
            return image?.pngData()
        }
    }
}
#endif
