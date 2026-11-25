import Testing
@testable import HaloFoundation

@Suite("HaloSignpost")
struct HaloSignpostTests {
    @Test("measure returns the result and passes errors through")
    func measure() {
        #expect(HaloSignpost.measure(.imageDecode) { 42 } == 42)
        #expect(throws: HaloError.unauthorized(soft: false)) {
            try HaloSignpost.measure(.imageDecode) { () throws(HaloError) in throw HaloError.unauthorized(soft: false) }
        }
    }

    #if canImport(os)
    @Test("The signpost's literal name is the raw value", arguments: SignpostInterval.allCases)
    func name(_ interval: SignpostInterval) {
        #expect("\(interval.signpostName)" == interval.rawValue)
    }
    #endif
}

#if canImport(os)
import XCTest

/// Reads the intervals back the way the performance suite does (`XCTOSSignpostMetric`).
final class HaloSignpostMetricTests: XCTestCase {
    func testColdStartIsRecorded() { assertRecorded(.coldStart) }
    func testRoomOpenIsRecorded() { assertRecorded(.roomOpen) }
    func testSyncCatchUpIsRecorded() { assertRecorded(.syncCatchUp) }
    func testSyncLongPollIsRecorded() { assertRecorded(.syncLongPoll) }
    func testImageDecodeIsRecorded() { assertRecorded(.imageDecode) }
    func testNotificationServiceIsRecorded() { assertRecorded(.notificationService) }

    private func assertRecorded(_ interval: SignpostInterval) {
        CapturingMetric.durations = []
        let options = XCTMeasureOptions()
        options.iterationCount = 1
        let metric = CapturingMetric(subsystem: HaloSignpost.subsystem, category: HaloSignpost.category, name: interval.rawValue)
        measure(metrics: [metric], options: options) {
            let running = HaloSignpost.begin(interval)
            usleep(20_000)
            running.end()
            running.end()  // only the first call counts
        }
        XCTAssertFalse(CapturingMetric.durations.isEmpty, "no \(interval.rawValue) interval was recorded")
        for duration in CapturingMetric.durations {
            XCTAssertGreaterThanOrEqual(duration, 0.019)
            XCTAssertLessThan(duration, 1)
        }
    }
}

/// Keeps what the metric reports; `measure` itself doesn't hand it back. (XCTest copies metrics, hence the static.)
private final class CapturingMetric: XCTOSSignpostMetric {
    nonisolated(unsafe) static var durations: [Double] = []

    override func reportMeasurements(
        from startTime: XCTPerformanceMeasurementTimestamp, to endTime: XCTPerformanceMeasurementTimestamp
    ) throws -> [XCTPerformanceMeasurement] {
        let found = try super.reportMeasurements(from: startTime, to: endTime)
        Self.durations += found.map(\.value.value)
        return found
    }
}
#endif
