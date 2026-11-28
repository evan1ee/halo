import Foundation
import HaloDomain
import Testing

@Suite("Storage models & retention policy (D55, SETTINGS §3, M20-13)")
struct StorageModelsTests {
    @Test("D55 default media cache retention is 1 GB and 30 days with 50 MiB max file and daily cleanup")
    func defaultRetentionMatchesD55() {
        let policy = MediaCacheRetention.defaultPolicy
        #expect(policy.maxSize == .gb1)
        #expect(policy.maxSize.bytes == 1_073_741_824)
        #expect(policy.expiry == .days30)
        #expect(policy.expiry.seconds == TimeInterval(30 * 86_400))
        #expect(MediaCacheRetention.maxFileSizeBytes == 52_428_800)
        #expect(MediaCacheRetention.cleanupFrequencySeconds == 86_400)
    }

    @Test("unlimited size and never expiry map to nil limits")
    func unlimitedAndNeverLimits() {
        #expect(MediaCacheSizeLimit.unlimited.bytes == nil)
        #expect(MediaCacheExpiry.never.seconds == nil)
        #expect(MediaCacheSizeLimit.mb250.bytes == 250 * 1_048_576)
        #expect(MediaCacheSizeLimit.mb500.bytes == 500 * 1_048_576)
        #expect(MediaCacheSizeLimit.gb2.bytes == 2 * 1_073_741_824)
        #expect(MediaCacheExpiry.days7.seconds == TimeInterval(7 * 86_400))
        #expect(MediaCacheExpiry.days90.seconds == TimeInterval(90 * 86_400))
    }

    @Test("StoreSizeBreakdown clamps negative inputs and sums totalBytes")
    func storeSizeBreakdown() {
        let breakdown = StoreSizeBreakdown(
            mediaCacheBytes: 100,
            messagesBytes: 200,
            cryptoKeysBytes: 50,
            haloDatabaseBytes: -10
        )
        #expect(breakdown.haloDatabaseBytes == 0)
        #expect(breakdown.totalBytes == 350)
    }

    @Test("MediaCacheClearResult reports non-negative freed bytes")
    func clearResultFreedBytes() {
        let after = StoreSizeBreakdown(mediaCacheBytes: 10, messagesBytes: 200, cryptoKeysBytes: 50, haloDatabaseBytes: 20)
        let result = MediaCacheClearResult(beforeMediaBytes: 1_000, afterMediaBytes: 10, breakdown: after)
        #expect(result.freedBytes == 990)

        let grew = MediaCacheClearResult(beforeMediaBytes: 10, afterMediaBytes: 50, breakdown: after)
        #expect(grew.freedBytes == 0)
    }
}
