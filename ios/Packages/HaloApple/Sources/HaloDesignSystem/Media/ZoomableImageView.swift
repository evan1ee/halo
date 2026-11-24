#if canImport(SwiftUI)
import SwiftUI
#if canImport(UIKit)
import UIKit
#if canImport(VisionKit)
import VisionKit
#endif

/// Native `UIScrollView`-backed pinch-to-zoom, double-tap-to-zoom, and VisionKit Live Text / Subject Lift / Visual Look Up
/// image viewer (MEDIA_ATTACHMENTS FR-1). Plays nicely inside a paged `TabView`: horizontal swipes pass through whenever
/// `zoomScale == minimumZoomScale`.
public struct ZoomableImageView: UIViewRepresentable {
    private let image: UIImage
    private let maximumZoomScale: CGFloat
    private let onSingleTap: (() -> Void)?
    private let onZoomChange: ((Bool) -> Void)?

    public init(
        image: UIImage,
        maximumZoomScale: CGFloat = 5.0,
        onSingleTap: (() -> Void)? = nil,
        onZoomChange: ((Bool) -> Void)? = nil
    ) {
        self.image = image
        self.maximumZoomScale = maximumZoomScale
        self.onSingleTap = onSingleTap
        self.onZoomChange = onZoomChange
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(onSingleTap: onSingleTap, onZoomChange: onZoomChange)
    }

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
        imageView.isUserInteractionEnabled = true
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
        context.coordinator.attachVisionKit(to: imageView, image: image)

        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(doubleTap)

        let singleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleSingleTap(_:)))
        singleTap.numberOfTapsRequired = 1
        singleTap.require(toFail: doubleTap)
        scroll.addGestureRecognizer(singleTap)

        return scroll
    }

    public func updateUIView(_ uiView: UIScrollView, context: Context) {
        context.coordinator.onSingleTap = onSingleTap
        context.coordinator.onZoomChange = onZoomChange
        if context.coordinator.imageView?.image !== image {
            context.coordinator.imageView?.image = image
            uiView.setZoomScale(1.0, animated: false)
            context.coordinator.notifyZoom(isZoomed: false)
            context.coordinator.analyze(image)
        }
    }

    @MainActor
    public final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var imageView: UIImageView?
        weak var scrollView: UIScrollView?
        var onSingleTap: (() -> Void)?
        var onZoomChange: ((Bool) -> Void)?
        private var lastReportedZoomed = false

        #if canImport(VisionKit)
        private var interaction: ImageAnalysisInteraction?
        private var analysisTask: Task<Void, Never>?
        #endif

        init(onSingleTap: (() -> Void)?, onZoomChange: ((Bool) -> Void)?) {
            self.onSingleTap = onSingleTap
            self.onZoomChange = onZoomChange
        }

        deinit {
            #if canImport(VisionKit)
            analysisTask?.cancel()
            #endif
        }

        func attachVisionKit(to imageView: UIImageView, image: UIImage) {
            #if canImport(VisionKit)
            guard ImageAnalyzer.isSupported else { return }
            let interaction = ImageAnalysisInteraction()
            interaction.preferredInteractionTypes = [.automatic]
            imageView.addInteraction(interaction)
            self.interaction = interaction
            analyze(image)
            #endif
        }

        func analyze(_ image: UIImage) {
            #if canImport(VisionKit)
            analysisTask?.cancel()
            guard let interaction, ImageAnalyzer.isSupported else { return }
            interaction.analysis = nil
            analysisTask = Task { [weak interaction] in
                let analyzer = ImageAnalyzer()
                let configuration = ImageAnalyzer.Configuration([.text, .machineReadableCode, .visualLookUp])
                guard let analysis = try? await analyzer.analyze(image, configuration: configuration),
                      !Task.isCancelled else { return }
                interaction?.analysis = analysis
            }
            #endif
        }

        public func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

        public func scrollViewDidZoom(_ scrollView: UIScrollView) {
            notifyZoom(isZoomed: scrollView.zoomScale > scrollView.minimumZoomScale + 0.01)
        }

        func notifyZoom(isZoomed: Bool) {
            guard isZoomed != lastReportedZoomed else { return }
            lastReportedZoomed = isZoomed
            onZoomChange?(isZoomed)
        }

        @objc func handleSingleTap(_ gesture: UITapGestureRecognizer) {
            #if canImport(VisionKit)
            if let interaction, let imageView {
                let pt = gesture.location(in: imageView)
                if interaction.hasInteractiveItem(at: pt) { return }
            }
            #endif
            onSingleTap?()
        }

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
