import Foundation
import HaloDomain
import Testing
@testable import HaloTestSupport

@Suite("FakeSyncPort honours the contract")
struct FakeSyncContractTests {
    @Test("start, repeat start, stop, repeat stop")
    func contract() async throws {
        let port = FakeSyncPort()
        try await SyncPortContract.verify(port)
        #expect(port.status == .stopped)
    }
}

@Suite("FakeMediaPort honours the contract")
struct FakeMediaContractTests {
    @Test("existing media loads, missing media is not found")
    func contract() async throws {
        let port = FakeMediaPort()
        let existing = MediaRef(token: "a")
        port.add(existing, data: Data([1, 2, 3]))
        try await MediaPortContract.verify(port, existing: existing, missing: MediaRef(token: "gone"))
    }
}
