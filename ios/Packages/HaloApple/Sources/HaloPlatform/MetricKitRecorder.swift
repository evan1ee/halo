#if os(iOS)
import Foundation
import MetricKit

/// Receives MetricKit's payloads (about once a day; crashes and hangs at the next launch) and keeps them in a `MetricPayloadStore`.
/// Create one at launch and keep it: iOS delivers only while a subscriber exists.
public final class MetricKitRecorder: NSObject, MXMetricManagerSubscriber, Sendable {
    private let store: MetricPayloadStore

    public init(store: MetricPayloadStore) {
        self.store = store
        super.init()
    }

    public func start() { MXMetricManager.shared.add(self) }

    public func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads { store.save(payload.jsonRepresentation(), kind: .metrics) }
    }

    public func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads { store.save(payload.jsonRepresentation(), kind: .diagnostics) }
    }
}
#endif
