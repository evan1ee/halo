import HaloDomain
import Testing

@Suite("SyncEnergyPolicy (M19-7)")
struct SyncEnergyPolicyTests {
    @Test("normal conditions keep instant polling with headroom below the 15 s request timeout")
    func normalConditions() {
        let schedule = SyncEnergyPolicy.schedule(for: .init())
        #expect(schedule.longPollMilliseconds < SyncEnergyPolicy.requestTimeoutMilliseconds)
        #expect(schedule.longPollMilliseconds == 12_000)
        #expect(schedule.idleRest == .zero)
        #expect(schedule.minimumBackoff == .seconds(1))
        #expect(schedule.maximumBackoff == .seconds(60))
        #expect(schedule.backgroundRefreshInterval == 15 * 60)
        #expect(!schedule.pauseAuxiliaryWork)
    }

    @Test("Low Power Mode adds an idle rest, stretches backoff and background refresh, and pauses auxiliary work")
    func lowPowerMode() {
        let schedule = SyncEnergyPolicy.schedule(for: .init(lowPower: true))
        #expect(schedule.longPollMilliseconds < SyncEnergyPolicy.requestTimeoutMilliseconds)
        #expect(schedule.idleRest == .seconds(15))
        #expect(schedule.minimumBackoff == .seconds(3))
        #expect(schedule.maximumBackoff == .seconds(120))
        #expect(schedule.backgroundRefreshInterval == 45 * 60)
        #expect(schedule.pauseAuxiliaryWork)
    }

    @Test("thermal stress takes precedence over Low Power Mode with a longer rest and refresh interval")
    func thermalStress() {
        let schedule = SyncEnergyPolicy.schedule(for: .init(lowPower: true, isHot: true))
        #expect(schedule.idleRest == .seconds(25))
        #expect(schedule.minimumBackoff == .seconds(5))
        #expect(schedule.maximumBackoff == .seconds(120))
        #expect(schedule.backgroundRefreshInterval == 60 * 60)
        #expect(schedule.pauseAuxiliaryWork)
    }

    @Test("nextBackoff doubles and caps at maximumBackoff")
    func backoffProgression() {
        let schedule = SyncEnergyPolicy.schedule(for: .init(lowPower: true))
        #expect(SyncEnergyPolicy.nextBackoff(current: .seconds(1), schedule: schedule) == .seconds(6))
        #expect(SyncEnergyPolicy.nextBackoff(current: .seconds(6), schedule: schedule) == .seconds(12))
        #expect(SyncEnergyPolicy.nextBackoff(current: .seconds(90), schedule: schedule) == .seconds(120))
    }
}
