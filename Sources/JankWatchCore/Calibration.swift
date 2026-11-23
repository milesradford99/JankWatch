import Foundation

/// Decides whether `CGEvent.timestamp` is in nanoseconds or Mach ticks by looking at which interpretation
/// gives plausible delivery latencies (0 ms ... 1 s). On Intel both are identical.
public struct TimestampClockCalibrator: Sendable {
    public private(set) var decided: InputClockMode?
    private var asNanos: [Double] = []
    private var asTicks: [Double] = []
    public let minSamples: Int
    public let giveUpAfter: Int

    public init(forced: InputClockMode = .auto, minSamples: Int = 10, giveUpAfter: Int = 60) {
        self.minSamples = minSamples
        self.giveUpAfter = giveUpAfter
        if forced != .auto { decided = forced }
    }

    public var failed: Bool { decided == nil && asNanos.count >= giveUpAfter }
    public var sampleCount: Int { asNanos.count }

    static func plausibleFraction(_ v: [Double]) -> Double {
        guard !v.isEmpty else { return 0 }
        return Double(v.filter { $0 >= -1 && $0 < 1000 }.count) / Double(v.count)
    }

    /// Feed one event's candidate latencies (ms). Returns the decision once made.
    @discardableResult
    public mutating func observe(latencyIfNanosMs: Double, latencyIfTicksMs: Double) -> InputClockMode? {
        if let d = decided { return d }
        asNanos.append(latencyIfNanosMs)
        asTicks.append(latencyIfTicksMs)
        guard asNanos.count >= minSamples else { return nil }
        let fn = Self.plausibleFraction(asNanos)
        let ft = Self.plausibleFraction(asTicks)
        if fn >= 0.9 && fn >= ft {
            decided = .nanoseconds
        } else if ft >= 0.9 {
            decided = .machTicks
        }
        return decided
    }

    /// Latency in ms given the decided mode.
    public static func latency(mode: InputClockMode, latencyIfNanosMs: Double, latencyIfTicksMs: Double) -> Double {
        mode == .machTicks ? latencyIfTicksMs : latencyIfNanosMs
    }
}

/// Decides the unit of rusage CPU times by comparing our own process's rusage CPU delta (raw)
/// against a trusted nanosecond CPU clock delta (CLOCK_PROCESS_CPUTIME_ID).
public enum RusageUnitCalibrator {
    public static func decide(rawDelta: UInt64, trueNanosDelta: UInt64, timebase: TimeBase) -> RusageTimeUnit? {
        guard trueNanosDelta > 10_000_000 else { return nil }  // need ≥10 ms of CPU to judge
        let truth = Double(trueNanosDelta)
        let asNanos = Double(rawDelta)
        let asTicks = Double(timebase.ticksToNanos(rawDelta))
        let errN = abs(asNanos - truth) / truth
        let errT = abs(asTicks - truth) / truth
        if errN <= 0.3 && errN <= errT { return .nanoseconds }
        if errT <= 0.3 { return .machTicks }
        return nil
    }

    public static func toNanos(_ raw: UInt64, unit: RusageTimeUnit, timebase: TimeBase) -> UInt64 {
        unit == .machTicks ? timebase.ticksToNanos(raw) : raw
    }
}

/// Which logical CPU indices are performance cores. On Apple Silicon the efficiency cores are assumed to be the
/// first `effCount` indices; this assumption is checked on hardware by `jankprobe topology` (V5).
public struct CPUTopology: Codable, Equatable, Sendable {
    public var logical: Int
    public var perfCount: Int?
    public var effCount: Int?
    public var effCoresFirst: Bool

    public init(logical: Int, perfCount: Int?, effCount: Int?, effCoresFirst: Bool = true) {
        self.logical = logical
        self.perfCount = perfCount
        self.effCount = effCount
        self.effCoresFirst = effCoresFirst
    }

    public var isHeterogeneous: Bool { (perfCount ?? 0) > 0 && (effCount ?? 0) > 0 }

    public func perfIndices() -> Range<Int>? {
        guard isHeterogeneous, let p = perfCount, let e = effCount, p + e == logical else { return nil }
        return effCoresFirst ? e..<logical : 0..<p
    }

    /// Busy fraction of P cores given per-core busy fractions.
    public func pCoreBusy(_ perCore: [Double]) -> Double? {
        guard let r = perfIndices(), r.upperBound <= perCore.count, !r.isEmpty else { return nil }
        return perCore[r].reduce(0, +) / Double(r.count)
    }
}

/// Per-core busy fractions from cumulative (user, system, idle, nice) ticks. Handles UInt32 wrap-around.
public enum CPULoad {
    public struct CoreTicks: Equatable, Sendable {
        public var user: UInt32, system: UInt32, idle: UInt32, nice: UInt32
        public init(user: UInt32, system: UInt32, idle: UInt32, nice: UInt32) {
            self.user = user
            self.system = system
            self.idle = idle
            self.nice = nice
        }
    }

    public static func busy(prev: [CoreTicks], cur: [CoreTicks]) -> [Double] {
        guard prev.count == cur.count else { return [] }
        return zip(prev, cur).map { p, c in
            let u = Double(c.user &- p.user), s = Double(c.system &- p.system)
            let i = Double(c.idle &- p.idle), n = Double(c.nice &- p.nice)
            let total = u + s + i + n
            return total > 0 ? (u + s + n) / total : 0
        }
    }
}
