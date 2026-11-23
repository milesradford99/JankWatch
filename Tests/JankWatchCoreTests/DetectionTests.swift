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

    func testNoisyMachineLearnsHigherThresholds() {
        var b = ProbeBaseline()
        for _ in 0..<100 { b.observeCalm(Fx.probe(p95: 20), config: JankConfig()) }
        XCTAssertEqual(eval.latenessThresholdMs(baseline: b), 80)
        XCTAssertEqual(eval.latenessSevereMs(baseline: b), 120)
        XCTAssertEqual(eval.evaluate(Fx.tick(1, probe: Fx.probe(p95: 25)), baseline: b).probeScore, 0)
        XCTAssertEqual(eval.evaluate(Fx.tick(1, probe: Fx.probe(p95: 90)), baseline: b).probeScore, 0.5)
        XCTAssertEqual(eval.evaluate(Fx.tick(1, probe: Fx.probe(p95: 130)), baseline: b).probeScore, 1)
    }

    func testBaselineCandidateIgnoresProbeScore() {
        let t = Fx.tick(1, probe: Fx.probe(p95: 30), input: Fx.input(count: 0))
        let probeOnly = TickSignals(probeScore: 0.5, inputScore: 0, frontScore: 0, total: 0.5, isLagTick: false, reasons: [])
        XCTAssertTrue(SignalEvaluator.isBaselineCandidate(t, probeOnly, phase: .suspect))
        XCTAssertFalse(SignalEvaluator.isBaselineCandidate(t, probeOnly, phase: .lagging), "no input to contradict the probe")
        let typing = Fx.tick(1, probe: Fx.probe(p95: 30), input: Fx.input(max: 12, count: 4))
        XCTAssertTrue(SignalEvaluator.isBaselineCandidate(typing, probeOnly, phase: .lagging), "prompt input contradicts the probe")
        let withInput = TickSignals(probeScore: 0, inputScore: 0.5, frontScore: 0, total: 0.5, isLagTick: false, reasons: [])
        XCTAssertFalse(SignalEvaluator.isBaselineCandidate(t, withInput, phase: .normal))
        XCTAssertFalse(SignalEvaluator.isBaselineCandidate(Fx.tick(1, active: false), .zero, phase: .normal))
    }

    func testBaselineIgnoresValuesAboveCap() {
        var b = ProbeBaseline()
        b.observeCalm(Fx.probe(p95: 250), config: JankConfig())
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

    func testForceEnd() {
        var (d, _) = run([true, true, true])
        XCTAssertEqual(d.phase, .lagging)
        let ep = d.forceEnd(t: 10, wall: Date())
        XCTAssertEqual(ep?.endT, 10)
        XCTAssertEqual(d.phase, .normal)
        XCTAssertNil(d.forceEnd(t: 11, wall: Date()))
    }

    func testGateOffEndsEpisode() {
        let (_, events) = run([true, true, true, true], gate: [.active, .active, .active, .off])
        XCTAssertEqual(events.count, 2)
        guard case .ended(let e) = events.last! else { return XCTFail("expected end") }
        XCTAssertEqual(e.endT, 3)
    }
}
