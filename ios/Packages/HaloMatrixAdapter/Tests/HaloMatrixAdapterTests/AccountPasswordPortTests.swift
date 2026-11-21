import Foundation
import HaloFoundation
import Testing
@testable import HaloMatrixAdapter

@Suite("MatrixAccountPasswordPort")
struct AccountPasswordPortTests {
    private func body(_ code: String) -> Data { Data(#"{"errcode":"\#(code)","error":"x"}"#.utf8) }

    @Test("a wrong current password, a refused new password, throttling and server trouble are told apart")
    func errors() {
        let error = MatrixAccountPasswordPort.error(status:body:)
        #expect(error(401, body("M_FORBIDDEN")) == .invalidInput("CURRENT_PASSWORD"))
        #expect(error(403, body("M_FORBIDDEN")) == .invalidInput("CURRENT_PASSWORD"))
        #expect(error(400, body("M_WEAK_PASSWORD")) == .invalidInput("NEW_PASSWORD"))
        #expect(error(400, body("M_PASSWORD_TOO_SHORT")) == .invalidInput("NEW_PASSWORD"))
        #expect(error(403, body("M_SOMETHING")) == .forbidden)
        #expect(error(429, body("M_LIMIT_EXCEEDED")) == .network(retryable: true))
        #expect(error(502, Data()) == .network(retryable: true))
        #expect(error(400, body("M_UNKNOWN")) == .internal(code: "PASSWORD_HTTP"))
    }
}
