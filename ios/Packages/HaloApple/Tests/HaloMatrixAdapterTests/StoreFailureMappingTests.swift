import HaloFoundation
import Testing
@testable import HaloMatrixAdapter

@Suite("Store failure mapping")
struct StoreFailureMappingTests {
    @Test("what the SDK said for garbage files and a wrong passphrase is damage; other build failures stay internal (AC-REL-5)")
    func classification() {
        // The texts are the ones `StoreRecoveryContractTests` provoked.
        #expect(ErrorMapper.buildFailure("Error occurred while creating a new object: disk I/O error") == .storage(.corrupted))
        #expect(ErrorMapper.buildFailure("Failed to initialize the store cipher: Error encrypting or decrypting a value: `aead::Error`") == .storage(.corrupted))
        #expect(ErrorMapper.buildFailure("file is not a database") == .storage(.corrupted))
        #expect(ErrorMapper.buildFailure("database disk image is malformed") == .storage(.corrupted))
        #expect(ErrorMapper.buildFailure("the homeserver sent an unexpected response") == .internal(code: "SDK_BUILD"))
        #expect(ErrorMapper.buildFailure("unable to open database file") == .internal(code: "SDK_BUILD"), "unreadable for now is not damage")
    }
}
