#if canImport(UIKit) && canImport(QuickLook)
import QuickLook
import SwiftUI

/// Quick Look for one local file: previews documents and images, plays audio and video, and offers share and save.
public struct QuickLookView: UIViewControllerRepresentable {
    public let url: URL

    public init(url: URL) { self.url = url }

    /// In a navigation controller, because Quick Look shows its title and its share button only there.
    public func makeUIViewController(context: Context) -> UINavigationController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return UINavigationController(rootViewController: controller)
    }

    public func updateUIViewController(_ navigation: UINavigationController, context: Context) {
        context.coordinator.url = url
        (navigation.viewControllers.first as? QLPreviewController)?.reloadData()
    }

    public func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    public final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL
        init(url: URL) { self.url = url }
        public func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        public func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem { url as NSURL }
    }
}
#endif
