import Foundation
import Testing
@testable import HaloMatrixAdapter

@Suite("MatrixPushPort payload")
struct PushPayloadTests {
    @Test("the default payload asks for the extension, is generic, and never carries a badge (ADR-0015)")
    func payload() throws {
        let object = try #require(JSONSerialization.jsonObject(with: Data(MatrixPushPort.defaultPayload.utf8)) as? [String: Any])
        let aps = try #require(object["aps"] as? [String: Any])
        #expect(aps["mutable-content"] as? Int == 1)
        #expect(aps["badge"] == nil)
        #expect(aps["alert"] != nil)
    }
}
