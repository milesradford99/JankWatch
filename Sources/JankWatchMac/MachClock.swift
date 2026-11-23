#if os(macOS)
import Darwin
import Foundation
import JankWatchCore

public enum MachClock {
    public static let timebase: TimeBase = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return TimeBase(numer: info.numer, denom: info.denom)
    }()

    @inline(__always)
    public static func now() -> UInt64 { mach_absolute_time() }

    /// Monotonic seconds since boot (does not advance while asleep).
    public static func uptimeSeconds() -> Double { timebase.ticksToSeconds(mach_absolute_time()) }

    /// CPU time consumed by this process so far, in nanoseconds (trusted reference clock).
    public static func processCPUNanos() -> UInt64 { clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID) }
}

public enum MachineInfo {
    public static var arch: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    public static var osVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    public static func sysctlInt(_ name: String) -> Int? {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        if sysctlbyname(name, &value, &size, nil, 0) == 0 {
            if size == MemoryLayout<Int32>.size {
                return Int(Int32(truncatingIfNeeded: value))
            }
            return Int(value)
        }
        return nil
    }

    public static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }

    public static var modelIdentifier: String { sysctlString("hw.model") ?? "unknown" }
    public static var cpuBrand: String { sysctlString("machdep.cpu.brand_string") ?? "unknown" }

    public static var topology: CPUTopology {
        let logical = sysctlInt("hw.logicalcpu") ?? ProcessInfo.processInfo.activeProcessorCount
        let levels = sysctlInt("hw.nperflevels") ?? 1
        if levels >= 2 {
            return CPUTopology(logical: logical, perfCount: sysctlInt("hw.perflevel0.logicalcpu"), effCount: sysctlInt("hw.perflevel1.logicalcpu"))
        }
        return CPUTopology(logical: logical, perfCount: nil, effCount: nil)
    }

    public static var currentUID: UInt32 { getuid() }

    public static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    public static func runMeta(inputClock: InputClockMode?, rusageUnit: RusageTimeUnit?) -> RunMeta {
        RunMeta(appVersion: appVersion, arch: arch, osVersion: osVersion, timebase: MachClock.timebase,
                inputClock: inputClock, rusageUnit: rusageUnit)
    }
}

/// Run a command and capture stdout (used for `ps`, `pmset`). Blocks the calling thread.
public enum Shell {
    public static func run(_ path: String, _ args: [String], timeout: TimeInterval = 5) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return (-1, "") }
        // Read before waiting so a large output cannot fill the pipe and deadlock.
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { usleep(5_000) }
        if p.isRunning { p.terminate() }
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
#endif
