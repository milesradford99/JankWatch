import Foundation

/// Whether JankWatch is monitoring right now.
public enum GateState: String, Codable, Sendable {
    /// Screen asleep, screen locked, or the user session is not on console. Nothing is sampled.
    case off
    /// Screen on but no input for a while. Only cheap bookkeeping.
    case idle
    /// Screen on and the user is using the Mac. Full 1 Hz sampling + symptom probes.
    case active
}

// MARK: - Symptom samples

/// Aggregated scheduling-latency probe results for one tick (~1 s).
public struct ProbeWindowStats: Codable, Equatable, Sendable {
    /// Number of probe wake-ups that happened in the window.
    public var samples: Int
    /// Wake-ups we expected in the window (1000 / intervalMs).
    public var expected: Int
    public var latenessP50Ms: Double
    public var latenessP95Ms: Double
    public var latenessMaxMs: Double
    /// Median duration of the fixed CPU work unit, nil if no work sample in window.
    public var workP50Ms: Double?

    public init(samples: Int, expected: Int, latenessP50Ms: Double, latenessP95Ms: Double, latenessMaxMs: Double, workP50Ms: Double?) {
        self.samples = samples
        self.expected = expected
        self.latenessP50Ms = latenessP50Ms
        self.latenessP95Ms = latenessP95Ms
        self.latenessMaxMs = latenessMaxMs
        self.workP50Ms = workP50Ms
    }

    public static func from(latenessMs: [Double], workMs: [Double], expected: Int) -> ProbeWindowStats {
        ProbeWindowStats(
            samples: latenessMs.count,
            expected: expected,
            latenessP50Ms: Stats.percentile(latenessMs, 0.5) ?? 0,
            latenessP95Ms: Stats.percentile(latenessMs, 0.95) ?? 0,
            latenessMaxMs: latenessMs.max() ?? 0,
            workP50Ms: Stats.median(workMs)
        )
    }
}

public enum InputEventKind: String, Codable, Sendable {
    case key, click, scroll
}

/// One input event's delivery latency: time from the event's hardware timestamp to our tap receiving it.
public struct InputLatencySample: Codable, Equatable, Sendable {
    public var kind: InputEventKind
    public var latencyMs: Double
    public init(kind: InputEventKind, latencyMs: Double) {
        self.kind = kind
        self.latencyMs = latencyMs
    }
}

public struct InputWindowStats: Codable, Equatable, Sendable {
    public var count: Int
    public var maxMs: Double
    public var p95Ms: Double
    public var overModerate: Int
    public var overSevere: Int

    public init(count: Int = 0, maxMs: Double = 0, p95Ms: Double = 0, overModerate: Int = 0, overSevere: Int = 0) {
        self.count = count
        self.maxMs = maxMs
        self.p95Ms = p95Ms
        self.overModerate = overModerate
        self.overSevere = overSevere
    }

    public static let empty = InputWindowStats()

    public static func from(_ samples: [InputLatencySample], moderateMs: Double, severeMs: Double) -> InputWindowStats {
        let lat = samples.map { max(0, $0.latencyMs) }
        return InputWindowStats(
            count: lat.count,
            maxMs: lat.max() ?? 0,
            p95Ms: Stats.percentile(lat, 0.95) ?? 0,
            overModerate: lat.filter { $0 >= moderateMs }.count,
            overSevere: lat.filter { $0 >= severeMs }.count
        )
    }
}

/// Result of one accessibility round trip to the frontmost app.
public struct FrontAppSample: Codable, Equatable, Sendable {
    public var pid: Int32
    public var roundTripMs: Double
    public var timedOut: Bool
    public init(pid: Int32, roundTripMs: Double, timedOut: Bool) {
        self.pid = pid
        self.roundTripMs = roundTripMs
        self.timedOut = timedOut
    }
}

public struct FrontAppStats: Codable, Equatable, Sendable {
    public var pid: Int32
    public var bundleID: String?
    public var name: String?
    public var bundlePath: String?
    /// nil when AX probing is disabled / not permitted / skipped for this app.
    public var maxRoundTripMs: Double?
    public var timedOut: Bool

    public init(pid: Int32, bundleID: String?, name: String?, bundlePath: String?, maxRoundTripMs: Double?, timedOut: Bool) {
        self.pid = pid
        self.bundleID = bundleID
        self.name = name
        self.bundlePath = bundlePath
        self.maxRoundTripMs = maxRoundTripMs
        self.timedOut = timedOut
    }
}

// MARK: - Context samples

public enum MemoryPressure: Int, Codable, Comparable, Sendable {
    case normal = 1
    case warning = 2
    case critical = 4

    public static func < (a: MemoryPressure, b: MemoryPressure) -> Bool { a.rawValue < b.rawValue }

    public init(sysctlLevel: Int32) {
        switch sysctlLevel {
        case 4...: self = .critical
        case 2...3: self = .warning
        default: self = .normal
        }
    }
}

/// Mirrors ProcessInfo.ThermalState.
public enum ThermalLevel: Int, Codable, Comparable, Sendable {
    case nominal = 0, fair = 1, serious = 2, critical = 3
    public static func < (a: ThermalLevel, b: ThermalLevel) -> Bool { a.rawValue < b.rawValue }
}

public struct SystemSample: Codable, Equatable, Sendable {
    /// Average busy fraction across all logical CPUs, 0...1.
    public var cpuBusy: Double
    /// Busy fraction of performance cores only (Apple Silicon), nil if unknown.
    public var pCoreBusy: Double?
    public var logicalCPUs: Int
    public var memoryPressure: MemoryPressure
    public var swapInBytesPerSec: Double
    public var swapOutBytesPerSec: Double
    public var pageInBytesPerSec: Double
    public var swapUsedBytes: UInt64
    public var compressedBytes: UInt64
    public var thermal: ThermalLevel
    /// Intel only: `pmset -g therm` CPU_Speed_Limit (100 = not throttled).
    public var cpuSpeedLimit: Int?

    public init(cpuBusy: Double, pCoreBusy: Double?, logicalCPUs: Int, memoryPressure: MemoryPressure,
                swapInBytesPerSec: Double, swapOutBytesPerSec: Double, pageInBytesPerSec: Double,
                swapUsedBytes: UInt64, compressedBytes: UInt64, thermal: ThermalLevel, cpuSpeedLimit: Int?) {
        self.cpuBusy = cpuBusy
        self.pCoreBusy = pCoreBusy
        self.logicalCPUs = logicalCPUs
        self.memoryPressure = memoryPressure
        self.swapInBytesPerSec = swapInBytesPerSec
        self.swapOutBytesPerSec = swapOutBytesPerSec
        self.pageInBytesPerSec = pageInBytesPerSec
        self.swapUsedBytes = swapUsedBytes
        self.compressedBytes = compressedBytes
        self.thermal = thermal
        self.cpuSpeedLimit = cpuSpeedLimit
    }
}

/// Stable identity of a process: pid plus start time, so a recycled pid is never mistaken for the original.
public struct PIDRef: Codable, Hashable, Sendable {
    public var pid: Int32
    /// Process start time, seconds since 1970 (from kinfo_proc p_starttime).
    public var startTime: Double
    public var uid: UInt32

    public init(pid: Int32, startTime: Double, uid: UInt32) {
        self.pid = pid
        self.startTime = startTime
        self.uid = uid
    }
}

/// Per-process metrics for one tick (already turned into rates).
public struct ProcessSample: Codable, Equatable, Sendable {
    public var ref: PIDRef
    public var ppid: Int32
    public var name: String
    public var path: String?
    /// Percent of ONE core (can exceed 100). nil when not readable.
    public var cpuPercent: Double?
    /// Physical footprint (rusage) or RSS (ps fallback), bytes.
    public var memoryBytes: UInt64?
    public var diskReadBytesPerSec: Double?
    public var diskWriteBytesPerSec: Double?
    /// Metrics came from the `ps` fallback because proc_pid_rusage was denied.
    public var viaFallback: Bool

    public init(ref: PIDRef, ppid: Int32, name: String, path: String?, cpuPercent: Double?, memoryBytes: UInt64?,
                diskReadBytesPerSec: Double?, diskWriteBytesPerSec: Double?, viaFallback: Bool) {
        self.ref = ref
        self.ppid = ppid
        self.name = name
        self.path = path
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes
        self.diskReadBytesPerSec = diskReadBytesPerSec
        self.diskWriteBytesPerSec = diskWriteBytesPerSec
        self.viaFallback = viaFallback
    }
}

/// Processes aggregated into a user-meaningful unit (an app bundle, or a known system component).
public struct GroupSample: Codable, Equatable, Sendable {
    public var key: String
    public var name: String
    public var bundlePath: String?
    /// Executable path of the largest member (used for system-path heuristics).
    public var mainPath: String?
    /// Representative process name used for knowledge-base lookup.
    public var mainProcessName: String
    public var cpuPercent: Double
    public var memoryBytes: UInt64
    public var diskBytesPerSec: Double
    public var pids: [PIDRef]
    /// pid of the member that looks like the app's main process (shortest path / no parent in group).
    public var mainPID: Int32
    /// Every member is owned by the user running JankWatch (so no admin rights are needed to act).
    public var ownedByCurrentUser: Bool
    /// Some members' metrics were unavailable.
    public var partial: Bool

    public init(key: String, name: String, bundlePath: String?, mainPath: String?, mainProcessName: String, cpuPercent: Double,
                memoryBytes: UInt64, diskBytesPerSec: Double, pids: [PIDRef], mainPID: Int32, ownedByCurrentUser: Bool, partial: Bool) {
        self.key = key
        self.name = name
        self.bundlePath = bundlePath
        self.mainPath = mainPath
        self.mainProcessName = mainProcessName
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes
        self.diskBytesPerSec = diskBytesPerSec
        self.pids = pids
        self.mainPID = mainPID
        self.ownedByCurrentUser = ownedByCurrentUser
        self.partial = partial
    }
}

/// Everything known about one ~1 s interval.
public struct Tick: Codable, Equatable, Sendable {
    /// Monotonic seconds (mach uptime).
    public var t: Double
    public var wall: Date
    public var gate: GateState
    public var idleSeconds: Double
    /// User produced input within `userActiveWindowSec`.
    public var userActive: Bool
    public var probe: ProbeWindowStats?
    public var input: InputWindowStats
    public var front: FrontAppStats?
    public var system: SystemSample?
    public var groups: [GroupSample]
    public var signals: TickSignals?

    public init(t: Double, wall: Date, gate: GateState, idleSeconds: Double, userActive: Bool, probe: ProbeWindowStats? = nil,
                input: InputWindowStats = .empty, front: FrontAppStats? = nil, system: SystemSample? = nil,
                groups: [GroupSample] = [], signals: TickSignals? = nil) {
        self.t = t
        self.wall = wall
        self.gate = gate
        self.idleSeconds = idleSeconds
        self.userActive = userActive
        self.probe = probe
        self.input = input
        self.front = front
        self.system = system
        self.groups = groups
        self.signals = signals
    }

    /// A copy without per-pid lists and limited to the top groups, for the 1 Hz debug log.
    public func compact(maxGroups: Int = 5) -> Tick {
        var c = self
        c.groups = Array(groups.sorted { $0.cpuPercent > $1.cpuPercent }.prefix(maxGroups)).map {
            var g = $0
            g.pids = []
            return g
        }
        return c
    }
}
