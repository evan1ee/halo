/// A deterministic random number generator (SplitMix64).
///
/// Used wherever randomness must be injectable so tests are deterministic: retry jitter
/// (ERROR_HANDLING §2 rule 4) and the seeded property tests (docs/testing/TEST_STRATEGY.md §1, which
/// print the seed on failure). Not suitable for anything security-related.
public struct SeededRandomNumberGenerator: RandomNumberGenerator, Sendable {
    public let seed: UInt64
    private var state: UInt64

    public init(seed: UInt64) {
        self.seed = seed
        self.state = seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
