#if os(macOS)
import CoreGraphics
import Darwin
import Foundation
import JankWatchCore

/// Listen-only event tap measuring how long input events take to reach us (event timestamp → tap callback).
/// Requires "Input Monitoring" permission. Only timestamps and event kinds are read — never key codes or characters.
public final class InputLatencySensor {
    private let lock = NSLock()
    private var samples: [InputLatencySample] = []
    private var calibrator: TimestampClockCalibrator
    private var enabled = false
    private var tap: CFMachPort?
    private var thread: Thread?
    /// Raw candidate pairs, kept only when `debugCapture` is on (used by `jankprobe clock`).
    private var debugPairs: [(nanos: Double, ticks: Double)] = []
    public var debugCapture = false

    public init(clock: InputClockMode) {
        calibrator = TimestampClockCalibrator(forced: clock)
    }

    public static func hasPermission() -> Bool { CGPreflightListenEventAccess() }

    @discardableResult
    public static func requestPermission() -> Bool { CGRequestListenEventAccess() }

    public var clockDecision: InputClockMode? {
        lock.lock(); defer { lock.unlock() }
        return calibrator.decided
    }

    public var clockCalibrationFailed: Bool {
        lock.lock(); defer { lock.unlock() }
        return calibrator.failed
    }

    public var isInstalled: Bool { tap != nil }

    /// Create the tap on a dedicated run-loop thread (so a busy main thread never delays our measurements).
    /// Returns false if the tap could not be created (usually: no Input Monitoring permission).
    @discardableResult
    public func install() -> Bool {
        if tap != nil { return true }
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue) |
            (1 << CGEventType.scrollWheel.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                           eventsOfInterest: mask, callback: inputTapCallback, userInfo: refcon) else {
            return false
        }
        tap = port
        CGEvent.tapEnable(tap: port, enable: false)
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        let t = Thread {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CFRunLoopRun()
        }
        t.name = "JankWatch.inputTap"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
        return true
    }

    public func setEnabled(_ on: Bool) {
        lock.lock()
        enabled = on
        if !on { samples.removeAll() }
        lock.unlock()
        if let tap { CGEvent.tapEnable(tap: tap, enable: on) }
    }

    public func drain() -> [InputLatencySample] {
        lock.lock()
        defer { lock.unlock() }
        let r = samples
        samples.removeAll(keepingCapacity: true)
        return r
    }

    public func drainDebugPairs() -> [(nanos: Double, ticks: Double)] {
        lock.lock()
        defer { lock.unlock() }
        let r = debugPairs
        debugPairs.removeAll()
        return r
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap, enabled { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        let nowTicks = mach_absolute_time()
        let tb = MachClock.timebase
        let ts = event.timestamp
        let nowNanos = tb.ticksToNanos(nowTicks)
        let ifNanos = (Double(nowNanos) - Double(ts)) / 1_000_000
        let ifTicks = tb.ticksToMillis(Double(nowTicks) - Double(ts))
        let kind: InputEventKind
        switch type {
        case .keyDown: kind = .key
        case .scrollWheel: kind = .scroll
        default: kind = .click
        }
        lock.lock()
        defer { lock.unlock() }
        guard enabled else { return }
        if debugCapture { debugPairs.append((ifNanos, ifTicks)) }
        guard let mode = calibrator.observe(latencyIfNanosMs: ifNanos, latencyIfTicksMs: ifTicks) else { return }
        let ms = TimestampClockCalibrator.latency(mode: mode, latencyIfNanosMs: ifNanos, latencyIfTicksMs: ifTicks)
        // Ignore implausible values (synthetic events with odd timestamps).
        guard ms > -1, ms < 10_000 else { return }
        samples.append(InputLatencySample(kind: kind, latencyMs: max(0, ms)))
        if samples.count > 5000 { samples.removeFirst(2500) }
    }
}

private func inputTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if let refcon {
        let sensor = Unmanaged<InputLatencySensor>.fromOpaque(refcon).takeUnretainedValue()
        sensor.handle(type: type, event: event)
    }
    return Unmanaged.passUnretained(event)
}
#endif
