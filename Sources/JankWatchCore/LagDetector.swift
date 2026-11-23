import Foundation

public enum DetectorPhase: String, Codable, Sendable {
    case normal, suspect, lagging
}

/// One continuous period of perceived lag.
public struct Episode: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var startT: Double
    public var startWall: Date
    public var endT: Double?
    public var endWall: Date?
    public var peakScore: Double
    public var lagTicks: Int
    public var maxInputLatencyMs: Double
    public var maxProbeLatenessMs: Double
    public var frontHungTicks: Int

    public init(id: String = UUID().uuidString, startT: Double, startWall: Date) {
        self.id = id
        self.startT = startT
        self.startWall = startWall
        self.peakScore = 0
        self.lagTicks = 0
        self.maxInputLatencyMs = 0
        self.maxProbeLatenessMs = 0
        self.frontHungTicks = 0
    }

    public var durationSec: Double? { endT.map { $0 - startT } }

    mutating func absorb(_ tick: Tick, _ s: TickSignals) {
        peakScore = max(peakScore, s.total)
        if s.isLagTick { lagTicks += 1 }
        maxInputLatencyMs = max(maxInputLatencyMs, tick.input.maxMs)
        if let p = tick.probe { maxProbeLatenessMs = max(maxProbeLatenessMs, p.latenessMaxMs) }
        if s.frontScore >= 1.0 { frontHungTicks += 1 }
    }
}

public enum DetectorEvent: Equatable, Sendable {
    case started(Episode)
    case updated(Episode)
    case ended(Episode)
}

/// Hysteresis state machine: enter "lagging" when ≥ enterCount of the last enterWindow ticks are lag ticks,
/// leave when ≤ exitCount are. Gate off / user inactive ends any episode.
public struct LagDetector {
    public private(set) var phase: DetectorPhase = .normal
    public private(set) var current: Episode?
    private var window: [Bool] = []
    private var recentTicks: [(Tick, TickSignals)] = []
    private let config: JankConfig

    public init(config: JankConfig) {
        self.config = config
    }

    /// End the current episode now (e.g. the app is quitting). Returns the finished episode, if any.
    public mutating func forceEnd(t: Double, wall: Date) -> Episode? {
        guard var ep = current else { return nil }
        ep.endT = t
        ep.endWall = wall
        current = nil
        phase = .normal
        window.removeAll()
        recentTicks.removeAll()
        return ep
    }

    public mutating func process(_ tick: Tick, _ s: TickSignals) -> [DetectorEvent] {
        var events: [DetectorEvent] = []

        guard tick.gate == .active else {
            if var ep = current {
                ep.endT = tick.t
                ep.endWall = tick.wall
                events.append(.ended(ep))
            }
            current = nil
            phase = .normal
            window.removeAll()
            recentTicks.removeAll()
            return events
        }

        window.append(s.isLagTick)
        if window.count > config.enterWindow { window.removeFirst(window.count - config.enterWindow) }
        recentTicks.append((tick, s))
        if recentTicks.count > config.enterWindow { recentTicks.removeFirst(recentTicks.count - config.enterWindow) }
        let lagCount = window.filter { $0 }.count

        if var ep = current {
            ep.absorb(tick, s)
            if lagCount <= config.exitCount {
                ep.endT = tick.t
                ep.endWall = tick.wall
                events.append(.ended(ep))
                current = nil
                phase = lagCount > 0 ? .suspect : .normal
            } else {
                current = ep
                events.append(.updated(ep))
            }
        } else if lagCount >= config.enterCount {
            // Start the episode at the first lag tick in the window.
            let first = recentTicks.first { $0.1.isLagTick } ?? (tick, s)
            var ep = Episode(startT: first.0.t, startWall: first.0.wall)
            for (t, sig) in recentTicks where t.t >= first.0.t { ep.absorb(t, sig) }
            current = ep
            phase = .lagging
            events.append(.started(ep))
        } else {
            phase = lagCount > 0 ? .suspect : .normal
        }
        return events
    }
}
