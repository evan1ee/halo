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
