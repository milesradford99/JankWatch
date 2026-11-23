import Foundation

/// Rolling "what does calm look like on this Mac" for the probe. Learned only from calm, user-active ticks.
public struct ProbeBaseline: Codable, Equatable, Sendable {
    public var latenessP95: [Double] = []
    public var workP50: [Double] = []

    public init() {}

    public func latenessP95Ms(minSamples: Int) -> Double? {
        latenessP95.count >= minSamples ? Stats.median(latenessP95) : nil
    }

    public func workP50Ms(minSamples: Int) -> Double? {
        workP50.count >= minSamples ? Stats.median(workP50) : nil
    }

    public mutating func observeCalm(_ s: ProbeWindowStats, config: JankConfig) {
        guard s.samples > 0 else { return }
        if s.latenessP95Ms <= config.baselineLatenessCapMs {
            latenessP95.append(s.latenessP95Ms)
            if latenessP95.count > config.baselineMaxSamples { latenessP95.removeFirst(latenessP95.count - config.baselineMaxSamples) }
        }
        if let w = s.workP50Ms, w > 0 {
            workP50.append(w)
            if workP50.count > config.baselineMaxSamples { workP50.removeFirst(workP50.count - config.baselineMaxSamples) }
        }
    }
}

/// Per-tick symptom scores. Each signal scores 0 (fine), 0.5 (moderate) or up to 1.0 (severe).
/// A tick is a "lag tick" when the sum reaches `lagScoreThreshold` (default 1.0): two moderate signals, or one severe.
public struct TickSignals: Codable, Equatable, Sendable {
    public var probeScore: Double
    public var inputScore: Double
    public var frontScore: Double
    public var total: Double
    public var isLagTick: Bool
    /// Short machine-readable reasons, e.g. "probe.lateness", "input.severe".
    public var reasons: [String]

    public init(probeScore: Double, inputScore: Double, frontScore: Double, total: Double, isLagTick: Bool, reasons: [String]) {
        self.probeScore = probeScore
        self.inputScore = inputScore
        self.frontScore = frontScore
        self.total = total
        self.isLagTick = isLagTick
        self.reasons = reasons
    }

    public static let zero = TickSignals(probeScore: 0, inputScore: 0, frontScore: 0, total: 0, isLagTick: false, reasons: [])
}

public struct SignalEvaluator {
    public var config: JankConfig  // already scaled

    public init(config: JankConfig) {
        self.config = config.scaled
    }

    /// Current probe-lateness threshold given the learned baseline.
    public func latenessThresholdMs(baseline: ProbeBaseline) -> Double {
        if let b = baseline.latenessP95Ms(minSamples: config.baselineMinSamples) {
            return max(config.probeLatenessFloorMs, b * config.probeLatenessBaselineMultiplier)
        }
        return config.probeLatenessNoBaselineMs
    }

    public func latenessSevereMs(baseline: ProbeBaseline) -> Double {
        if let b = baseline.latenessP95Ms(minSamples: config.baselineMinSamples) {
            return max(config.probeLatenessSevereMs, b * config.probeLatenessSevereBaselineMultiplier)
        }
        return config.probeLatenessSevereMs
    }

    /// Whether this tick may be used to learn the probe baseline: the user is active and the *other* signals
    /// (input, front app) look fine. The probe's own score is deliberately not used, so a machine whose calm state
    /// is noisier than the defaults can still learn its baseline instead of alerting forever.
    ///
    /// During a lag episode we normally stop learning, except when the user is producing input and that input is
    /// delivered promptly: then the direct measurement contradicts the probe, and the probe's idea of "normal" is
    /// what needs to move (otherwise a machine with a noisy probe would stay in the lagging state forever).
    public static func isBaselineCandidate(_ tick: Tick, _ s: TickSignals, phase: DetectorPhase) -> Bool {
        guard tick.gate == .active, tick.userActive, tick.probe != nil, s.inputScore == 0, s.frontScore == 0 else { return false }
        if phase != .lagging { return true }
        return tick.input.count >= 2
    }

    public func evaluate(_ tick: Tick, baseline: ProbeBaseline) -> TickSignals {
        var reasons: [String] = []

        // Probe
        var probeScore = 0.0
        if let p = tick.probe, p.expected > 0 {
            if Double(p.samples) < Double(p.expected) * config.probeMinSampleFraction {
                probeScore = 1.0
                reasons.append("probe.starved")
            } else {
                let threshold = latenessThresholdMs(baseline: baseline)
                if p.latenessP95Ms >= latenessSevereMs(baseline: baseline) {
                    probeScore = 1.0
                    reasons.append("probe.lateness.severe")
                } else if p.latenessP95Ms >= threshold {
                    probeScore = 0.5
                    reasons.append("probe.lateness")
                }
                if let w = p.workP50Ms, let bw = baseline.workP50Ms(minSamples: config.baselineMinSamples), bw > 0 {
                    let inflation = w / bw
                    if inflation >= config.probeWorkInflationSevere {
                        probeScore = max(probeScore, 1.0)
                        reasons.append("probe.work.severe")
                    } else if inflation >= config.probeWorkInflationModerate {
                        probeScore = max(probeScore, 0.5)
                        reasons.append("probe.work")
                    }
                }
            }
        }

        // Input
        var inputScore = 0.0
        let i = tick.input
        if i.overSevere > 0 {
            inputScore = 1.0
            reasons.append("input.severe")
        } else if i.overModerate >= 2 {
            inputScore = 0.75
            reasons.append("input.moderate")
        } else if i.overModerate == 1 {
            inputScore = 0.5
            reasons.append("input.moderate")
        }

        // Front app
        var frontScore = 0.0
        if let f = tick.front, let rt = f.maxRoundTripMs {
            if f.timedOut || rt >= config.frontProbeTimeoutMs {
                frontScore = 1.0
                reasons.append("front.hung")
            } else if rt >= config.frontProbeSlowMs {
                frontScore = 0.5
                reasons.append("front.slow")
            }
        }

        let total = probeScore + inputScore + frontScore
        let eligible = tick.gate == .active && tick.userActive
        return TickSignals(
            probeScore: probeScore,
            inputScore: inputScore,
            frontScore: frontScore,
            total: total,
            isLagTick: eligible && total >= config.lagScoreThreshold,
            reasons: reasons
        )
    }
}
