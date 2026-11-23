import XCTest
@testable import JankWatchCore

final class AttributionTests: XCTestCase {
    let attributor = Attributor(config: JankConfig())
    let ctx = AttributionContext(frontmostPID: 500, frontmostBundlePath: "/Applications/TextEdit.app", ownGroupKey: "app:/Applications/JankWatch.app")

    var front: GroupSample { Fx.group("TextEdit", bundle: "/Applications/TextEdit.app", cpu: 5, mem: 200 << 20, pids: [500]) }
    var me: GroupSample { Fx.group("JankWatch", bundle: "/Applications/JankWatch.app", cpu: 90, pids: [600]) }

    func ticks(_ n: Int = 10, system: SystemSample = Fx.system(), signals: TickSignals = Fx.lagSignals(),
               front frontStats: FrontAppStats? = nil, groups: (Int) -> [GroupSample]) -> [Tick] {
        (0..<n).map { i in Fx.tick(Double(i), front: frontStats, system: system, groups: groups(i), signals: signals) }
    }

    func testCPUContention() {
        let chrome = Fx.group("Google Chrome", bundle: "/Applications/Google Chrome.app", cpu: 250, mem: 2 << 30, pids: [700, 701, 702])
        let d = attributor.diagnose(ticks(system: Fx.system(busy: 0.95)) { _ in [self.front, chrome, self.me] }, context: ctx)
        XCTAssertEqual(d.cause, .cpuContention)
        XCTAssertEqual(d.primaryCulprit?.displayName, "Google Chrome")
        XCTAssertEqual(d.primaryCulprit?.recommended, .background)
        XCTAssertEqual(d.primaryCulprit?.hotkeyAction, .background)
        XCTAssertEqual(d.primaryCulprit?.pids.count, 3)
        XCTAssertFalse(d.culprits.contains { $0.displayName == "JankWatch" }, "own app must never be blamed")
        XCTAssertFalse(d.culprits.contains { $0.isFrontmost })
        XCTAssertTrue(d.headline.contains("Google Chrome"))
    }

    func testMemoryPressurePrefersBackgroundAndRecommendsQuit() {
        let slack = Fx.group("Slack", bundle: "/Applications/Slack.app", cpu: 3, mem: 3 << 30, pids: [800])
        let bigFront = Fx.group("TextEdit", bundle: "/Applications/TextEdit.app", cpu: 1, mem: 5 << 30, pids: [500])
        let sys = Fx.system(busy: 0.3, pressure: .warning, swapIn: Double(20 << 20))
        let d = attributor.diagnose(ticks(system: sys) { _ in [bigFront, slack] }, context: ctx)
        XCTAssertEqual(d.cause, .memoryPressure)
        XCTAssertEqual(d.primaryCulprit?.displayName, "Slack")
        XCTAssertEqual(d.primaryCulprit?.recommended, .quit)
        XCTAssertEqual(d.primaryCulprit?.hotkeyAction, .pause, "hotkey only does reversible actions")
        XCTAssertTrue(d.evidence.contains { $0.contains("swap") })
    }

    func testMemoryGrowthTracked() {
        let d = attributor.diagnose(ticks(system: Fx.system(pressure: .critical, swapIn: Double(50 << 20))) { i in
            [Fx.group("Leaky", bundle: "/Applications/Leaky.app", mem: UInt64(1 << 30) + UInt64(i) * (100 << 20), pids: [900])]
        }, context: ctx)
        XCTAssertEqual(d.primaryCulprit?.memoryGrowthBytes, 900 << 20)
        XCTAssertTrue(d.primaryCulprit!.metricsSummary.contains("↑"))
    }

    func testFrontAppHung() {
        let hung = FrontAppStats(pid: 500, bundleID: "com.apple.TextEdit", name: "TextEdit", bundlePath: "/Applications/TextEdit.app",
                                 maxRoundTripMs: 250, timedOut: true)
        let sig = TickSignals(probeScore: 0, inputScore: 0, frontScore: 1, total: 1, isLagTick: true, reasons: ["front.hung"])
        let d = attributor.diagnose(ticks(signals: sig, front: hung) { _ in [self.front] }, context: ctx)
        XCTAssertEqual(d.cause, .frontAppHung)
        XCTAssertEqual(d.primaryCulprit?.displayName, "TextEdit")
        XCTAssertNil(d.primaryCulprit?.recommended)
        XCTAssertEqual(d.primaryCulprit?.allowedActions, [.quit, .forceQuit])
        XCTAssertNil(d.primaryCulprit?.hotkeyAction)
    }

    func testThermalOnIntel() {
        let worker = Fx.group("ffmpeg", path: "/opt/homebrew/bin/ffmpeg", cpu: 400, pids: [1000])
        let kt = Fx.group("kernel_task", key: "proc:kernel_task", path: nil, cpu: 300, pids: [0], owned: false)
        let d = attributor.diagnose(ticks(system: Fx.system(busy: 0.7, speedLimit: 60)) { _ in [kt, worker] }, context: ctx)
        XCTAssertEqual(d.cause, .thermalThrottling)
        XCTAssertEqual(d.primaryCulprit?.displayName, "ffmpeg")
        XCTAssertTrue(d.headline.contains("60%"))
        XCTAssertFalse(d.culprits.contains { $0.displayName == "kernel_task" })
    }

    func testDiskIOSpotlightUsesKnowledgeBase() {
        let spot = Fx.group("Spotlight 索引", key: "kb:Spotlight 索引", path: "/System/Library/Frameworks/CoreServices.framework/mds_stores",
                            cpu: 20, disk: Double(120 << 20), pids: [300, 301], owned: false, mainName: "mds_stores")
        let d = attributor.diagnose(ticks { _ in [spot] }, context: ctx)
        XCTAssertEqual(d.cause, .diskIO)
        let c = try! XCTUnwrap(d.primaryCulprit)
        XCTAssertEqual(c.category, .systemDeferrable)
        XCTAssertTrue(c.needsAdmin)
        XCTAssertNotNil(c.adminFix)
        XCTAssertEqual(c.allowedActions, [.background, .pause])
        XCTAssertEqual(c.recommended, .background)
    }

    func testWindowServerNeverActionable() {
        let ws = Fx.group("WindowServer", path: "/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer", cpu: 95,
                          pids: [150], owned: false)
        let d = attributor.diagnose(ticks(system: Fx.system(busy: 0.4)) { _ in [ws] }, context: ctx)
        XCTAssertEqual(d.cause, .windowServer)
        XCTAssertFalse(d.culprits.contains { $0.displayName == "WindowServer" })
        XCTAssertTrue(d.headline.contains("WindowServer"))
    }

    func testIgnoredGroupsExcluded() {
        var cfg = JankConfig()
        cfg.ignoredGroups = ["app:/Applications/Xcode.app"]
        let a = Attributor(config: cfg)
        let xcode = Fx.group("Xcode", bundle: "/Applications/Xcode.app", cpu: 400, pids: [1100])
        let d = a.diagnose(ticks(system: Fx.system(busy: 0.95)) { _ in [xcode] }, context: ctx)
        XCTAssertTrue(d.culprits.isEmpty)
        XCTAssertEqual(d.cause, .cpuContention)
    }

    func testUnknown() {
        let d = attributor.diagnose(ticks { _ in [self.front] }, context: ctx)
        XCTAssertEqual(d.cause, .unknown)
        XCTAssertTrue(d.culprits.isEmpty)
    }

    func testCriticalCategoryHasNoActions() {
        XCTAssertEqual(ActionPolicy.allowed(category: .critical, isApp: false, cause: .cpuContention), [])
        XCTAssertEqual(ActionPolicy.allowed(category: .security, isApp: false, cause: .cpuContention), [])
        XCTAssertEqual(ActionPolicy.allowed(category: .systemService, isApp: false, cause: .cpuContention), [.background])
    }

    func testAlertPolicyCooldown() {
        var p = AlertPolicy(config: JankConfig())
        let chrome = Fx.group("Google Chrome", bundle: "/Applications/Google Chrome.app", cpu: 250, pids: [700])
        let d = attributor.diagnose(ticks(system: Fx.system(busy: 0.95)) { _ in [chrome] }, context: ctx)
        XCTAssertTrue(p.shouldAlert(d, now: 0))
        XCTAssertFalse(p.shouldAlert(d, now: 60))
        XCTAssertTrue(p.shouldAlert(d, now: 121))
    }
}

final class KnowledgeBaseTests: XCTestCase {
    let kb = KnowledgeBase.builtin

    func testLookup() {
        XCTAssertEqual(kb.lookup("mds_stores")?.group, "Spotlight 索引")
        XCTAssertEqual(kb.lookup("kernel_task")?.category, .critical)
        XCTAssertEqual(kb.lookup("XProtectRemediatorFoo")?.group, "XProtect")  // prefix
        XCTAssertNil(kb.lookup("SomeRandomApp"))
    }

    func testCategoryHeuristics() {
        XCTAssertEqual(kb.category(processName: "foo", path: "/System/Library/CoreServices/foo"), .systemService)
        XCTAssertEqual(kb.category(processName: "foo", path: "/usr/libexec/foo"), .systemService)
        XCTAssertEqual(kb.category(processName: "foo", path: "/Applications/Foo.app/Contents/MacOS/foo"), .userApp)
        XCTAssertEqual(kb.category(processName: "x", path: nil, groupName: "Spotlight 索引"), .systemDeferrable)
    }

    func testNoDuplicateNames() {
        var seen = Set<String>()
        for e in kb.entries where !e.prefix {
            for n in e.names {
                XCTAssertFalse(seen.contains(n), "duplicate KB name \(n)")
                seen.insert(n)
            }
        }
    }
}
