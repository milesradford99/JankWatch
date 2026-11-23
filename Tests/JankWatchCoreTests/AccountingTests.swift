import XCTest
@testable import JankWatchCore

final class AccountingTests: XCTestCase {
    func raw(_ pid: Int32, cpuMs: UInt64, at: Double, start: Double = 1000, name: String = "p", path: String? = nil,
             read: UInt64? = nil, fallback: Bool = false) -> RawProcessCounters {
        RawProcessCounters(ref: Fx.ref(pid, start: start), ppid: 1, name: name, path: path, cpuNanos: cpuMs * 1_000_000,
                           measuredAt: at, diskReadBytes: read, diskWriteBytes: read.map { _ in 0 }, memoryBytes: 1 << 20, viaFallback: fallback)
    }

    func testCPUPercentFromDelta() {
        var c = ProcessDeltaComputer()
        let first = c.compute([raw(1, cpuMs: 1000, at: 10)], nowWall: 2000)
        XCTAssertNil(first[0].cpuPercent, "no rate on first sight")
        let second = c.compute([raw(1, cpuMs: 2500, at: 11, read: nil)], nowWall: 2001)
        XCTAssertEqual(second[0].cpuPercent!, 150, accuracy: 0.01)  // 1.5 s CPU in 1 s = 150 % of a core
    }

    func testPidReuseResets() {
        var c = ProcessDeltaComputer()
        _ = c.compute([raw(1, cpuMs: 5000, at: 10, start: 1000)], nowWall: 2000)
        let s = c.compute([raw(1, cpuMs: 100, at: 11, start: 1500)], nowWall: 2001)
        XCTAssertNil(s[0].cpuPercent, "recycled pid started before last sample: unknown")
    }

    func testNewbornProcessCountsWholeUsage() {
        var c = ProcessDeltaComputer()
        _ = c.compute([], nowWall: 2000)
        let s = c.compute([raw(7, cpuMs: 250, at: 11, start: 2000.5)], nowWall: 2001)
        XCTAssertEqual(s[0].cpuPercent!, 50, accuracy: 0.1)  // 0.25 s CPU over 0.5 s of life
    }

    func testFallbackReusesRateUntilRefreshed() {
        var c = ProcessDeltaComputer()
        _ = c.compute([raw(2, cpuMs: 0, at: 10, fallback: true)], nowWall: 2000)
        let a = c.compute([raw(2, cpuMs: 3000, at: 13, fallback: true)], nowWall: 2003)
        XCTAssertEqual(a[0].cpuPercent!, 100, accuracy: 0.01)
        // Same measurement (not refreshed): keep 100 %.
        let b = c.compute([raw(2, cpuMs: 3000, at: 13, fallback: true)], nowWall: 2004)
        XCTAssertEqual(b[0].cpuPercent!, 100, accuracy: 0.01)
    }

    func testDiskRate() {
        var c = ProcessDeltaComputer()
        _ = c.compute([raw(3, cpuMs: 0, at: 10, read: 0)], nowWall: 2000)
        let s = c.compute([raw(3, cpuMs: 0, at: 12, read: 100 << 20)], nowWall: 2002)
        XCTAssertEqual(s[0].diskReadBytesPerSec!, Double(50 << 20), accuracy: 1)
    }

    func testPSParser() {
        XCTAssertEqual(PSParser.parseCPUTime("0:01.50"), 1_500_000_000)
        XCTAssertEqual(PSParser.parseCPUTime("12:00.00"), 720_000_000_000)
        XCTAssertEqual(PSParser.parseCPUTime("1:00:00.00"), 3_600_000_000_000)
        XCTAssertEqual(PSParser.parseCPUTime("2-01:00:00"), (2 * 86400 + 3600) * 1_000_000_000)
        XCTAssertNil(PSParser.parseCPUTime("abc"))
        let out = """
            0  123:45.67      0
          150   10:00.01  204800
          bad line
        """
        let rows = PSParser.parse(out)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[150]?.rssBytes, 204_800 * 1024)
        XCTAssertEqual(rows[0]?.cpuNanos, 7_425_670_000_000)
    }

    func testPmsetParser() {
        let out = """
        Note: No thermal warning level has been recorded
        Note: No performance warning level has been recorded
        2026-11-23 10:00:00 +0800 CPU Power notify
        \tCPU_Scheduler_Limit \t= 100
        \tCPU_Available_CPUs \t= 8
        \tCPU_Speed_Limit \t= 72
        """
        XCTAssertEqual(PmsetParser.cpuSpeedLimit(out), 72)
        XCTAssertNil(PmsetParser.cpuSpeedLimit("Note: No thermal warning level has been recorded"))
    }

    func testGrouping() {
        let kb = KnowledgeBase.builtin
        let helper = "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/131/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)"
        XCTAssertEqual(AppGrouping.outermostAppBundle(helper), "/Applications/Google Chrome.app")
        let g = AppGrouping.groupKey(processName: "Google Chrome Helper (Renderer)", path: helper, kb: kb)
        XCTAssertEqual(g.key, "app:/Applications/Google Chrome.app")
        XCTAssertEqual(g.name, "Google Chrome")
        let s = AppGrouping.groupKey(processName: "mds_stores", path: "/System/Library/Frameworks/CoreServices.framework/Frameworks/Metadata.framework/Versions/A/Support/mds_stores", kb: kb)
        XCTAssertEqual(s.key, "kb:Spotlight 索引")
        XCTAssertEqual(AppGrouping.groupKey(processName: "yes", path: "/usr/bin/yes", kb: kb).key, "proc:yes")
        XCTAssertEqual(AppGrouping.processName(name: "Google Chrome He", path: helper), "Google Chrome Helper (Renderer)")
    }

    func testAggregatorSumsAndPicksMain() {
        let base = "/Applications/Google Chrome.app"
        let samples = [
            ProcessSample(ref: Fx.ref(10), ppid: 1, name: "Google Chrome", path: base + "/Contents/MacOS/Google Chrome",
                          cpuPercent: 20, memoryBytes: 500 << 20, diskReadBytesPerSec: 0, diskWriteBytesPerSec: 0, viaFallback: false),
            ProcessSample(ref: Fx.ref(11), ppid: 10, name: "Google Chrome Helper", path: base + "/Contents/Frameworks/X.framework/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper",
                          cpuPercent: 80, memoryBytes: 300 << 20, diskReadBytesPerSec: 1000, diskWriteBytesPerSec: 0, viaFallback: false),
            ProcessSample(ref: Fx.ref(20, uid: 0), ppid: 1, name: "mds_stores", path: "/System/x/mds_stores", cpuPercent: nil, memoryBytes: nil,
                          diskReadBytesPerSec: nil, diskWriteBytesPerSec: nil, viaFallback: true),
        ]
        let groups = ProcessAggregator.aggregate(samples, kb: .builtin, currentUID: Fx.me)
        let chrome = try! XCTUnwrap(groups.first { $0.name == "Google Chrome" })
        XCTAssertEqual(chrome.cpuPercent, 100)
        XCTAssertEqual(chrome.memoryBytes, 800 << 20)
        XCTAssertEqual(chrome.mainPID, 10)
        XCTAssertEqual(chrome.pids.count, 2)
        XCTAssertTrue(chrome.ownedByCurrentUser)
        let spot = try! XCTUnwrap(groups.first { $0.key == "kb:Spotlight 索引" })
        XCTAssertFalse(spot.ownedByCurrentUser)
        XCTAssertTrue(spot.partial)
    }

    func testCPULoadWraparound() {
        let prev = [CPULoad.CoreTicks(user: UInt32.max - 10, system: 0, idle: 0, nice: 0)]
        let cur = [CPULoad.CoreTicks(user: 10, system: 0, idle: 21, nice: 0)]
        XCTAssertEqual(CPULoad.busy(prev: prev, cur: cur)[0], 0.5, accuracy: 0.01)
    }

    func testTopology() {
        let m1 = CPUTopology(logical: 8, perfCount: 4, effCount: 4)
        XCTAssertEqual(m1.perfIndices(), 4..<8)
        XCTAssertEqual(m1.pCoreBusy([0, 0, 0, 0, 1, 1, 0.5, 0.5])!, 0.75, accuracy: 1e-9)
        XCTAssertNil(CPUTopology(logical: 8, perfCount: nil, effCount: nil).pCoreBusy([0, 1]))
    }
}

final class CalibrationTests: XCTestCase {
    func testClockNanos() {
        var c = TimestampClockCalibrator()
        for _ in 0..<9 { XCTAssertNil(c.observe(latencyIfNanosMs: 3, latencyIfTicksMs: -5e9)) }
        XCTAssertEqual(c.observe(latencyIfNanosMs: 3, latencyIfTicksMs: -5e9), .nanoseconds)
    }

    func testClockTicks() {
        var c = TimestampClockCalibrator()
        for _ in 0..<10 { c.observe(latencyIfNanosMs: -9e12, latencyIfTicksMs: 4) }
        XCTAssertEqual(c.decided, .machTicks)
    }

    func testClockFailure() {
        var c = TimestampClockCalibrator(giveUpAfter: 20)
        for _ in 0..<20 { c.observe(latencyIfNanosMs: 1e9, latencyIfTicksMs: 1e9) }
        XCTAssertNil(c.decided)
        XCTAssertTrue(c.failed)
    }

    func testClockForced() {
        XCTAssertEqual(TimestampClockCalibrator(forced: .machTicks).decided, .machTicks)
    }

    func testRusageUnit() {
        let tb = TimeBase.appleSilicon
        // 100 ms of CPU reported in ticks (2.4M ticks)
        XCTAssertEqual(RusageUnitCalibrator.decide(rawDelta: 2_400_000, trueNanosDelta: 100_000_000, timebase: tb), .machTicks)
        XCTAssertEqual(RusageUnitCalibrator.decide(rawDelta: 101_000_000, trueNanosDelta: 100_000_000, timebase: tb), .nanoseconds)
        XCTAssertEqual(RusageUnitCalibrator.decide(rawDelta: 100_000_000, trueNanosDelta: 100_000_000, timebase: .identity), .nanoseconds)
        XCTAssertNil(RusageUnitCalibrator.decide(rawDelta: 1, trueNanosDelta: 1_000, timebase: tb))
        XCTAssertEqual(RusageUnitCalibrator.toNanos(24, unit: .machTicks, timebase: tb), 1000)
    }
}
