import Testing

@testable import FeatureSettings

@MainActor
@Suite("ChangePasswordModel")
struct ChangePasswordTests {
    final class Recorder: @unchecked Sendable {  // test double touched from one test at a time
        var outcome = ChangePasswordActions.Outcome.changed
        var sent: [(String, String)] = []
    }

    func model(_ recorder: Recorder) -> ChangePasswordModel {
        ChangePasswordModel(actions: .init(isAvailable: { true }, submit: { current, new in
            recorder.sent.append((current, new))
            return recorder.outcome
        }))
    }

    @Test("the form can be sent only with a current password and a matching, different, long-enough new one; the hint says what is wrong")
    func validation() {
        let model = model(Recorder())
        #expect(!model.canSubmit && model.hint == nil)
        model.current = "old-password"
        model.new = "short"
        #expect(!model.canSubmit && model.hint == "Use at least 8 characters.")
        model.new = "old-password"
        #expect(model.hint == "The new password must differ from the current one.")
        model.new = "a-better-one"
        model.confirmation = "a-better-on"
        #expect(!model.canSubmit && model.hint == "The two new passwords don't match.")
        model.confirmation = "a-better-one"
        #expect(model.canSubmit && model.hint == nil)
    }

    @Test("a change sends both passwords once and clears the fields; each failure has its own message and keeps the fields")
    func submitting() async {
        let recorder = Recorder()
        let model = model(recorder)
        model.current = "old-password"
        model.new = "a-better-one"
        model.confirmation = "a-better-one"
        recorder.outcome = .wrongCurrent
        await model.submit()
        #expect(model.error == "The current password is wrong." && !model.isDone && model.new == "a-better-one")
        recorder.outcome = .refusedNew
        await model.submit()
        #expect(model.error?.hasPrefix("The server didn't accept") == true)
        recorder.outcome = .failed
        await model.submit()
        #expect(model.error?.hasPrefix("The password couldn't be changed") == true)
        recorder.outcome = .changed
        await model.submit()
        #expect(model.isDone && model.error == nil && model.current.isEmpty && model.new.isEmpty && model.confirmation.isEmpty)
        #expect(recorder.sent.count == 4 && recorder.sent[3].0 == "old-password" && recorder.sent[3].1 == "a-better-one")
    }
}
