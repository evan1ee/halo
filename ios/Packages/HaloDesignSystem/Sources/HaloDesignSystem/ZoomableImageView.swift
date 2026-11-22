#if canImport(SwiftUI)
import SwiftUI
#if canImport(UIKit)
import UIKit

/// Native `UIScrollView`-backed pinch-to-zoom and double-tap-to-zoom image viewer (MEDIA_ATTACHMENTS FR-1).
/// Plays nicely inside a paged `TabView`: horizontal swipes pass through whenever `zoomScale == minimumZoomScale`.
public struct ZoomableImageView: UIViewRepresentable {
    private let image: UIImage
    private let maximumZoomScale: CGFloat

    public init(image: UIImage, maximumZoomScale: CGFloat = 5.0) {
        self.image = image
        self.maximumZoomScale = maximumZoomScale
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public func makeUIView(context: Context) -> UIScrollView {
        let scroll = UIScrollView()
        scroll.delegate = context.coordinator
        scroll.minimumZoomScale = 1.0
        scroll.maximumZoomScale = maximumZoomScale
        scroll.bouncesZoom = true
        scroll.showsVerticalScrollIndicator = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.backgroundColor = .clear
        scroll.contentInsetAdjustmentBehavior = .never

        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(imageView)

        NSLayoutConstraint.activate([
            imageView.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
            imageView.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
            imageView.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
        ])

        context.coordinator.imageView = imageView
        context.coordinator.scrollView = scroll

        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(doubleTap)
        return scroll
    }

    public func updateUIView(_ uiView: UIScrollView, context: Context) {
        if context.coordinator.imageView?.image !== image {
            context.coordinator.imageView?.image = image
            uiView.setZoomScale(1.0, animated: false)
        }
    }

    @MainActor
    public final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var imageView: UIImageView?
        weak var scrollView: UIScrollView?

        public func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scrollView, let imageView else { return }
            if scrollView.zoomScale > scrollView.minimumZoomScale + 0.01 {
                scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
            } else {
                let targetScale: CGFloat = min(2.5, scrollView.maximumZoomScale)
                let point = gesture.location(in: imageView)
                let size = CGSize(
                    width: scrollView.bounds.width / targetScale,
                    height: scrollView.bounds.height / targetScale
                )
                let origin = CGPoint(x: point.x - size.width / 2, y: point.y - size.height / 2)
                scrollView.zoom(to: CGRect(origin: origin, size: size), animated: true)
            }
        }
    }
}
#endif
#endif
