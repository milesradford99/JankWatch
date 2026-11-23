import XCTest
@testable import JankWatchCore

final class StoreTests: XCTestCase {
    var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("jw-test-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    let meta = RunMeta(appVersion: "0.1.0", arch: "arm64", osVersion: "15.1", timebase: .appleSilicon, inputClock: .nanoseconds, rusageUnit: .machTicks)

    func testConfigCreatedWithDefaults() {
        let s = EventStore(root: dir)
        XCTAssertEqual(s.loadConfig(), JankConfig())
        XCTAssertTrue(FileManager.default.fileExists(atPath: s.configURL.path))
        var c = JankConfig()
        c.sensitivity = .low
        s.saveConfig(c)
        XCTAssertEqual(EventStore(root: dir).loadConfig().sensitivity, .low)
    }

    func testLedgerAndBaselineRoundTrip() {
        let s = EventStore(root: dir)
        var l = ActionLedger()
        let r = ActionRecord(kind: .pause, groupKey: "app:/A.app", displayName: "A", pids: [Fx.ref(1)], appliedAt: Date(timeIntervalSince1970: 100),
                             autoRevertAt: Date(timeIntervalSince1970: 700))
        l.add(r)
        s.saveLedger(l)
        let loaded = s.loadLedger()
        XCTAssertEqual(loaded.records.count, 1)
        XCTAssertEqual(loaded.activePauses.count, 1)
        XCTAssertEqual(loaded.due(now: Date(timeIntervalSince1970: 701)).count, 1)
        XCTAssertEqual(loaded.due(now: Date(timeIntervalSince1970: 600)).count, 0)
        XCTAssertEqual(loaded.activePauses(containing: 1).count, 1)

        var b = ProbeBaseline()
        b.observeCalm(Fx.probe(p95: 2), config: JankConfig())
        s.saveBaseline(b)
        XCTAssertEqual(s.loadBaseline(), b)
    }

    func testLedgerRevertAndPrune() {
        var l = ActionLedger()
        let r = ActionRecord(kind: .background, groupKey: "k", displayName: "K", pids: [], appliedAt: Date(timeIntervalSince1970: 0))
        l.add(r)
        XCTAssertTrue(l.records[0].canRevert)
        l.markReverted(r.id, at: Date(timeIntervalSince1970: 10))
        XCTAssertFalse(l.records[0].canRevert)
        l.prune(now: Date(timeIntervalSince1970: 86400 * 10))
        XCTAssertTrue(l.records.isEmpty)
        let q = ActionRecord(kind: .quit, groupKey: "k", displayName: "K", pids: [], appliedAt: Date())
        XCTAssertFalse(q.canRevert)
    }

    func testTicksMarksAndEvaluation() {
        let s = EventStore(root: dir)
        for i in 0..<7200 where i % 2 == 0 { s.appendTick(Fx.tick(Double(i)).compact()) }  // 3600 active ticks
        s.appendTick(Fx.tick(9999, gate: .idle))

        var ep = Episode(id: "E1", startT: 100, startWall: Date(timeIntervalSince1970: 1_800_000_100))
        ep.endT = 110
        ep.endWall = Date(timeIntervalSince1970: 1_800_000_110)
        let d = Diagnosis(cause: .cpuContention, secondaryCauses: [], headline: "h", evidence: [], culprits: [])
        let rec = EpisodeRecord(episode: ep, diagnosis: d, alerted: true, alertedAt: Date(timeIntervalSince1970: 1_800_000_103),
                                actionIDs: [], meta: meta, ticks: [Fx.tick(100)])
        XCTAssertNotNil(s.writeEpisode(rec))

        var ep2 = Episode(id: "E2", startT: 500, startWall: Date(timeIntervalSince1970: 1_800_000_500))
        ep2.endWall = Date(timeIntervalSince1970: 1_800_000_505)
        s.writeEpisode(EpisodeRecord(episode: ep2, diagnosis: nil, alerted: true, alertedAt: Date(timeIntervalSince1970: 1_800_000_503),
                                     actionIDs: [], meta: meta, ticks: []))

        s.appendMark(MarkRecord(wall: Date(timeIntervalSince1970: 1_800_000_115), t: 115, phase: .normal))  // matches E1
        s.appendMark(MarkRecord(wall: Date(timeIntervalSince1970: 1_800_003_000), t: 3000, phase: .normal))  // missed
        s.appendFeedback(FeedbackRecord(wall: Date(), episodeID: "E2", kind: .notLag, detail: nil))

        let report = Evaluator.evaluate(s.loadEpisodes(), marks: s.loadMarks(), feedback: s.loadFeedback(), activeTicks: s.countActiveTicks())
        XCTAssertEqual(report.episodes, 2)
        XCTAssertEqual(report.marks, 2)
        XCTAssertEqual(report.matchedMarks, 1)
        XCTAssertEqual(report.recall!, 0.5, accuracy: 1e-9)
        XCTAssertEqual(report.episodesConfirmedByMark, 1)
        XCTAssertEqual(report.episodesMarkedNotLag, 1)
        XCTAssertEqual(report.activeHours, 1.0, accuracy: 1e-9)
        XCTAssertEqual(report.alertsPerActiveHour!, 2, accuracy: 1e-9)
        XCTAssertEqual(report.medianAlertDelaySec!, 3, accuracy: 1e-9)
        XCTAssertEqual(report.episodesByCause["cpuContention"], 1)
        XCTAssertEqual(report.unmatchedMarkTimes.count, 1)
    }

    func testPruneTicks() throws {
        let s = EventStore(root: dir)
        let old = s.ticksDir.appendingPathComponent("2020-01-01.jsonl")
        try Data().write(to: old)
        s.appendTick(Fx.tick(1))
        s.pruneTicks(retentionDays: 7, now: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: s.ticksDir.path).count, 1)
    }
}
