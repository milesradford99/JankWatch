import Foundation

public enum ActionKind: String, Codable, CaseIterable, Sendable {
    /// Darwin background priority (PRIO_DARWIN_BG): lower CPU + IO priority; on Apple Silicon moves work to E cores. Reversible.
    case background
    /// SIGSTOP, auto-resumed later or when the app is brought to front. Reversible.
    case pause
    /// Graceful quit (apps get a chance to save).
    case quit
    /// Force quit / SIGKILL.
    case forceQuit
    /// Run the knowledge base's admin command (e.g. pause Spotlight indexing).
    case adminFix

    public var isReversible: Bool { self == .background || self == .pause }

    public var label: String {
        switch self {
        case .background: return "降级"
        case .pause: return "暂停"
        case .quit: return "退出"
        case .forceQuit: return "强制退出"
        case .adminFix: return "修复"
        }
    }
}

public enum CauseKind: String, Codable, Sendable {
    case frontAppHung, memoryPressure, thermalThrottling, cpuContention, diskIO, windowServer, unknown

    public var label: String {
        switch self {
        case .frontAppHung: return "前台 App 无响应"
        case .memoryPressure: return "内存不足"
        case .thermalThrottling: return "过热降频"
        case .cpuContention: return "CPU 被后台抢占"
        case .diskIO: return "磁盘读写繁忙"
        case .windowServer: return "图形合成负载高"
        case .unknown: return "原因不明"
        }
    }
}

public struct Culprit: Codable, Equatable, Identifiable, Sendable {
    public var id: String { groupKey }
    public var groupKey: String
    public var displayName: String
    public var bundlePath: String?
    public var mainPID: Int32
    public var pids: [PIDRef]
    public var cpuPercent: Double
    public var memoryBytes: UInt64
    public var memoryGrowthBytes: Int64
    public var diskBytesPerSec: Double
    public var isFrontmost: Bool
    public var needsAdmin: Bool
    public var category: ProcessCategory
    public var description: String?
    public var advice: String?
    public var allowedActions: [ActionKind]
    public var recommended: ActionKind?
    public var adminFix: AdminFix?

    /// The action the global "recover" hotkey performs: only ever a reversible one.
    public var hotkeyAction: ActionKind? {
        if let r = recommended, r.isReversible, allowedActions.contains(r) { return r }
        // Recommended quit means memory: pausing stops growth and lets the system compress it; demoting would not help.
        if recommended == .quit, allowedActions.contains(.pause) { return .pause }
        if allowedActions.contains(.background) { return .background }
        if allowedActions.contains(.pause) { return .pause }
        return nil
    }

    /// One-line metric summary in Chinese.
    public var metricsSummary: String {
        var parts: [String] = []
        if cpuPercent >= 1 { parts.append("CPU " + Format.percent(cpuPercent)) }
        if memoryBytes > 0 {
            var m = "内存 " + Format.bytes(Double(memoryBytes))
            if memoryGrowthBytes > 50 * 1024 * 1024 { m += "↑" }
            parts.append(m)
        }
        if diskBytesPerSec >= 1024 * 1024 { parts.append("磁盘 " + Format.rate(diskBytesPerSec)) }
        return parts.joined(separator: " · ")
    }
}

public struct Diagnosis: Codable, Equatable, Sendable {
    public var cause: CauseKind
    public var secondaryCauses: [CauseKind]
    public var headline: String
    public var evidence: [String]
    public var culprits: [Culprit]

    public init(cause: CauseKind, secondaryCauses: [CauseKind], headline: String, evidence: [String], culprits: [Culprit]) {
        self.cause = cause
        self.secondaryCauses = secondaryCauses
        self.headline = headline
        self.evidence = evidence
        self.culprits = culprits
    }

    public var primaryCulprit: Culprit? { culprits.first }
}

public enum ActionPolicy {
    public static func allowed(category: ProcessCategory, isApp: Bool, cause: CauseKind) -> [ActionKind] {
        switch category {
        case .critical, .security:
            return []
        case .systemService:
            return [.background]
        case .systemDeferrable:
            return [.background, .pause]
        case .developer, .userApp:
            if cause == .frontAppHung { return [.quit, .forceQuit] }
            return [.background, .pause, .quit, .forceQuit]
        }
    }

    public static func recommended(cause: CauseKind, allowed: [ActionKind], hasAdminFix: Bool) -> ActionKind? {
        func first(_ order: [ActionKind]) -> ActionKind? { order.first { allowed.contains($0) || ($0 == .adminFix && hasAdminFix) } }
        switch cause {
        case .frontAppHung: return nil  // never auto-recommend killing what the user is working in
        case .memoryPressure: return first([.quit, .pause])
        case .cpuContention, .thermalThrottling: return first([.background, .pause, .adminFix])
        case .diskIO: return first([.background, .adminFix, .pause])
        case .windowServer, .unknown: return first([.background])
        }
    }
}

public struct AttributionContext: Sendable {
    public var frontmostPID: Int32?
    public var frontmostBundlePath: String?
    /// JankWatch's own group key (excluded from culprits).
    public var ownGroupKey: String?

    public init(frontmostPID: Int32?, frontmostBundlePath: String?, ownGroupKey: String?) {
        self.frontmostPID = frontmostPID
        self.frontmostBundlePath = frontmostBundlePath
        self.ownGroupKey = ownGroupKey
    }
}

/// Explains an episode from the recent ticks: what kind of slowdown, and which groups caused it.
public struct Attributor {
    public var config: JankConfig
    public var kb: KnowledgeBase

    public init(config: JankConfig, kb: KnowledgeBase = .builtin) {
        self.config = config
        self.kb = kb
    }

    struct Agg {
        var group: GroupSample
        var cpuSum = 0.0
        var diskSum = 0.0
        var firstMem: UInt64?
        var lastMem: UInt64 = 0
    }

    static let neverCulprit: Set<String> = ["kernel_task", "launchd", "WindowServer"]

    public func diagnose(_ ticks: [Tick], context: AttributionContext) -> Diagnosis {
        let window = Array(ticks.suffix(max(1, config.attributionWindowSec)))
        let n = Double(max(window.count, 1))

        // Aggregate groups across the window.
        var aggs: [String: Agg] = [:]
        for t in window {
            for g in t.groups {
                var a = aggs[g.key] ?? Agg(group: g)
                a.cpuSum += g.cpuPercent
                a.diskSum += g.diskBytesPerSec
                if a.firstMem == nil { a.firstMem = g.memoryBytes }
                a.lastMem = g.memoryBytes
                a.group = g  // latest pids
                aggs[g.key] = a
            }
        }
        let systems = window.compactMap(\.system)
        let avgSwapIn = Stats.mean(systems.map(\.swapInBytesPerSec)) ?? 0
        let maxPressure = systems.map(\.memoryPressure).max() ?? .normal
        let maxThermal = systems.map(\.thermal).max() ?? .nominal
        let minSpeedLimit = systems.compactMap(\.cpuSpeedLimit).min()
        let avgBusy = Stats.mean(systems.map { $0.pCoreBusy ?? $0.cpuBusy }) ?? 0
        let signals = window.compactMap(\.signals)
        let maxProbe = Stats.mean(signals.map(\.probeScore)) ?? 0
        let frontHungTicks = signals.filter { $0.frontScore >= 1.0 }.count
        let maxInput = window.map(\.input.maxMs).max() ?? 0
        let maxLateness = window.compactMap { $0.probe?.latenessP95Ms }.max() ?? 0

        func isFront(_ g: GroupSample) -> Bool {
            if let pid = context.frontmostPID, g.pids.contains(where: { $0.pid == pid }) { return true }
            if let b = context.frontmostBundlePath, g.bundlePath == b { return true }
            return false
        }
        let candidates = aggs.values.filter { a in
            a.group.key != context.ownGroupKey && !Self.neverCulprit.contains(a.group.name)
                && !config.ignoredGroups.contains(a.group.key)
        }
        func avgCPU(_ a: Agg) -> Double { a.cpuSum / n }
        func avgDisk(_ a: Agg) -> Double { a.diskSum / n }
        let windowServer = aggs.values.first { $0.group.name == "WindowServer" }
        let wsCPU = windowServer.map(avgCPU) ?? 0

        var evidence: [String] = []
        if maxInput > 0 { evidence.append("输入延迟最高 " + Format.ms(maxInput)) }
        if maxLateness > 0 { evidence.append("调度延迟 p95 最高 " + Format.ms(maxLateness)) }
        if !systems.isEmpty { evidence.append("CPU 总占用 " + Format.percent(avgBusy * 100)) }
        if maxPressure > .normal { evidence.append("内存压力：" + (maxPressure == .critical ? "严重" : "警告")) }
        if avgSwapIn > 0 { evidence.append("swap 读入 " + Format.rate(avgSwapIn)) }
        if maxThermal >= .serious { evidence.append("温控等级：" + (maxThermal == .critical ? "危急" : "严重")) }
        if let l = minSpeedLimit, l < 100 { evidence.append("CPU 限速 \(l)%") }

        // Which causes apply, in priority order.
        var causes: [CauseKind] = []
        if frontHungTicks >= 1 && maxProbe < 0.5 { causes.append(.frontAppHung) }
        if maxPressure >= .warning && avgSwapIn >= config.swapInHighBytesPerSec { causes.append(.memoryPressure) }
        if maxThermal >= .serious || (minSpeedLimit ?? 100) < 90 { causes.append(.thermalThrottling) }
        let background = candidates.filter { !isFront($0.group) }
        let topBgCPU = background.max { avgCPU($0) < avgCPU($1) }
        if avgBusy >= config.cpuBusyHigh || (topBgCPU.map(avgCPU) ?? 0) >= config.cpuHogPercent { causes.append(.cpuContention) }
        let topBgDisk = background.max { avgDisk($0) < avgDisk($1) }
        if (topBgDisk.map(avgDisk) ?? 0) >= config.diskHogBytesPerSec { causes.append(.diskIO) }
        if wsCPU >= config.windowServerHighPercent { causes.append(.windowServer) }
        if frontHungTicks >= 2 && !causes.contains(.frontAppHung) { causes.append(.frontAppHung) }
        let primary = causes.first ?? .unknown

        // Pick culprits for the primary cause.
        var chosen: [Agg] = []
        switch primary {
        case .frontAppHung:
            chosen = candidates.filter { isFront($0.group) }
        case .memoryPressure:
            let sorted = candidates.sorted { a, b in
                let fa = isFront(a.group), fb = isFront(b.group)
                if fa != fb { return !fa }  // background first
                return a.lastMem > b.lastMem
            }
            chosen = Array(sorted.prefix(3))
        case .cpuContention, .thermalThrottling, .unknown:
            let sorted = background.sorted { avgCPU($0) > avgCPU($1) }
            chosen = sorted.filter { avgCPU($0) >= config.cpuNotablePercent }.prefix(3).map { $0 }
            if chosen.isEmpty, let top = sorted.first, avgCPU(top) >= 5 { chosen = [top] }
            if chosen.isEmpty, primary != .unknown, let topAny = candidates.max(by: { avgCPU($0) < avgCPU($1) }) { chosen = [topAny] }
        case .diskIO:
            chosen = background.sorted { avgDisk($0) > avgDisk($1) }.filter { avgDisk($0) >= config.diskHogBytesPerSec / 4 }.prefix(3).map { $0 }
        case .windowServer:
            chosen = background.sorted { avgCPU($0) > avgCPU($1) }.filter { avgCPU($0) >= config.cpuNotablePercent }.prefix(2).map { $0 }
        }

        let culprits = chosen.map { a -> Culprit in
            let g = a.group
            let entry = kb.lookup(g.mainProcessName) ?? kb.lookup(group: g.name)
            let category = kb.category(processName: g.mainProcessName, path: g.mainPath, groupName: g.name)
            let allowed = ActionPolicy.allowed(category: category, isApp: g.bundlePath != nil, cause: primary)
            let growth = Int64(clamping: a.lastMem) - Int64(clamping: a.firstMem ?? a.lastMem)
            return Culprit(groupKey: g.key, displayName: g.name, bundlePath: g.bundlePath, mainPID: g.mainPID, pids: g.pids,
                           cpuPercent: avgCPU(a), memoryBytes: a.lastMem, memoryGrowthBytes: growth, diskBytesPerSec: avgDisk(a),
                           isFrontmost: isFront(g), needsAdmin: !g.ownedByCurrentUser, category: category,
                           description: entry?.description, advice: entry?.advice, allowedActions: allowed,
                           recommended: ActionPolicy.recommended(cause: primary, allowed: allowed, hasAdminFix: entry?.adminFix != nil),
                           adminFix: entry?.adminFix)
        }

        return Diagnosis(cause: primary, secondaryCauses: Array(causes.dropFirst()),
                         headline: headline(primary, culprits.first, swapIn: avgSwapIn, wsCPU: wsCPU, speedLimit: minSpeedLimit,
                                            thermal: maxThermal),
                         evidence: evidence, culprits: culprits)
    }

    func headline(_ cause: CauseKind, _ c: Culprit?, swapIn: Double, wsCPU: Double, speedLimit: Int?, thermal: ThermalLevel) -> String {
        let name = c.map { "「\($0.displayName)」" } ?? ""
        switch cause {
        case .frontAppHung:
            return "\(name.isEmpty ? "前台 App" : name)自身无响应（主线程卡住），不是后台问题"
        case .memoryPressure:
            let who = c.map { "，占用最多的是\(name)（\(Format.bytes(Double($0.memoryBytes)))）" } ?? ""
            return "内存不足，系统正在换页（swap 读入 \(Format.rate(swapIn))）" + who
        case .thermalThrottling:
            let how = speedLimit.map { "CPU 限速到 \($0)%" } ?? "温控等级\(thermal == .critical ? "危急" : "严重")"
            let who = c.map { "，主要热源\(name)（CPU \(Format.percent($0.cpuPercent))）" } ?? ""
            return "过热降频（\(how)）" + who
        case .cpuContention:
            if let c { return "后台\(name)占用 \(Format.percent(c.cpuPercent)) CPU，抢占了前台的算力" }
            return "CPU 满载，前台 App 抢不到算力"
        case .diskIO:
            if let c { return "后台\(name)正在大量读写磁盘（\(Format.rate(c.diskBytesPerSec))）" }
            return "磁盘读写繁忙"
        case .windowServer:
            return "WindowServer 负载过高（CPU \(Format.percent(wsCPU))）：可能是录屏/屏幕共享、外接显示器或大量动画窗口"
        case .unknown:
            if let c { return "检测到卡顿，最可疑的是\(name)（\(c.metricsSummary)）" }
            return "检测到卡顿，但没有找到明确的元凶"
        }
    }
}

/// Decides whether a diagnosis should pop up an alert.
public struct AlertPolicy {
    public var config: JankConfig
    private var lastAlert: [String: Double] = [:]

    public init(config: JankConfig) {
        self.config = config
    }

    public mutating func updateConfig(_ c: JankConfig) { config = c }

    public static func dedupeKey(_ d: Diagnosis) -> String {
        d.cause.rawValue + "|" + (d.primaryCulprit?.groupKey ?? "-")
    }

    public mutating func shouldAlert(_ d: Diagnosis, now: Double) -> Bool {
        if let c = d.primaryCulprit, config.ignoredGroups.contains(c.groupKey) { return false }
        let key = Self.dedupeKey(d)
        if let last = lastAlert[key], now - last < config.alertCooldownSec { return false }
        lastAlert[key] = now
        return true
    }
}
