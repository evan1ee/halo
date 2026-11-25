import HaloDesignSystem
import Testing

@Suite("ActionState double-tap guard (TD-07)")
struct ActionStateTests {
    @Test("Ignores concurrent double-taps while an action is in flight and resets when finished")
    @MainActor
    func preventsDoubleTap() async {
        let state = ActionState()
        var runs = 0

        let started = state.run {
            runs += 1
            for _ in 0..<20 { await Task.yield() }
        }
        let duplicate = state.run {
            runs += 1
        }
        #expect(started == true)
        #expect(duplicate == false)
        #expect(state.isRunning == true)

        for _ in 0..<500 where state.isRunning { await Task.yield() }
        #expect(state.isRunning == false)
        #expect(runs == 1)

        // After completion, a subsequent tap runs normally.
        let second = state.run { runs += 1 }
        #expect(second == true)
        for _ in 0..<500 where state.isRunning { await Task.yield() }
        #expect(runs == 2)
    }

    @Test("cancel resets isRunning and cancels the in-flight task")
    @MainActor
    func cancelStopsInFlight() async {
        let state = ActionState()
        _ = state.run {
            try? await Task.sleep(for: .seconds(10))
        }
        #expect(state.isRunning == true)
        state.cancel()
        #expect(state.isRunning == false)
    }

    @MainActor
    final class Box { var runs = 0; var gate: CheckedContinuation<Void, Never>? }

    @Test("a keyed action runs once while it is running; another key runs alongside; the key is free again afterwards")
    @MainActor
    func keyedGuard() async {
        let guardTaps = ActionGuard()
        let box = Box()
        let first = Task { @MainActor in
            await guardTaps.run("delete:a") {
                box.runs += 1
                await withCheckedContinuation { box.gate = $0 }
            }
        }
        while box.gate == nil { await Task.yield() }
        #expect(guardTaps.isRunning("delete:a"))
        let second = await guardTaps.run("delete:a") { box.runs += 1 }
        let other = await guardTaps.run("delete:b") { box.runs += 1 }
        #expect(second == false && other == true && box.runs == 2)
        box.gate?.resume()
        #expect(await first.value)
        #expect(!guardTaps.isRunning("delete:a"))
        #expect(await guardTaps.run("delete:a") { box.runs += 1 })
        #expect(box.runs == 3)
    }
}
