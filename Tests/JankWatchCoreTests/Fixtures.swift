import Foundation
@testable import JankWatchCore

enum Fx {
    static let me: UInt32 = 501

    static func ref(_ pid: Int32, uid: UInt32 = me, start: Double = 1000) -> PIDRef {
        PIDRef(pid: pid, startTime: start, uid: uid)
    }

    static func group(_ name: String, key: String? = nil, bundle: String? = nil, path: String? = nil, cpu: Double = 0,
                      mem: UInt64 = 0, disk: Double = 0, pids: [Int32] = [100], owned: Bool = true, mainName: String? = nil) -> GroupSample {
        GroupSample(key: key ?? (bundle.map { "app:" + $0 } ?? "proc:" + name), name: name, bundlePath: bundle,
                    mainPath: path ?? bundle.map { $0 + "/Contents/MacOS/" + name }, mainProcessName: mainName ?? name,
                    cpuPercent: cpu, memoryBytes: mem, diskBytesPerSec: disk,
                    pids: pids.map { ref($0, uid: owned ? me : 0) }, mainPID: pids.first ?? 0, ownedByCurrentUser: owned, partial: false)
    }

    static func system(busy: Double = 0.2, pressure: MemoryPressure = .normal, swapIn: Double = 0,
                       thermal: ThermalLevel = .nominal, speedLimit: Int? = nil) -> SystemSample {
        SystemSample(cpuBusy: busy, pCoreBusy: nil, logicalCPUs: 8, memoryPressure: pressure, swapInBytesPerSec: swapIn,
                     swapOutBytesPerSec: 0, pageInBytesPerSec: 0, swapUsedBytes: 0, compressedBytes: 0, thermal: thermal, cpuSpeedLimit: speedLimit)
    }

    static func probe(p95: Double = 1, samples: Int = 20, work: Double? = 0.2) -> ProbeWindowStats {
        ProbeWindowStats(samples: samples, expected: 20, latenessP50Ms: p95 / 2, latenessP95Ms: p95, latenessMaxMs: p95 * 1.2, workP50Ms: work)
    }

    static func input(max: Double = 10, moderate: Int = 0, severe: Int = 0, count: Int = 3) -> InputWindowStats {
        InputWindowStats(count: count, maxMs: max, p95Ms: max, overModerate: moderate, overSevere: severe)
    }

    static func tick(_ t: Double, gate: GateState = .active, active: Bool = true, probe: ProbeWindowStats? = Fx.probe(),
                     input: InputWindowStats = Fx.input(), front: FrontAppStats? = nil, system: SystemSample? = Fx.system(),
                     groups: [GroupSample] = [], signals: TickSignals? = nil) -> Tick {
        Tick(t: t, wall: Date(timeIntervalSince1970: 1_800_000_000 + t), gate: gate, idleSeconds: active ? 0.5 : 120, userActive: active,
             probe: probe, input: input, front: front, system: system, groups: groups, signals: signals)
    }

    static func lagSignals(_ total: Double = 1.5, probe: Double = 1, front: Double = 0) -> TickSignals {
        TickSignals(probeScore: probe, inputScore: max(0, total - probe - front), frontScore: front, total: total, isLagTick: total >= 1, reasons: [])
    }

    static func calmSignals() -> TickSignals { .zero }
}
