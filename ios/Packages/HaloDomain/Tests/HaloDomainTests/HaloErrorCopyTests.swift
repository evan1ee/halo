import HaloDomain
import HaloFoundation
import Testing

@Suite("HaloErrorCopy (DESIGN_SYSTEM §12, UX-15)")
struct HaloErrorCopyTests {
    @Test("Every HaloError case maps to a non-empty plain-language sentence without raw error codes")
    func allCasesHavePlainCopy() {
        let samples: [HaloError] = [
            .network(retryable: true),
            .network(retryable: false),
            .unauthorized(soft: true),
            .unauthorized(soft: false),
            .forbidden,
            .notFound,
            .crypto(.missingKeys),
            .crypto(.unverifiedDevice),
            .crypto(.noBackup),
            .crypto(.verificationFailed),
            .invalidInput("RAW_FIELD_CODE"),
            .unsupported("MISSING_MSC"),
            .storage(.unavailable),
            .storage(.corrupted),
            .storage(.migrationFailed),
            .cancelled,
            .internal(code: "INTERNAL_500"),
        ]

        for error in samples {
            let text = HaloErrorCopy.message(for: error)
            #expect(!text.isEmpty)
            #expect(!text.contains("RAW_"))
            #expect(!text.contains("INTERNAL_500"))
            #expect(!text.contains("MISSING_MSC"))
        }
    }
}
