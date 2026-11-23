#if os(macOS)
import Darwin
import Foundation
import JankWatchCore

/// Scheduling-latency probe. A user-interactive thread (same QoS as a foreground app's UI thread) wakes every
/// `intervalMs` and records how late it woke; every `workEvery` wake-ups it also times a fixed unit of CPU work.
/// Late wake-ups = CPU starvation; slower work = frequency throttling / heavy contention.
public final class ProbeSensor {
    private let lock = NSLock()
    private var lateness: [Double] = []
    private var work: [Double] = []
    private var running = false
    private var thread: Thread?

    public let intervalMs: Double
    public let workEvery: Int
    public let workIterations: Int

    public init(intervalMs: Double, workEvery: Int, workIterations: Int) {
        self.intervalMs = max(5, intervalMs)
        self.workEvery = max(1, workEvery)
        self.workIterations = max(1000, workIterations)
    }

    public var expectedPerSecond: Int { Int((1000 / intervalMs).rounded()) }

    public var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    public func start() {
        lock.lock()
        defer { lock.unlock() }
        guard !running else { return }
        running = true
        lateness.removeAll()
        work.removeAll()
        let t = Thread { [weak self] in self?.loop() }
        t.name = "JankWatch.probe"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
    }

    public func stop() {
        lock.lock()
        running = false
        thread = nil
        lock.unlock()
    }

    /// Take everything recorded since the last drain.
    public func drain() -> (latenessMs: [Double], workMs: [Double]) {
        lock.lock()
        defer { lock.unlock() }
        let r = (lateness, work)
        lateness.removeAll(keepingCapacity: true)
        work.removeAll(keepingCapacity: true)
        return r
    }

    private func loop() {
        let tb = MachClock.timebase
        let intervalTicks = tb.nanosToTicks(UInt64(intervalMs * 1_000_000))
        var next = mach_absolute_time() + intervalTicks
        var i = 0
        var sink: UInt64 = 0
        while isRunning {
            mach_wait_until(next)
            let now = mach_absolute_time()
            let lateMs = now > next ? tb.ticksToMillis(Double(now - next)) : 0
            var workMs: Double?
            if i % workEvery == 0 {
                let s = mach_absolute_time()
                sink &+= probeSpinWork(workIterations)
                let e = mach_absolute_time()
                workMs = tb.ticksToMillis(Double(e - s))
            }
            lock.lock()
            lateness.append(lateMs)
            if let w = workMs { work.append(w) }
            // Bound memory if nobody drains (should not happen).
            if lateness.count > 2000 { lateness.removeFirst(1000) }
            if work.count > 1000 { work.removeFirst(500) }
            lock.unlock()
            i += 1
            next += intervalTicks
            let after = mach_absolute_time()
            if after > next + intervalTicks * 4 {
                // We fell far behind (huge stall or system sleep): resynchronise instead of firing a burst.
                next = after + intervalTicks
            }
        }
        if sink == 42 { print("") }  // keep the work from being optimised away
    }
}
#endif
