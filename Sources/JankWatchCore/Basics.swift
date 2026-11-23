import Foundation

/// Conversion between Mach absolute-time ticks and nanoseconds.
/// Intel Macs: numer/denom = 1/1 (1 tick = 1 ns). Apple Silicon: 125/3 (1 tick ≈ 41.67 ns).
/// Forgetting this conversion makes CPU usage on Apple Silicon off by ~24x.
public struct TimeBase: Codable, Equatable, Sendable {
    public var numer: UInt32
    public var denom: UInt32

    public init(numer: UInt32, denom: UInt32) {
        self.numer = max(numer, 1)
        self.denom = max(denom, 1)
    }

    public static let identity = TimeBase(numer: 1, denom: 1)
    public static let appleSilicon = TimeBase(numer: 125, denom: 3)

    public var isIdentity: Bool { numer == denom }

    public func ticksToNanos(_ ticks: UInt64) -> UInt64 {
        if isIdentity { return ticks }
        return UInt64((Double(ticks) * Double(numer) / Double(denom)).rounded())
    }

    public func nanosToTicks(_ nanos: UInt64) -> UInt64 {
        if isIdentity { return nanos }
        return UInt64((Double(nanos) * Double(denom) / Double(numer)).rounded())
    }

    /// Signed tick delta to milliseconds.
    public func ticksToMillis(_ ticks: Double) -> Double {
        ticks * Double(numer) / Double(denom) / 1_000_000.0
    }

    public func ticksToSeconds(_ ticks: UInt64) -> Double {
        Double(ticks) * Double(numer) / Double(denom) / 1_000_000_000.0
    }
}

public enum Stats {
    /// Linear-interpolated percentile, p in [0, 1]. Returns nil for empty input.
    public static func percentile(_ values: [Double], _ p: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        if sorted.count == 1 { return sorted[0] }
        let clamped = min(max(p, 0), 1)
        let pos = clamped * Double(sorted.count - 1)
        let lo = Int(pos.rounded(.down))
        let hi = min(lo + 1, sorted.count - 1)
        let frac = pos - Double(lo)
        return sorted[lo] + (sorted[hi] - sorted[lo]) * frac
    }

    public static func median(_ values: [Double]) -> Double? { percentile(values, 0.5) }

    public static func mean(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    /// Replace NaN / infinity with a fallback so values stay JSON-encodable.
    public static func finite(_ v: Double, _ fallback: Double = 0) -> Double {
        v.isFinite ? v : fallback
    }
}

/// Fixed-capacity FIFO buffer.
public struct RingBuffer<Element> {
    public private(set) var capacity: Int
    private var storage: [Element] = []
    private var head = 0  // index of oldest element once full

    public init(capacity: Int) {
        self.capacity = max(1, capacity)
        storage.reserveCapacity(self.capacity)
    }

    public var count: Int { storage.count }
    public var isEmpty: Bool { storage.isEmpty }

    public mutating func append(_ element: Element) {
        if storage.count < capacity {
            storage.append(element)
        } else {
            storage[head] = element
            head = (head + 1) % capacity
        }
    }

    /// All elements, oldest first.
    public var elements: [Element] {
        if storage.count < capacity || head == 0 { return storage }
        return Array(storage[head...] + storage[..<head])
    }

    /// The newest `n` elements, oldest first.
    public func last(_ n: Int) -> [Element] {
        let all = elements
        return Array(all.suffix(max(0, n)))
    }

    public var newest: Element? { elements.last }

    public mutating func removeAll() {
        storage.removeAll(keepingCapacity: true)
        head = 0
    }
}

/// Deterministic CPU work used by the probe to detect CPU slowdowns (throttling / contention).
/// Kept in Core so it can be benchmarked in tests.
@inline(never)
public func probeSpinWork(_ iterations: Int) -> UInt64 {
    var x: UInt64 = 0x9E37_79B9_7F4A_7C15
    var i = 0
    while i < iterations {
        x ^= x << 13
        x ^= x >> 7
        x ^= x << 17
        i += 1
    }
    return x
}

public enum Format {
    public static func ms(_ v: Double) -> String {
        if v >= 100 { return String(format: "%.0fms", v) }
        return String(format: "%.1fms", v)
    }

    public static func percent(_ v: Double) -> String { String(format: "%.0f%%", v) }

    public static func bytes(_ v: Double) -> String {
        let abs = Swift.abs(v)
        if abs >= 1024 * 1024 * 1024 { return String(format: "%.1fGB", v / (1024 * 1024 * 1024)) }
        if abs >= 1024 * 1024 { return String(format: "%.0fMB", v / (1024 * 1024)) }
        if abs >= 1024 { return String(format: "%.0fKB", v / 1024) }
        return String(format: "%.0fB", v)
    }

    public static func rate(_ bytesPerSec: Double) -> String { bytes(bytesPerSec) + "/s" }
}
