import HaloDomain
import HaloFoundation
import MatrixRustSDK
import Testing
@testable import HaloMatrixAdapter

@Suite("Send failure mapping")
struct SendFailureMappingTests {
    @Test("every reason the SDK gives keeps its meaning; only unverified devices and changed identities can be sent anyway (AC-SEC-2)")
    func reasons() throws {
        let bob = try UserID("@bob:x.org")
        let carol = try UserID("@carol:x.org")
        #expect(TimelineMapper.failure(of: .insecureDevices(userDeviceMap: ["@carol:x.org": ["D1"], "@bob:x.org": ["D2", "D3"]]))
            == .unverifiedDevices(users: [bob, carol]))
        #expect(TimelineMapper.failure(of: .identityViolations(users: ["@carol:x.org"])) == .identityChanged(users: [carol]))
        #expect(TimelineMapper.failure(of: .crossVerificationRequired) == .needsVerification)
        #expect(TimelineMapper.failure(of: .expiredAccessToken) == .sessionExpired)
        #expect(TimelineMapper.failure(of: .missingMediaContent) == .mediaGone)
        #expect(TimelineMapper.failure(of: .invalidMimeType(mimeType: "x")) == .other)
        #expect(TimelineMapper.failure(of: .genericApiError(msg: "boom")) == .other)
        let anyway = [SendFailure.unverifiedDevices(users: []), .identityChanged(users: [])].allSatisfy(\.canSendAnyway)
        #expect(anyway)
        let never = [SendFailure.needsVerification, .sessionExpired, .mediaGone, .other].map(\.canSendAnyway)
        #expect(never == [false, false, false, false])
    }
}
