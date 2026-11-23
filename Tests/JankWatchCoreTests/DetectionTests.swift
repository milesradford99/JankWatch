import XCTest
@testable import JankWatchCore

final class SignalTests: XCTestCase {
    let eval = SignalEvaluator(config: JankConfig())

    func calmBaseline() -> ProbeBaseline {
        var b = ProbeBaseline()
        for _ in 0..<100 { b.observeCalm(Fx.probe(p95: 2, work: 0.2), config: JankConfig()) }
        return b
    }

    func testCalmTickScoresZero() {
        let s = eval.evaluate(Fx.tick(1), baseline: calmBaseline())
        XCTAssertEqual(s.total, 0)
        XCTAssertFalse(s.isLagTick)
    }

    func testProbeModeratePlusInputModerateIsLag() {
        let tick = Fx.tick(1, probe: Fx.probe(p95: 10), input: Fx.input(max: 90, moderate: 1))
        let s = eval.evaluate(tick, baseline: calmBaseline())  // threshold max(8, 2*4)=8
        XCTAssertEqual(s.probeScore, 0.5)
        XCTAssertEqual(s.inputScore, 0.5)
        XCTAssertTrue(s.isLagTick)
    }

    func testSingleModerateSignalIsNotLag() {
        let s = eval.evaluate(Fx.tick(1, probe: Fx.probe(p95: 10)), baseline: calmBaseline())
        XCTAssertEqual(s.total, 0.5)
        XCTAssertFalse(s.isLagTick)
    }

    func testSevereSignalAloneIsLag() {
        XCTAssertTrue(eval.evaluate(Fx.tick(1, probe: Fx.probe(p95: 80)), baseline: calmBaseline()).isLagTick)
        XCTAssertTrue(eval.evaluate(Fx.tick(1, input: Fx.input(max: 300, moderate: 1, severe: 1)), baseline: calmBaseline()).isLagTick)
        // Starved probe thread: only 5 of 20 expected wake-ups.
        let starved = eval.evaluate(Fx.tick(1, probe: Fx.probe(p95: 1, samples: 5)), baseline: calmBaseline())
        XCTAssertEqual(starved.probeScore, 1)
        XCTAssertTrue(starved.reasons.contains("probe.starved"))
    }

    func testWorkInflation() {
        let s = eval.evaluate(Fx.tick(1, probe: Fx.probe(p95: 1, work: 0.7)), baseline: calmBaseline())  // 3.5x
        XCTAssertEqual(s.probeScore, 1)
        XCTAssertTrue(s.reasons.contains("probe.work.severe"))
    }

    func testFrontAppHung() {
        let front = FrontAppStats(pid: 42, bundleID: "x", name: "X", bundlePath: nil, maxRoundTripMs: 260, timedOut: true)
        let s = eval.evaluate(Fx.tick(1, front: front), baseline: calmBaseline())
        XCTAssertEqual(s.frontScore, 1)
        XCTAssertTrue(s.isLagTick)
    }

    func testInactiveUserNeverLag() {
        let s = eval.evaluate(Fx.tick(1, active: false, probe: Fx.probe(p95: 200)), baseline: calmBaseline())
        XCTAssertFalse(s.isLagTick)
        let off = eval.evaluate(Fx.tick(1, gate: .idle, probe: Fx.probe(p95: 200)), baseline: calmBaseline())
        XCTAssertFalse(off.isLagTick)
    }

    func testNoBaselineUsesDefaultThreshold() {
        XCTAssertEqual(eval.latenessThresholdMs(baseline: ProbeBaseline()), 12)
        XCTAssertEqual(eval.latenessThresholdMs(baseline: calmBaseline()), 8)
    }

    func testBaselineIgnoresValuesAboveCap() {
        var b = ProbeBaseline()
        b.observeCalm(Fx.probe(p95: 30), config: JankConfig())
        XCTAssertTrue(b.latenessP95.isEmpty)
        XCTAssertEqual(b.workP50.count, 1)
    }
}

final class DetectorTests: XCTestCase {
    func run(_ pattern: [Bool], gate: [GateState]? = nil) -> (LagDetector, [DetectorEvent]) {
        var d = LagDetector(config: JankConfig())
        var events: [DetectorEvent] = []
        for (i, lag) in pattern.enumerated() {
            let g = gate?[i] ?? .active
            events += d.process(Fx.tick(Double(i), gate: g), lag ? Fx.lagSignals() : Fx.calmSignals())
        }
        return (d, events)
    }

    func testEntersAfterThreeOfFive() {
        let (d, events) = run([true, false, true, true])
        XCTAssertEqual(d.phase, .lagging)
        guard case .started(let ep)? = events.first else { return XCTFail("no start") }
        XCTAssertEqual(ep.startT, 0)  // starts at first lag tick in window
        XCTAssertEqual(ep.lagTicks, 3)
    }

    func testIsolatedSpikesDoNotTrigger() {
        let (d, events) = run([true, false, false, true, false, false, true, false, false])
        XCTAssertTrue(events.isEmpty)
        XCTAssertNotEqual(d.phase, .lagging)
    }

    func testExitWithHysteresis() {
        let (d, events) = run([true, true, true, true, false, false, false, false])
        XCTAssertEqual(d.phase, .suspect)  // one lag tick still in the window
        let ended = events.compactMap { if case .ended(let e) = $0 { return e } else { return nil } }
        XCTAssertEqual(ended.count, 1)
        // window after tick 6: [T, F, F, F, F]? exit when ≤1 lag tick in last 5 → at tick 6 window = [t2..t6] = T,T,F,F,F → 2; tick 7 → T,F,F,F,F → 1 → end
        XCTAssertEqual(ended.first?.endT, 7)
    }

    func testGateOffEndsEpisode() {
        let (_, events) = run([true, true, true, true], gate: [.active, .active, .active, .off])
        XCTAssertEqual(events.count, 2)
        guard case .ended(let e) = events.last! else { return XCTFail("expected end") }
        XCTAssertEqual(e.endT, 3)
    }
}
