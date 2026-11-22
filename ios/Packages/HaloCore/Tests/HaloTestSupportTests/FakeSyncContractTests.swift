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

@Suite("FakeEncryptionPort honours the contract")
struct FakeEncryptionContractTests {
    @Test("a wrong key is rejected, the right key verifies the device")
    func contract() async throws {
        try await EncryptionPortContract.verifyRecovery(FakeEncryptionPort(recoveryKey: "abc"), recoveryKey: "abc")
    }

    @Test("an unverified device with recovery set up needs recovery; a verified one does not")
    func needsRecovery() {
        #expect(FakeEncryptionPort(recoveryKey: "k").status.needsRecovery)
        #expect(!FakeEncryptionPort(recoveryKey: "k", verified: true).status.needsRecovery)
        #expect(!FakeEncryptionPort(recoveryKey: nil).status.needsRecovery)
    }
}
