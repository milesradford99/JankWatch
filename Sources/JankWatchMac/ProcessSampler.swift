#if os(macOS)
import Darwin
import Foundation
import JankWatchCore

/// Basic identity of every process, readable without privileges via sysctl(KERN_PROC_ALL).
public struct KinfoEntry: Sendable {
    public var pid: Int32
    public var ppid: Int32
    public var uid: UInt32
    public var comm: String
    public var startTime: Double
    public var isZombie: Bool
}

public enum ProcessTable {
    public static func all() -> [KinfoEntry] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return [] }
        let stride = MemoryLayout<kinfo_proc>.stride
        // The table can grow between the two calls: leave headroom.
        var capacity = size / stride + 32
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: capacity)
        size = capacity * stride
        var rc = procs.withUnsafeMutableBytes { sysctl(&mib, UInt32(mib.count), $0.baseAddress, &size, nil, 0) }
        if rc != 0 && errno == ENOMEM {
            capacity *= 2
            procs = [kinfo_proc](repeating: kinfo_proc(), count: capacity)
            size = capacity * stride
            rc = procs.withUnsafeMutableBytes { sysctl(&mib, UInt32(mib.count), $0.baseAddress, &size, nil, 0) }
        }
        guard rc == 0 else { return [] }
        let n = size / stride
        return procs.prefix(n).map(entry(from:))
    }

    public static func lookup(pid: Int32) -> KinfoEntry? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let e = entry(from: info)
        return e.pid == pid ? e : nil
    }

    static func entry(from p: kinfo_proc) -> KinfoEntry {
        var comm16 = p.kp_proc.p_comm
        let commSize = MemoryLayout.size(ofValue: comm16)
        let comm = withUnsafePointer(to: &comm16) {
            $0.withMemoryRebound(to: CChar.self, capacity: commSize) { String(cString: $0) }
        }
        // `p_starttime` is a C macro for `p_un.__p_starttime`, so it has to be spelled out in Swift.
        let tv = p.kp_proc.p_un.__p_starttime
        return KinfoEntry(pid: p.kp_proc.p_pid, ppid: p.kp_eproc.e_ppid, uid: p.kp_eproc.e_ucred.cr_uid, comm: comm,
                          startTime: Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000,
                          isZombie: Int32(p.kp_proc.p_stat) == Int32(SZOMB))
    }

    /// True if `ref` still names the same process (guards against pid reuse before signalling).
    public static func isSame(_ ref: PIDRef) -> Bool {
        guard let e = lookup(pid: ref.pid), !e.isZombie else { return false }
        return abs(e.startTime - ref.startTime) < 0.001
    }

    public static func path(pid: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: 4096)  // PROC_PIDPATHINFO_MAXSIZE
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        guard n > 0 else { return nil }
        return String(cString: buf)
    }

    public static func name(pid: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: 64)
        let n = proc_name(pid, &buf, UInt32(buf.count))
        guard n > 0 else { return nil }
        return String(cString: buf)
    }
}

public struct RusageReading: Sendable {
    public var cpuRaw: UInt64
    public var diskRead: UInt64
    public var diskWrite: UInt64
    public var footprint: UInt64
}

public enum Rusage {
    /// proc_pid_rusage(RUSAGE_INFO_V4). Returns nil and sets `errno` on failure (EPERM for other users' processes
    /// when not root — to be confirmed on hardware, docs/VALIDATION.md V2).
    public static func read(pid: Int32) -> (RusageReading?, Int32) {
        var info = rusage_info_v4()
        let rc = withUnsafeMutablePointer(to: &info) { ptr -> Int32 in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        guard rc == 0 else { return (nil, errno) }
        return (RusageReading(cpuRaw: info.ri_user_time &+ info.ri_system_time, diskRead: info.ri_diskio_bytesread,
                              diskWrite: info.ri_diskio_byteswritten, footprint: info.ri_phys_footprint), 0)
    }

    /// Determine the unit of ri_user_time on this machine by burning ~100 ms of CPU and comparing against
    /// CLOCK_PROCESS_CPUTIME_ID.
    public static func calibrateUnit() -> RusageTimeUnit? {
        let pid = getpid()
        guard let before = read(pid: pid).0 else { return nil }
        let cpuBefore = MachClock.processCPUNanos()
        let deadline = mach_absolute_time() + MachClock.timebase.nanosToTicks(120_000_000)
        var sink: UInt64 = 0
        while mach_absolute_time() < deadline { sink &+= probeSpinWork(10_000) }
        guard let after = read(pid: pid).0 else { return nil }
        let cpuAfter = MachClock.processCPUNanos()
        if sink == 7 { print("") }
        return RusageUnitCalibrator.decide(rawDelta: after.cpuRaw &- before.cpuRaw, trueNanosDelta: cpuAfter &- cpuBefore,
                                           timebase: MachClock.timebase)
    }
}

/// Reads per-process counters each tick. Uses proc_pid_rusage where permitted, and `ps` (refreshed every few
/// seconds) for processes we are not allowed to inspect.
public final class ProcessSampler {
    public private(set) var rusageUnit: RusageTimeUnit
    public var fallbackInterval: Double
    private var pathCache: [Int32: (start: Double, path: String?, name: String)] = [:]
    private var fallbackPIDs = Set<Int32>()
    private var psRows: [Int32: PSParser.Row] = [:]
    private var psMeasuredAt: Double = -1_000
    public private(set) var lastStats = SampleStats()
    private let ownPID = getpid()

    public struct SampleStats: Sendable {
        public var total = 0
        public var rusageOK = 0
        public var rusageDenied = 0
        public var viaPS = 0
        public var unknown = 0
    }

    public init(rusageUnit: RusageTimeUnit, fallbackInterval: Double) {
        self.fallbackInterval = fallbackInterval
        if rusageUnit == .auto {
            self.rusageUnit = Rusage.calibrateUnit() ?? (MachClock.timebase.isIdentity ? .nanoseconds : .machTicks)
        } else {
            self.rusageUnit = rusageUnit
        }
    }

    private func refreshPS(now: Double) {
        guard now - psMeasuredAt >= fallbackInterval else { return }
        let r = Shell.run("/bin/ps", ["-A", "-o", "pid=,time=,rss="])
        if r.status == 0 {
            psRows = PSParser.parse(r.output)
            psMeasuredAt = now
        }
    }

    public func sample() -> [RawProcessCounters] {
        let now = MachClock.uptimeSeconds()
        let table = ProcessTable.all()
        var out: [RawProcessCounters] = []
        out.reserveCapacity(table.count)
        var stats = SampleStats()
        if !fallbackPIDs.isEmpty { refreshPS(now: now) }
        var newFallback = Set<Int32>()
        var alive = Set<Int32>()

        for e in table where !e.isZombie {
            alive.insert(e.pid)
            stats.total += 1
            let ref = PIDRef(pid: e.pid, startTime: e.startTime, uid: e.uid)
            let ident: (start: Double, path: String?, name: String)
            if let c = pathCache[e.pid], abs(c.start - e.startTime) < 0.001 {
                ident = c
            } else {
                let path = e.pid == 0 ? nil : ProcessTable.path(pid: e.pid)
                let name = e.pid == 0 ? "kernel_task" : (ProcessTable.name(pid: e.pid) ?? e.comm)
                ident = (e.startTime, path, name)
                pathCache[e.pid] = ident
            }

            let (reading, err) = Rusage.read(pid: e.pid)
            if let r = reading {
                stats.rusageOK += 1
                out.append(RawProcessCounters(ref: ref, ppid: e.ppid, name: ident.name, path: ident.path,
                                              cpuNanos: RusageUnitCalibrator.toNanos(r.cpuRaw, unit: rusageUnit, timebase: MachClock.timebase),
                                              measuredAt: now, diskReadBytes: r.diskRead, diskWriteBytes: r.diskWrite,
                                              memoryBytes: r.footprint, viaFallback: false))
            } else {
                if err == EPERM || err == EACCES { stats.rusageDenied += 1 }
                newFallback.insert(e.pid)
                if let row = psRows[e.pid] {
                    stats.viaPS += 1
                    out.append(RawProcessCounters(ref: ref, ppid: e.ppid, name: ident.name, path: ident.path, cpuNanos: row.cpuNanos,
                                                  measuredAt: psMeasuredAt, memoryBytes: row.rssBytes, viaFallback: true))
                } else {
                    stats.unknown += 1
                    out.append(RawProcessCounters(ref: ref, ppid: e.ppid, name: ident.name, path: ident.path, cpuNanos: nil,
                                                  measuredAt: now, viaFallback: true))
                }
            }
        }
        // First time we discover denied processes, fetch ps right away so the next tick has data.
        if fallbackPIDs.isEmpty && !newFallback.isEmpty { refreshPS(now: now) }
        fallbackPIDs = newFallback
        if pathCache.count > alive.count + 256 { pathCache = pathCache.filter { alive.contains($0.key) } }
        lastStats = stats
        return out
    }

    public var ownProcessID: Int32 { ownPID }
}
#endif
