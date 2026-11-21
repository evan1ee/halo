import Foundation
import Testing
@testable import HaloPlatform

@Suite("DarwinSignal")
struct DarwinSignalTests {
    @Test("posting a Darwin signal wakes observers on the same name")
    func signals() async throws {
        let name = "one.mbm.halo.test.\(UUID().uuidString)"
        let receiver = DarwinSignal(name: name)
        let sender = DarwinSignal(name: name)
        let stream = receiver.observe()
        let waiter = Task { () -> Bool in
            for await _ in stream { return true }
            return false
        }
        sender.post()
        let timeout = Task { try? await Task.sleep(for: .seconds(5)); waiter.cancel() }
        let fired = await waiter.value
        timeout.cancel()
        #expect(fired)
    }
}
