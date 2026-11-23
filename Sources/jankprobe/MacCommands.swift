#if os(macOS)
import AppKit
import Darwin
import Foundation
import JankWatchCore
import JankWatchMac

func runMacCommand(_ args: Args) {
    switch args.command {
    case "env": cmdEnv()
    case "clock": cmdClock(seconds: args.double("--seconds", 20))
    case "rusage": cmdRusage()
    case "ax": cmdAX(args)
    case "probe": cmdProbe(args)
    case "topology": cmdTopology()
    case "act": cmdAct(args)
    case "engine": cmdEngine(args)
    default:
        print(usageText)
        exit(64)
    }
}

/// Run the main run loop for `seconds` (needed for event taps on other threads to stay alive, notifications, etc.).
func spin(_ seconds: Double, every: Double = 1, _ body: (() -> Void)? = nil) {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        RunLoop.main.run(until: min(end, Date().addingTimeInterval(every)))
        body?()
    }
}

// MARK: env

struct EnvResult: Codable {
    var arch: String
    var osVersion: String
    var model: String
    var cpu: String
    var timebase: TimeBase
    var topology: CPUTopology
    var pageSize: Int
    var uid: UInt32
    var inputMonitoring: Bool
    var accessibility: Bool
    var thermal: Int
    var memoryPressure: Int
}

func cmdEnv() {
    let r = EnvResult(arch: MachineInfo.arch, osVersion: MachineInfo.osVersion, model: MachineInfo.modelIdentifier, cpu: MachineInfo.cpuBrand,
                      timebase: MachClock.timebase, topology: MachineInfo.topology, pageSize: Int(getpagesize()), uid: getuid(),
                      inputMonitoring: InputLatencySensor.hasPermission(), accessibility: FrontAppProbe.hasPermission(),
                      thermal: SystemSampler.thermal().rawValue, memoryPressure: SystemSampler.memoryPressure().rawValue)
    printJSON("RESULT env", r)
    print("Note: when run from Terminal, permissions are those granted to the terminal app, not to JankWatch.app.")
}

// MARK: V1 clock

struct ClockResult: Codable {
    var events: Int
    var decided: String?
    var medianIfNanosMs: Double?
    var medianIfTicksMs: Double?
    var p95IfNanosMs: Double?
    var p95IfTicksMs: Double?
}

func cmdClock(seconds: Double) {
    print("V1: type, click and scroll in any app for \(Int(seconds)) s ...")
    if !InputLatencySensor.hasPermission() {
        InputLatencySensor.requestPermission()
        print("!! Input Monitoring not granted for this terminal. Grant it in System Settings > Privacy & Security > Input Monitoring, restart the terminal, re-run.")
    }
    let s = InputLatencySensor(clock: .auto)
    s.debugCapture = true
    guard s.install() else {
        print("!! CGEvent.tapCreate failed (no permission?)")
        printJSON("RESULT clock", ClockResult(events: 0, decided: nil))
        exit(1)
    }
    s.setEnabled(true)
    var pairs: [(nanos: Double, ticks: Double)] = []
    spin(seconds) {
        let p = s.drainDebugPairs()
        for x in p { print(String(format: "  event: if-nanos %.3f ms | if-ticks %.3f ms", x.nanos, x.ticks)) }
        pairs += p
        _ = s.drain()
    }
    let n = pairs.map { $0.nanos }, t = pairs.map { $0.ticks }
    printJSON("RESULT clock", ClockResult(events: pairs.count, decided: s.clockDecision?.rawValue,
                                          medianIfNanosMs: Stats.median(n), medianIfTicksMs: Stats.median(t),
                                          p95IfNanosMs: Stats.percentile(n, 0.95), p95IfTicksMs: Stats.percentile(t, 0.95)))
}

// MARK: V2 rusage

struct RusageResult: Codable {
    var runningAsRoot: Bool
    var total: Int
    var ok: Int
    var deniedEPERM: Int
    var otherErrors: Int
    var ownUserOK: Int
    var ownUserTotal: Int
    var rootOK: Int
    var rootTotal: Int
    var otherUsersOK: Int
    var otherUsersTotal: Int
    var pathReadableForDenied: Int
    var deniedSamples: [String]
    var unit: String?
    var psRows: Int
    var psCoversDenied: Int
    var kernelTaskViaPS: Bool
    var windowServerViaRusage: Bool
}

func cmdRusage() {
    let me = getuid()
    let table = ProcessTable.all().filter { !$0.isZombie }
    var r = RusageResult(runningAsRoot: me == 0, total: table.count, ok: 0, deniedEPERM: 0, otherErrors: 0, ownUserOK: 0, ownUserTotal: 0,
                         rootOK: 0, rootTotal: 0, otherUsersOK: 0, otherUsersTotal: 0, pathReadableForDenied: 0, deniedSamples: [],
                         unit: nil, psRows: 0, psCoversDenied: 0, kernelTaskViaPS: false, windowServerViaRusage: false)
    var denied: [Int32] = []
    for e in table {
        let (reading, err) = Rusage.read(pid: e.pid)
        let ok = reading != nil
        if ok { r.ok += 1 } else if err == EPERM { r.deniedEPERM += 1 } else { r.otherErrors += 1 }
        if e.uid == me { r.ownUserTotal += 1; if ok { r.ownUserOK += 1 } }
        else if e.uid == 0 { r.rootTotal += 1; if ok { r.rootOK += 1 } }
        else { r.otherUsersTotal += 1; if ok { r.otherUsersOK += 1 } }
        if !ok {
            denied.append(e.pid)
            if ProcessTable.path(pid: e.pid) != nil { r.pathReadableForDenied += 1 }
            if r.deniedSamples.count < 15 { r.deniedSamples.append("\(e.pid) \(ProcessTable.name(pid: e.pid) ?? e.comm) uid=\(e.uid) errno=\(err)") }
        }
        if e.comm == "WindowServer" { r.windowServerViaRusage = ok }
    }
    r.unit = Rusage.calibrateUnit()?.rawValue
    let ps = Shell.run("/bin/ps", ["-A", "-o", "pid=,time=,rss="])
    let rows = PSParser.parse(ps.output)
    r.psRows = rows.count
    r.psCoversDenied = denied.filter { rows[$0] != nil }.count
    r.kernelTaskViaPS = rows[0] != nil
    printJSON("RESULT rusage", r)
}

// MARK: V3 accessibility probe

struct AXResult: Codable {
    var bundleID: String
    var pid: Int32
    var calls: Int
    var p50Ms: Double?
    var p95Ms: Double?
    var maxMs: Double?
    var timeouts: Int
    var appCPUPercentWithoutProbe: Double?
    var appCPUPercentWithProbe: Double?
    var appMemoryBytesBefore: UInt64
    var appMemoryBytesAfter: UInt64
}

func appPIDs(bundlePath: String) -> [Int32] {
    ProcessTable.all().filter { e in
        guard let p = ProcessTable.path(pid: e.pid) else { return false }
        return AppGrouping.outermostAppBundle(p) == bundlePath
    }.map(\.pid)
}

func groupUsage(_ pids: [Int32], unit: RusageTimeUnit) -> (cpuNanos: UInt64, mem: UInt64) {
    var cpu: UInt64 = 0, mem: UInt64 = 0
    for p in pids {
        if let r = Rusage.read(pid: p).0 {
            cpu += RusageUnitCalibrator.toNanos(r.cpuRaw, unit: unit, timebase: MachClock.timebase)
            mem += r.footprint
        }
    }
    return (cpu, mem)
}

func cmdAX(_ args: Args) {
    guard let bundle = args.value("--bundle"),
          let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first,
          let bundlePath = app.bundleURL?.path else {
        print("usage: jankprobe ax --bundle com.google.Chrome   (the app must be running)")
        exit(64)
    }
    if !FrontAppProbe.hasPermission(prompt: true) {
        print("!! Accessibility not granted for this terminal. Grant it, restart the terminal, re-run.")
        exit(1)
    }
    let seconds = args.double("--seconds", 30)
    let unit = Rusage.calibrateUnit() ?? .nanoseconds
    let pid = app.processIdentifier
    let pids = appPIDs(bundlePath: bundlePath)
    print("V3: \(bundle) pid \(pid), \(pids.count) processes. Leave the app idle in the background.")

    print("Phase A: \(Int(seconds)) s without probing ...")
    let a0 = groupUsage(pids, unit: unit)
    spin(seconds)
    let a1 = groupUsage(pids, unit: unit)

    print("Phase B: \(Int(seconds)) s probing once per second ...")
    var rts: [Double] = []
    var timeouts = 0
    let b0 = groupUsage(pids, unit: unit)
    spin(seconds) {
        if let s = FrontAppProbe.measure(pid: pid, timeoutMs: 250) {
            rts.append(s.roundTripMs)
            if s.timedOut { timeouts += 1 }
            print(String(format: "  AX round trip %.2f ms%@", s.roundTripMs, s.timedOut ? " (TIMEOUT)" : ""))
        } else {
            print("  AX call gave no answer (no permission or no AX support)")
        }
    }
    let b1 = groupUsage(appPIDs(bundlePath: bundlePath), unit: unit)
    let r = AXResult(bundleID: bundle, pid: pid, calls: rts.count, p50Ms: Stats.median(rts), p95Ms: Stats.percentile(rts, 0.95), maxMs: rts.max(),
                     timeouts: timeouts,
                     appCPUPercentWithoutProbe: Double(a1.cpuNanos &- a0.cpuNanos) / 1e9 / seconds * 100,
                     appCPUPercentWithProbe: Double(b1.cpuNanos &- b0.cpuNanos) / 1e9 / seconds * 100,
                     appMemoryBytesBefore: a0.mem, appMemoryBytesAfter: b1.mem)
    printJSON("RESULT ax", r)
}

// MARK: V4 probe

func cmdProbe(_ args: Args) {
    let seconds = args.double("--seconds", 120)
    let cfg = JankConfig()
    let probe = ProbeSensor(intervalMs: cfg.probeIntervalMs, workEvery: cfg.probeWorkEvery, workIterations: cfg.probeWorkIterations)
    let sys = SystemSampler(thermPollInterval: cfg.intelThermPollSec)
    let input = InputLatencySensor(clock: .auto)
    if args.has("--input") {
        if input.install() { input.setEnabled(true) } else { print("!! input tap unavailable (Input Monitoring for this terminal?)") }
    }
    let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical], reason: "jankprobe")
    defer { ProcessInfo.processInfo.endActivity(activity) }
    var csv = "sec,samples,lat_p50_ms,lat_p95_ms,lat_max_ms,work_p50_ms,work_ratio,input_max_ms,input_n,cpu_busy,pcore_busy,pressure,swapin_mb_s,thermal,speed_limit\n"
    probe.start()
    _ = sys.sample()
    spin(1.2)
    _ = probe.drain()
    var workBase: [Double] = []
    var sec = 0
    print("sec samples  lat_p50  lat_p95  lat_max  work_p50 ratio  in_max  cpu  pcpu  press swapin   therm limit")
    spin(seconds) {
        sec += 1
        let (lat, work) = probe.drain()
        let st = ProbeWindowStats.from(latenessMs: lat, workMs: work, expected: probe.expectedPerSecond)
        if sec <= 10, let w = st.workP50Ms { workBase.append(w) }
        let ratio = (st.workP50Ms ?? 0) / (Stats.median(workBase) ?? 1)
        let inp = input.drain()
        let inMax = inp.map(\.latencyMs).max() ?? 0
        let s = sys.sample()
        let line = String(format: "%3d %7d %8.2f %8.2f %8.2f %9.3f %5.2f %7.1f %4.0f%% %4.0f%% %5d %6.1f %7d %@",
                          sec, st.samples, st.latenessP50Ms, st.latenessP95Ms, st.latenessMaxMs, st.workP50Ms ?? 0, ratio, inMax,
                          (s?.cpuBusy ?? 0) * 100, (s?.pCoreBusy ?? 0) * 100, s?.memoryPressure.rawValue ?? 0,
                          (s?.swapInBytesPerSec ?? 0) / 1_048_576, s?.thermal.rawValue ?? 0, s?.cpuSpeedLimit.map { "\($0)" } ?? "-")
        print(line)
        csv += [String(sec), String(st.samples), String(st.latenessP50Ms), String(st.latenessP95Ms), String(st.latenessMaxMs),
                String(st.workP50Ms ?? 0), String(ratio), String(inMax), String(inp.count), String(s?.cpuBusy ?? 0), String(s?.pCoreBusy ?? -1),
                String(s?.memoryPressure.rawValue ?? 0), String((s?.swapInBytesPerSec ?? 0) / 1_048_576), String(s?.thermal.rawValue ?? 0),
                s?.cpuSpeedLimit.map { "\($0)" } ?? ""].joined(separator: ",") + "\n"
    }
    probe.stop()
    if let path = args.value("--csv") {
        try? csv.write(toFile: (path as NSString).expandingTildeInPath, atomically: true, encoding: .utf8)
        print("wrote \(path)")
    }
}

// MARK: V5 topology

struct TopologyResult: Codable {
    var topology: CPUTopology
    var backgroundBusyPerCore: [Double]
    var interactiveBusyPerCore: [Double]
    var backgroundBusiestIndices: [Int]
    var assumedEfficiencyIndices: [Int]
    var effCoresFirstLooksRight: Bool?
}

func burn(threads: Int, qos: QualityOfService, seconds: Double) -> [Double] {
    guard let before = SystemSampler.coreTicks() else { return [] }
    let group = DispatchGroup()
    for _ in 0..<threads {
        group.enter()
        let t = Thread {
            let end = Date().addingTimeInterval(seconds)
            var x: UInt64 = 0
            while Date() < end { x &+= probeSpinWork(50_000) }
            if x == 1 { print("") }
            group.leave()
        }
        t.qualityOfService = qos
        t.start()
    }
    group.wait()
    guard let after = SystemSampler.coreTicks() else { return [] }
    return CPULoad.busy(prev: before, cur: after)
}

func cmdTopology() {
    let topo = MachineInfo.topology
    print("topology: \(topo)")
    guard topo.isHeterogeneous, let e = topo.effCount else {
        printJSON("RESULT topology", TopologyResult(topology: topo, backgroundBusyPerCore: [], interactiveBusyPerCore: [],
                                                    backgroundBusiestIndices: [], assumedEfficiencyIndices: [], effCoresFirstLooksRight: nil))
        print("Not a heterogeneous CPU (Intel): nothing to check.")
        return
    }
    print("Burning \(e) background-QoS threads for 4 s (macOS should keep them on efficiency cores) ...")
    let bg = burn(threads: e, qos: .background, seconds: 4)
    spin(1)
    print("Burning \(topo.logical) user-interactive threads for 3 s ...")
    let ui = burn(threads: topo.logical, qos: .userInteractive, seconds: 3)
    let busiest = bg.enumerated().sorted { $0.element > $1.element }.prefix(e).map(\.offset).sorted()
    let assumed = Array(0..<e)
    printJSON("RESULT topology", TopologyResult(topology: topo, backgroundBusyPerCore: bg, interactiveBusyPerCore: ui,
                                                backgroundBusiestIndices: busiest, assumedEfficiencyIndices: assumed,
                                                effCoresFirstLooksRight: busiest == assumed))
}

// MARK: V8 act

func cmdAct(_ args: Args) {
    let pos = args.positional
    guard pos.count == 2, let pid = Int32(pos[1]), let e = ProcessTable.lookup(pid: pid) else {
        print("usage: jankprobe act <bg-on|bg-off|stop|cont|term> <pid>")
        exit(64)
    }
    let ref = PIDRef(pid: pid, startTime: e.startTime, uid: e.uid)
    let before = ProcessOps.isBackground(pid)
    let r: ProcessOpResult
    switch pos[0] {
    case "bg-on": r = ProcessOps.setBackground(ref, on: true)
    case "bg-off": r = ProcessOps.setBackground(ref, on: false)
    case "stop": r = ProcessOps.signal(ref, SIGSTOP)
    case "cont": r = ProcessOps.signal(ref, SIGCONT)
    case "term": r = ProcessOps.signal(ref, SIGTERM)
    default:
        print("unknown action")
        exit(64)
    }
    usleep(200_000)
    let st = Shell.run("/bin/ps", ["-o", "pid=,stat=,ni=,pri=,comm=", "-p", String(pid)])
    print("result: \(r)")
    print("darwin-background before: \(before.map { "\($0)" } ?? "?") after: \(ProcessOps.isBackground(pid).map { "\($0)" } ?? "?")")
    print("ps: \(st.output.trimmingCharacters(in: .whitespacesAndNewlines))")
    if r == .denied, let ctl = AdminRunner.jankctlPath {
        print("denied: JankWatch would retry via admin: \(ctl) \(pos[0]) \(pid):\(e.startTime)")
    }
}

// MARK: V6 engine (headless)

final class PrintDelegate: EngineDelegate {
    var lastPhase: DetectorPhase = .normal
    var lastGate: GateState = .off
    var tick = 0
    let verbose: Bool
    init(verbose: Bool) { self.verbose = verbose }

    func engineDidUpdate(_ s: EngineStatus) {
        tick += 1
        let sig = s.lastSignals
        if verbose || s.phase != lastPhase || s.gate != lastGate || sig.total > 0 {
            print(String(format: "[%5d] gate=%@ phase=%@ score=%.2f (probe %.2f input %.2f front %.2f) %@ selfCPU=%.1f%%",
                         tick, s.gate.rawValue, s.phase.rawValue, sig.total, sig.probeScore, sig.inputScore, sig.frontScore,
                         sig.reasons.joined(separator: ","), s.selfCPUPercent))
        }
        lastPhase = s.phase
        lastGate = s.gate
    }

    func engineShowAlert(_ a: AlertModel) {
        print("\n>>> ALERT: \(a.diagnosis.cause.rawValue) — \(a.diagnosis.headline)")
        for e in a.diagnosis.evidence { print("    · \(e)") }
        for c in a.diagnosis.culprits {
            print("    culprit: \(c.displayName) [\(c.category.rawValue)] \(c.metricsSummary) actions=\(c.allowedActions.map(\.rawValue)) recommended=\(c.recommended?.rawValue ?? "-") admin=\(c.needsAdmin)")
        }
        print("")
    }

    func engineUpdateAlert(_ a: AlertModel) {
        if a.ended { print("<<< episode ended (\(a.episode.durationSec.map { String(format: "%.0f s", $0) } ?? "?"))") }
    }

    func engineMessage(_ m: String) { print("msg: \(m)") }
}

func cmdEngine(_ args: Args) {
    let seconds = args.double("--seconds", 0)
    let root = args.value("--data").map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        ?? EventStore.defaultRoot().deletingLastPathComponent().appendingPathComponent("JankWatch-probe")
    print("engine: data → \(root.path). Ctrl-C to stop.")
    let engine = Engine(store: EventStore(root: root))
    let delegate = PrintDelegate(verbose: args.has("--verbose"))
    engine.delegate = delegate
    engine.start()
    signal(SIGINT) { _ in exit(0) }
    if seconds > 0 { spin(seconds) } else { while true { spin(3600) } }
    engine.stop()
}
#endif
