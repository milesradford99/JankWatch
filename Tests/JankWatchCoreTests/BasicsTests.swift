import XCTest
@testable import JankWatchCore

final class BasicsTests: XCTestCase {
    func testTimeBaseAppleSilicon() {
        let tb = TimeBase.appleSilicon
        XCTAssertEqual(tb.ticksToNanos(24_000_000), 1_000_000_000)  // 24 MHz timebase → 1 s
        XCTAssertEqual(tb.nanosToTicks(1_000_000_000), 24_000_000)
        XCTAssertEqual(tb.ticksToMillis(24_000), 1.0, accuracy: 1e-9)
        XCTAssertEqual(tb.ticksToSeconds(48_000_000), 2.0, accuracy: 1e-9)
    }

    func testTimeBaseIdentity() {
        XCTAssertEqual(TimeBase.identity.ticksToNanos(12345), 12345)
        XCTAssertEqual(TimeBase.identity.ticksToMillis(2_000_000), 2.0, accuracy: 1e-12)
    }

    func testPercentile() {
        XCTAssertNil(Stats.percentile([], 0.5))
        XCTAssertEqual(Stats.percentile([5], 0.95), 5)
        XCTAssertEqual(Stats.percentile([1, 2, 3, 4, 5], 0.5), 3)
        XCTAssertEqual(Stats.percentile([1, 2, 3, 4], 0.5)!, 2.5, accuracy: 1e-9)
        XCTAssertEqual(Stats.percentile([10, 0], 1.0), 10)
        XCTAssertEqual(Stats.finite(.nan, 7), 7)
    }

    func testRingBuffer() {
        var rb = RingBuffer<Int>(capacity: 3)
        XCTAssertTrue(rb.isEmpty)
        for i in 1...5 { rb.append(i) }
        XCTAssertEqual(rb.elements, [3, 4, 5])
        XCTAssertEqual(rb.last(2), [4, 5])
        XCTAssertEqual(rb.newest, 5)
        rb.removeAll()
        XCTAssertEqual(rb.count, 0)
        rb.append(9)
        XCTAssertEqual(rb.elements, [9])
    }

    func testSpinWorkDeterministic() {
        XCTAssertEqual(probeSpinWork(1000), probeSpinWork(1000))
        XCTAssertNotEqual(probeSpinWork(1000), probeSpinWork(1001))
    }

    func testFormat() {
        XCTAssertEqual(Format.bytes(3 * 1024 * 1024 * 1024), "3.0GB")
        XCTAssertEqual(Format.bytes(50 * 1024 * 1024), "50MB")
        XCTAssertEqual(Format.ms(180), "180ms")
        XCTAssertEqual(Format.ms(12.34), "12.3ms")
    }

    func testConfigPartialDecodeKeepsDefaults() throws {
        let json = #"{"inputModerateMs": 120, "sensitivity": "high", "ignoredGroups": ["app:/Applications/Xcode.app"]}"#
        let c = try JankConfig.load(from: Data(json.utf8))
        XCTAssertEqual(c.inputModerateMs, 120)
        XCTAssertEqual(c.sensitivity, .high)
        XCTAssertEqual(c.ignoredGroups, ["app:/Applications/Xcode.app"])
        XCTAssertEqual(c.inputSevereMs, JankConfig().inputSevereMs)
        XCTAssertEqual(c.enterCount, 3)
        // Round trip
        let again = try JankConfig.load(from: c.encoded())
        XCTAssertEqual(again, c)
    }

    func testSensitivityScaling() {
        var c = JankConfig()
        c.sensitivity = .high
        XCTAssertEqual(c.scaled.inputModerateMs, 60, accuracy: 1e-9)
        XCTAssertEqual(c.scaled.probeWorkInflationModerate, 1.6, accuracy: 1e-9)
        c.sensitivity = .medium
        XCTAssertEqual(c.scaled.inputModerateMs, 80)
    }
}
