#if os(macOS)
import Darwin
import Foundation
import JankWatchCore

/// System-wide CPU, memory and thermal state.
public final class SystemSampler {
    private var prevCores: [CPULoad.CoreTicks]?
    private var prevVM: (at: Double, swapins: UInt64, swapouts: UInt64, pageins: UInt64)?
    private var speedLimit: Int?
    private var lastTherm: Double = -1_000
    public let topology: CPUTopology
    public var thermPollInterval: Double
    public private(set) var lastPerCoreBusy: [Double] = []
    private let pageSize = UInt64(getpagesize())

    public init(thermPollInterval: Double) {
        self.thermPollInterval = thermPollInterval
        topology = MachineInfo.topology
    }

    public static func coreTicks() -> [CPULoad.CoreTicks]? {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let kr = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount)
        guard kr == KERN_SUCCESS, let info else { return nil }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)), vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }
        var out: [CPULoad.CoreTicks] = []
        let stride = Int(CPU_STATE_MAX)
        for i in 0..<Int(count) {
            let base = stride * i
            out.append(CPULoad.CoreTicks(
                user: UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]),
                system: UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]),
                idle: UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]),
                nice: UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)])))
        }
        return out
    }

    public static func vmStats() -> vm_statistics64? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        return kr == KERN_SUCCESS ? stats : nil
    }

    public static func memoryPressure() -> MemoryPressure {
        var level: Int32 = 1
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) != 0 { return .normal }
        return MemoryPressure(sysctlLevel: level)
    }

    public static func swapUsed() -> UInt64 {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &usage, &size, nil, 0) != 0 { return 0 }
        return usage.xsu_used
    }

    public static func thermal() -> ThermalLevel {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return .nominal
        }
    }

    public func reset() {
        prevCores = nil
        prevVM = nil
    }

    public func sample() -> SystemSample? {
        let now = MachClock.uptimeSeconds()
        guard let cores = Self.coreTicks() else { return nil }
        defer { prevCores = cores }
        guard let prev = prevCores else {
            _ = updateVM(now: now)
            return nil
        }
        let busy = CPULoad.busy(prev: prev, cur: cores)
        lastPerCoreBusy = busy
        let avg = busy.isEmpty ? 0 : busy.reduce(0, +) / Double(busy.count)
        let vm = updateVM(now: now)

        #if arch(x86_64)
        if now - lastTherm >= thermPollInterval {
            lastTherm = now
            let r = Shell.run("/usr/bin/pmset", ["-g", "therm"])
            speedLimit = PmsetParser.cpuSpeedLimit(r.output)
        }
        #endif

        let stats = Self.vmStats()
        let compressed = UInt64(stats?.compressor_page_count ?? 0) * pageSize
        return SystemSample(cpuBusy: avg, pCoreBusy: topology.pCoreBusy(busy), logicalCPUs: busy.count,
                            memoryPressure: Self.memoryPressure(), swapInBytesPerSec: vm.swapIn, swapOutBytesPerSec: vm.swapOut,
                            pageInBytesPerSec: vm.pageIn, swapUsedBytes: Self.swapUsed(), compressedBytes: compressed,
                            thermal: Self.thermal(), cpuSpeedLimit: speedLimit)
    }

    private func updateVM(now: Double) -> (swapIn: Double, swapOut: Double, pageIn: Double) {
        guard let s = Self.vmStats() else { return (0, 0, 0) }
        defer { prevVM = (now, s.swapins, s.swapouts, s.pageins) }
        guard let p = prevVM, now > p.at else { return (0, 0, 0) }
        let dt = now - p.at
        func rate(_ a: UInt64, _ b: UInt64) -> Double { a >= b ? Double((a - b) * pageSize) / dt : 0 }
        return (rate(s.swapins, p.swapins), rate(s.swapouts, p.swapouts), rate(s.pageins, p.pageins))
    }
}
#endif
