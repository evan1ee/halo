#if canImport(UIKit)
import HaloDesignSystem
import HaloFoundation
import UIKit
import XCTest

/// Decoding a photo thumbnail and a sticker shows up as an `image-decode` interval (LOGGING_AND_DIAGNOSTICS §5).
final class ImageDecodeSignpostTests: XCTestCase {
    private var png: Data { UIGraphicsImageRenderer(size: CGSize(width: 600, height: 600)).pngData { $0.fill(CGRect(x: 0, y: 0, width: 600, height: 600)) } }

    func testThumbnailIsTimed() {
        let data = png
        assertTimed {
            let done = expectation(description: "decoded")
            Task {
                _ = await StickerImage.decodeThumbnail(data, maxPixelSize: 100, animated: false)
                done.fulfill()
            }
            wait(for: [done], timeout: 10)
        }
    }

    func testStickerIsTimed() {
        let data = png
        assertTimed { _ = StickerImage.decode(data, animated: true) }
    }

    private func assertTimed(_ work: () -> Void) {
        ImageDecodeReader.count = 0
        let options = XCTMeasureOptions()
        options.iterationCount = 1
        let reader = ImageDecodeReader(subsystem: HaloSignpost.subsystem, category: HaloSignpost.category, name: SignpostInterval.imageDecode.rawValue)
        measure(metrics: [reader], options: options, block: work)
        XCTAssertGreaterThan(ImageDecodeReader.count, 0, "no image-decode interval was recorded")
    }
}

private final class ImageDecodeReader: XCTOSSignpostMetric {
    nonisolated(unsafe) static var count = 0

    override func reportMeasurements(
        from startTime: XCTPerformanceMeasurementTimestamp, to endTime: XCTPerformanceMeasurementTimestamp
    ) throws -> [XCTPerformanceMeasurement] {
        let found = try super.reportMeasurements(from: startTime, to: endTime)
        Self.count += found.count
        return found
    }
}
#endif
