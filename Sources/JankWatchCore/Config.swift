import Foundation

public enum Sensitivity: String, Codable, CaseIterable, Sendable {
    case low, medium, high

    /// Multiplier applied to latency thresholds: low sensitivity = higher thresholds.
    public var thresholdScale: Double {
        switch self {
        case .low: return 1.3
        case .medium: return 1.0
        case .high: return 0.75
        }
    }

    public var label: String {
        switch self {
        case .low: return "低（少打扰）"
        case .medium: return "中"
        case .high: return "高（更敏感）"
        }
    }
}

/// How to interpret `CGEvent.timestamp`. Verified on real hardware by `jankprobe clock` (docs/VALIDATION.md V1).
public enum InputClockMode: String, Codable, Sendable {
    case auto, nanoseconds, machTicks
}

/// Unit of `rusage_info.ri_user_time` / `ri_system_time`. Verified by `jankprobe rusage` (V2).
public enum RusageTimeUnit: String, Codable, Sendable {
    case auto, nanoseconds, machTicks
}

/// All tunables. Stored as ~/Library/Application Support/JankWatch/config.json.
/// Missing keys fall back to defaults, so the file can contain only overrides.
public struct JankConfig: Codable, Equatable, Sendable {
    // Gate
    public var idleAfterSec: Double = 60
    public var userActiveWindowSec: Double = 5

    // Probe (scheduling latency)
    public var probeIntervalMs: Double = 50
    /// Run the fixed CPU work unit every N wake-ups.
    public var probeWorkEvery: Int = 4
    public var probeWorkIterations: Int = 100_000
    public var probeLatenessFloorMs: Double = 8
    public var probeLatenessNoBaselineMs: Double = 12
    public var probeLatenessBaselineMultiplier: Double = 4
    public var probeLatenessSevereMs: Double = 50
    /// Severe threshold is at least baseline × this (machines with a noisy baseline need a higher bar).
    public var probeLatenessSevereBaselineMultiplier: Double = 6
    public var probeWorkInflationModerate: Double = 1.8
    public var probeWorkInflationSevere: Double = 3.0
    /// If fewer than this fraction of expected wake-ups happened, the probe thread was starved.
    public var probeMinSampleFraction: Double = 0.5
    public var baselineMinSamples: Int = 60
    public var baselineMaxSamples: Int = 600
    /// Baseline never learns values above this cap (protects against learning a lag episode as normal).
    public var baselineLatenessCapMs: Double = 40

    // Input latency
    public var inputEnabled: Bool = true
    public var inputClock: InputClockMode = .auto
    public var inputModerateMs: Double = 80
    public var inputSevereMs: Double = 250

    // Front-app AX probe
    public var frontProbeEnabled: Bool = true
    public var frontProbeTimeoutMs: Double = 250
    public var frontProbeSlowMs: Double = 100
    public var frontProbeSkipBundleIDs: [String] = []

    // Detector
    public var lagScoreThreshold: Double = 1.0
    public var enterWindow: Int = 5
    public var enterCount: Int = 3
    /// Leave the lagging state when at most this many of the last `enterWindow` ticks were lag ticks.
    public var exitCount: Int = 1
    public var sensitivity: Sensitivity = .medium

    // Attribution
    public var attributionWindowSec: Int = 10
    public var cpuHogPercent: Double = 80
    public var cpuNotablePercent: Double = 30
    public var cpuBusyHigh: Double = 0.85
    public var diskHogBytesPerSec: Double = 50 * 1024 * 1024
    public var swapInHighBytesPerSec: Double = 5 * 1024 * 1024
    public var windowServerHighPercent: Double = 70

    // Alerts / actions
    public var alertCooldownSec: Double = 120
    public var ignoredGroups: [String] = []
    public var pauseAutoResumeMinutes: Double = 10
    public var quitGraceSec: Double = 5

    // Sampling
    public var rusageTimeUnit: RusageTimeUnit = .auto
    public var privilegedFallbackIntervalSec: Double = 3
    public var intelThermPollSec: Double = 10

    // Recording
    public var recordTicks: Bool = true
    public var tickRetentionDays: Int = 7
    public var episodePreSec: Int = 30
    public var episodePostSec: Int = 10

    public init() {}

    /// Thresholds after applying `sensitivity`.
    public var scaled: JankConfig {
        var c = self
        let s = sensitivity.thresholdScale
        c.probeLatenessFloorMs *= s
        c.probeLatenessNoBaselineMs *= s
        c.probeLatenessSevereMs *= s
        c.probeWorkInflationModerate = 1 + (probeWorkInflationModerate - 1) * s
        c.probeWorkInflationSevere = 1 + (probeWorkInflationSevere - 1) * s
        c.inputModerateMs *= s
        c.inputSevereMs *= s
        c.frontProbeSlowMs *= s
        return c
    }

    /// Decode a possibly partial JSON object, filling missing keys with defaults.
    public static func load(from data: Data) throws -> JankConfig {
        let defaultsData = try JSONEncoder().encode(JankConfig())
        guard var merged = try JSONSerialization.jsonObject(with: defaultsData) as? [String: Any] else {
            return JankConfig()
        }
        if let user = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for (k, v) in user { merged[k] = v }
        }
        let mergedData = try JSONSerialization.data(withJSONObject: merged)
        return try JSONDecoder().decode(JankConfig.self, from: mergedData)
    }

    public func encoded() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(self)
    }
}
