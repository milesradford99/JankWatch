import Foundation

/// Cumulative counters read from the OS for one process.
public struct RawProcessCounters: Equatable, Sendable {
    public var ref: PIDRef
    public var ppid: Int32
    public var name: String
    public var path: String?
    /// Cumulative CPU time (user + system), nanoseconds.
    public var cpuNanos: UInt64?
    /// Monotonic seconds when `cpuNanos` / disk counters were measured (fallback data is refreshed less often).
    public var measuredAt: Double
    public var diskReadBytes: UInt64?
    public var diskWriteBytes: UInt64?
    public var memoryBytes: UInt64?
    public var viaFallback: Bool

    public init(ref: PIDRef, ppid: Int32, name: String, path: String?, cpuNanos: UInt64?, measuredAt: Double,
                diskReadBytes: UInt64? = nil, diskWriteBytes: UInt64? = nil, memoryBytes: UInt64? = nil, viaFallback: Bool = false) {
        self.ref = ref
        self.ppid = ppid
        self.name = name
        self.path = path
        self.cpuNanos = cpuNanos
        self.measuredAt = measuredAt
        self.diskReadBytes = diskReadBytes
        self.diskWriteBytes = diskWriteBytes
        self.memoryBytes = memoryBytes
        self.viaFallback = viaFallback
    }
}

/// Turns cumulative counters into per-second rates, handling pid reuse and slowly refreshed fallback data.
public struct ProcessDeltaComputer {
    struct Prev {
        var startTime: Double
        var cpuNanos: UInt64?
        var read: UInt64?
        var write: UInt64?
        var at: Double
        var cpuRate: Double?
        var readRate: Double?
        var writeRate: Double?
    }

    private var prev: [Int32: Prev] = [:]
    private var lastNowWall: Double?

    public init() {}

    public mutating func reset() {
        prev.removeAll()
        lastNowWall = nil
    }

    private static func rate(_ cur: UInt64?, _ old: UInt64?, _ dt: Double) -> Double? {
        guard let cur, let old, dt > 0 else { return nil }
        if cur < old { return nil }
        return Double(cur - old) / dt
    }

    /// - Parameter nowWall: wall clock seconds since 1970 (used to detect processes born since the last sample).
    public mutating func compute(_ current: [RawProcessCounters], nowWall: Double) -> [ProcessSample] {
        var next: [Int32: Prev] = [:]
        next.reserveCapacity(current.count)
        var out: [ProcessSample] = []
        out.reserveCapacity(current.count)

        for c in current {
            var cpuRate: Double?
            var readRate: Double?
            var writeRate: Double?

            if let p = prev[c.ref.pid], abs(p.startTime - c.ref.startTime) < 0.001 {
                let dt = c.measuredAt - p.at
                if dt > 0.05 {
                    cpuRate = Self.rate(c.cpuNanos, p.cpuNanos, dt).map { $0 / 1e9 * 100 }
                    readRate = Self.rate(c.diskReadBytes, p.read, dt)
                    writeRate = Self.rate(c.diskWriteBytes, p.write, dt)
                    next[c.ref.pid] = Prev(startTime: c.ref.startTime, cpuNanos: c.cpuNanos, read: c.diskReadBytes, write: c.diskWriteBytes,
                                           at: c.measuredAt, cpuRate: cpuRate, readRate: readRate, writeRate: writeRate)
                } else {
                    // Counters not refreshed since last time (fallback data): reuse the previous rates.
                    cpuRate = p.cpuRate
                    readRate = p.readRate
                    writeRate = p.writeRate
                    next[c.ref.pid] = p
                }
            } else {
                // New process (or recycled pid). If it was born since the previous sample, its whole
                // cumulative usage happened in this interval.
                if let last = lastNowWall, c.ref.startTime > last, let cpu = c.cpuNanos {
                    let age = nowWall - c.ref.startTime
                    if age > 0.05 {
                        cpuRate = Double(cpu) / 1e9 / age * 100
                        readRate = c.diskReadBytes.map { Double($0) / age }
                        writeRate = c.diskWriteBytes.map { Double($0) / age }
                    }
                }
                next[c.ref.pid] = Prev(startTime: c.ref.startTime, cpuNanos: c.cpuNanos, read: c.diskReadBytes, write: c.diskWriteBytes,
                                       at: c.measuredAt, cpuRate: cpuRate, readRate: readRate, writeRate: writeRate)
            }

            out.append(ProcessSample(ref: c.ref, ppid: c.ppid, name: c.name, path: c.path,
                                     cpuPercent: cpuRate.map { Stats.finite($0) }, memoryBytes: c.memoryBytes,
                                     diskReadBytesPerSec: readRate.map { Stats.finite($0) },
                                     diskWriteBytesPerSec: writeRate.map { Stats.finite($0) },
                                     viaFallback: c.viaFallback))
        }
        prev = next
        lastNowWall = nowWall
        return out
    }
}

/// Parses `ps -A -o pid=,time=,rss=` (used when proc_pid_rusage is denied for other users' processes).
public enum PSParser {
    public struct Row: Equatable, Sendable {
        public var pid: Int32
        public var cpuNanos: UInt64
        public var rssBytes: UInt64
    }

    /// macOS `ps` time format: "M:SS.ss", "MM:SS.ss", "H:MM:SS.ss" or with a day prefix "D-HH:MM:SS".
    public static func parseCPUTime(_ s: String) -> UInt64? {
        var str = Substring(s)
        var days = 0.0
        if let dash = str.firstIndex(of: "-") {
            guard let d = Double(str[..<dash]) else { return nil }
            days = d
            str = str[str.index(after: dash)...]
        }
        let parts = str.split(separator: ":")
        guard !parts.isEmpty, parts.count <= 3 else { return nil }
        var seconds = 0.0
        for part in parts {
            guard let v = Double(part) else { return nil }
            seconds = seconds * 60 + v
        }
        seconds += days * 86400
        return UInt64((seconds * 1e9).rounded())
    }

    public static func parse(_ output: String) -> [Int32: Row] {
        var rows: [Int32: Row] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let f = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard f.count >= 3, let pid = Int32(f[0]), let cpu = parseCPUTime(String(f[1])), let rssKB = UInt64(f[2]) else { continue }
            rows[pid] = Row(pid: pid, cpuNanos: cpu, rssBytes: rssKB * 1024)
        }
        return rows
    }
}

/// Parses `pmset -g therm` (Intel Macs) for CPU_Speed_Limit.
public enum PmsetParser {
    public static func cpuSpeedLimit(_ output: String) -> Int? {
        for line in output.split(whereSeparator: \.isNewline) where line.contains("CPU_Speed_Limit") {
            if let eq = line.firstIndex(of: "=") {
                let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                if let v = Int(value) { return v }
            }
        }
        return nil
    }
}

// MARK: - Grouping

public enum AppGrouping {
    /// The outermost `.app` bundle containing `path`, e.g. Chrome helpers map to "/Applications/Google Chrome.app".
    public static func outermostAppBundle(_ path: String) -> String? {
        guard let range = path.range(of: ".app/") else {
            return path.hasSuffix(".app") ? path : nil
        }
        return String(path[..<range.lowerBound]) + ".app"
    }

    public static func displayName(forBundle bundlePath: String) -> String {
        let last = (bundlePath as NSString).lastPathComponent
        return last.hasSuffix(".app") ? String(last.dropLast(4)) : last
    }

    /// Executable name: last path component of the full path when available (proc_name is truncated to 32 chars).
    public static func processName(name: String, path: String?) -> String {
        if let p = path, !p.isEmpty {
            let last = (p as NSString).lastPathComponent
            if !last.isEmpty { return last }
        }
        return name
    }

    public static func groupKey(processName: String, path: String?, kb: KnowledgeBase) -> (key: String, name: String, bundlePath: String?) {
        if let entry = kb.lookup(processName), let g = entry.group {
            return ("kb:" + g, g, nil)
        }
        if let p = path, let bundle = outermostAppBundle(p) {
            return ("app:" + bundle, displayName(forBundle: bundle), bundle)
        }
        return ("proc:" + processName, processName, nil)
    }
}

public enum ProcessAggregator {
    /// Group processes and keep the interesting groups (top by CPU ∪ memory ∪ disk).
    public static func aggregate(_ samples: [ProcessSample], kb: KnowledgeBase, currentUID: UInt32,
                                 topCPU: Int = 12, topMemory: Int = 8, topDisk: Int = 6) -> [GroupSample] {
        struct Acc {
            var key: String, name: String, bundlePath: String?
            var cpu = 0.0, mem: UInt64 = 0, disk = 0.0
            var pids: [PIDRef] = []
            var mainPID: Int32 = 0, mainPath: String?, mainName = "", mainScore = Int.max
            var owned = true, partial = false
        }
        var accs: [String: Acc] = [:]
        for s in samples {
            let pname = AppGrouping.processName(name: s.name, path: s.path)
            let g = AppGrouping.groupKey(processName: pname, path: s.path, kb: kb)
            var a = accs[g.key] ?? Acc(key: g.key, name: g.name, bundlePath: g.bundlePath)
            if let c = s.cpuPercent { a.cpu += c } else { a.partial = true }
            if let m = s.memoryBytes { a.mem += m }
            a.disk += (s.diskReadBytesPerSec ?? 0) + (s.diskWriteBytesPerSec ?? 0)
            a.pids.append(s.ref)
            if s.ref.uid != currentUID { a.owned = false }
            // Main process: the one whose executable path is shortest (the app's own binary, not a nested helper).
            let score = s.path?.count ?? 10_000
            if score < a.mainScore {
                a.mainScore = score
                a.mainPID = s.ref.pid
                a.mainPath = s.path
                a.mainName = pname
            }
            accs[g.key] = a
        }
        let all = accs.values.map {
            GroupSample(key: $0.key, name: $0.name, bundlePath: $0.bundlePath, mainPath: $0.mainPath, mainProcessName: $0.mainName,
                        cpuPercent: $0.cpu, memoryBytes: $0.mem, diskBytesPerSec: $0.disk,
                        pids: $0.pids.sorted { $0.pid < $1.pid }, mainPID: $0.mainPID, ownedByCurrentUser: $0.owned, partial: $0.partial)
        }
        var keep = Set<String>()
        for g in all.sorted(by: { $0.cpuPercent > $1.cpuPercent }).prefix(topCPU) { keep.insert(g.key) }
        for g in all.sorted(by: { $0.memoryBytes > $1.memoryBytes }).prefix(topMemory) { keep.insert(g.key) }
        for g in all.sorted(by: { $0.diskBytesPerSec > $1.diskBytesPerSec }).prefix(topDisk) where g.diskBytesPerSec > 0 { keep.insert(g.key) }
        // Always keep these, they are evidence for specific causes.
        for g in all where g.name == "WindowServer" || g.name == "kernel_task" { keep.insert(g.key) }
        return all.filter { keep.contains($0.key) }.sorted { $0.cpuPercent > $1.cpuPercent }
    }
}
