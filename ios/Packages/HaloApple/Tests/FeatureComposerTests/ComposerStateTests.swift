import FeatureComposer
import Testing

@Suite("ComposerRules (FeatureComposer)")
struct ComposerStateTests {
    @Test("canSend allows non-blank draft or pending photos, and blocks while busy")
    func sendEligibility() {
        #expect(ComposerRules.maxLineCount == 6)
        #expect(ComposerRules.canSend(draft: "", pendingPhotoCount: 0, isBusy: false) == false)
        #expect(ComposerRules.canSend(draft: "   \n ", pendingPhotoCount: 0, isBusy: false) == false)
        #expect(ComposerRules.canSend(draft: "hi", pendingPhotoCount: 0, isBusy: false) == true)
        #expect(ComposerRules.canSend(draft: "", pendingPhotoCount: 1, isBusy: false) == true)
        #expect(ComposerRules.canSend(draft: "hi", pendingPhotoCount: 1, isBusy: true) == false)
    }
}
