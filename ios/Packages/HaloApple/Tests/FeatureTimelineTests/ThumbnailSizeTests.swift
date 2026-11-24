#if canImport(UIKit)
import SwiftUI
import Testing
import UIKit
@testable import FeatureTimeline

/// A photo row must not change height when its picture loads: a lazy list re-measuring a row while it scrolls to the newest
/// message drops its measurements and lands near the top of the room (S10, D95).
@MainActor
@Suite("ThumbnailSize")
struct ThumbnailSizeTests {
    private func size(_ view: some View) -> CGSize {
        UIHostingController(rootView: view).sizeThatFits(in: CGSize(width: 400, height: 2_000))
    }

    private var widePicture: UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 400, height: 100)).image { context in
            UIColor.purple.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 400, height: 100))
        }
    }

    @Test("a photo without an announced size keeps its 4:3 box when the picture loads")
    func unknownSizeKeepsBox() {
        let placeholder = size(Rectangle().fill(.gray).modifier(ThumbnailSize(isSticker: false, aspectRatio: nil)))
        let loaded = size(Image(uiImage: widePicture).resizable().scaledToFit().modifier(ThumbnailSize(isSticker: false, aspectRatio: nil)))
        #expect(placeholder == CGSize(width: 400, height: 300))
        #expect(loaded == placeholder)
    }

    @Test("a photo with an announced size keeps that shape whatever the picture turns out to be")
    func announcedSizeKeepsBox() {
        let placeholder = size(Rectangle().fill(.gray).modifier(ThumbnailSize(isSticker: false, aspectRatio: 0.5)))
        let loaded = size(Image(uiImage: widePicture).resizable().scaledToFit().modifier(ThumbnailSize(isSticker: false, aspectRatio: 0.5)))
        #expect(placeholder == CGSize(width: 400, height: 800))
        #expect(loaded == placeholder)
    }
}
#endif
