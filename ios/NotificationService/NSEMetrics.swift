import Darwin
import Foundation

/// Measurements for the G-NSE gate (docs/features/NOTIFICATIONS.md §11): one JSON line per push in the App Group
/// container (`nse-metrics.jsonl`), with step durations and the process's memory footprint. No content, no identifiers.
struct NSEMetrics {
    private let start = ContinuousClock.now
    private var steps: [(String, Int)] = []
    private var last = ContinuousClock.now

    mutating func step(_ name: String) {
        let now = ContinuousClock.now
        steps.append((name, Self.milliseconds(now - last)))
        last = now
    }

    /// Cap the metrics log at 128 KB (+ one `.prev` rotation, ≤ 256 KB total) so it never grows unbounded (R-27).
    private static let maxBytes: UInt64 = 128 * 1024

    func write(outcome: String, appGroup: String) {
        var object: [String: Any] = [
            "at": ISO8601DateFormatter().string(from: Date()),
            "outcome": outcome,
            "totalMs": Self.milliseconds(ContinuousClock.now - start),
            "footprintMB": Self.footprintMB(),
        ]
        for (name, ms) in steps { object["\(name)Ms"] = ms }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) else { return }
        let file = container.appendingPathComponent("nse-metrics.jsonl")
        let fm = FileManager.default
        if let attrs = try? fm.attributesOfItem(atPath: file.path),
           let size = attrs[.size] as? UInt64, size >= Self.maxBytes {
            let rotated = container.appendingPathComponent("nse-metrics.prev.jsonl")
            try? fm.removeItem(at: rotated)
            try? fm.moveItem(at: file, to: rotated)
        }
        var line = data
        line.append(0x0A)
        if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: file)
        }
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        let parts = duration.components
        return Int(parts.seconds) * 1000 + Int(parts.attoseconds / 1_000_000_000_000_000)
    }

    /// `phys_footprint` is the number iOS compares against the extension's memory limit.
    private static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        guard result == KERN_SUCCESS else { return -1 }
        return (Double(info.phys_footprint) / 1_048_576 * 10).rounded() / 10
    }
}
