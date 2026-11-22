import Foundation
import HaloDomain
import HaloFoundation
import Testing
@testable import HaloMatrixAdapter

@Suite("MatrixDevicesPort")
struct DevicesPortTests {
    private func json(_ text: String) -> Data { Data(text.utf8) }

    @Test("the current device comes first, then the most recently seen; empty names and missing times are tolerated")
    func parsing() throws {
        let data = json("""
        {"devices":[
          {"device_id":"OLD","display_name":"Old phone","last_seen_ts":1000000,"last_seen_ip":"10.0.0.1"},
          {"device_id":"NEW","display_name":"","last_seen_ts":9000000},
          {"device_id":"ME","display_name":"Halo (iPhone)"},
          {"device_id":"NEVER"}
        ]}
        """)
        let devices = try MatrixDevicesPort.parse(data, currentDeviceID: "ME")
        #expect(devices.map(\.id) == ["ME", "NEW", "OLD", "NEVER"])
        #expect(devices[0].isCurrent && !devices[1].isCurrent)
        #expect(devices[1].displayName == nil)
        #expect(devices[2].lastSeen == Date(timeIntervalSince1970: 1000))
        #expect(devices[3].lastSeen == nil)
    }

    @Test("a body that isn't a device list is an internal error")
    func malformed() {
        #expect(throws: HaloError.internal(code: "DEVICES_DECODE")) { try MatrixDevicesPort.parse(json("{}"), currentDeviceID: "x") }
    }
}
