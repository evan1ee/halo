import Testing
@testable import HaloMatrixAdapter

@Suite("HaloMatrixAdapter")
struct AdapterSmokeTests {
    @Test("the adapter module links against the pinned SDK")
    func links() {}
}
