#if os(macOS)
import AppKit
import Darwin
import Foundation
import JankWatchCore

public struct EpisodeSummary: Equatable, Identifiable, Sendable {
    public var id: String
    public var startWall: Date
    public var durationSec: Double?
    public var headline: String
    public var cause: CauseKind?
}

public struct AlertModel: Equatable, Identifiable, Sendable {
    public var id: String  // episode id
    public var episode: Episode
    public var diagnosis: Diagnosis
    public var ended: Bool
    public var isTest: Bool
    /// Last action message shown in the panel.
    public var lastMessage: String?
}

public struct EngineStatus: Equatable, Sendable {
    public var gate: GateState = .off
    public var phase: DetectorPhase = .normal
    public var lastSignals: TickSignals = .zero
    public var recentScores: [Double] = []
    public var permissions = PermissionStatus(inputMonitoring: false, accessibility: false)
    public var inputTapInstalled = false
    public var inputClock: InputClockMode?
    public var inputClockFailed = false
    public var rusageUnit: RusageTimeUnit?
    public var baselineLatencyMs: Double?
    public var baselineSamples = 0
    public var processesTotal = 0
    public var processesDenied = 0
    public var selfCPUPercent = 0.0
    public var recentEpisodes: [EpisodeSummary] = []
    public var ledger: [ActionRecord] = []
    public var config = JankConfig()
}

public protocol EngineDelegate: AnyObject {
    func engineDidUpdate(_ status: EngineStatus)
    func engineShowAlert(_ alert: AlertModel)
    func engineUpdateAlert(_ alert: AlertModel)
    func engineMessage(_ message: String)
}

/// Owns all sensors and logic. Everything runs on one serial queue at 1 Hz; process actions run on a second queue
/// because admin prompts block. Delegate callbacks are delivered on the main thread.
public final class Engine {
    public weak var delegate: EngineDelegate?
    public let store: EventStore

    private let queue = DispatchQueue(label: "JankWatch.engine", qos: .userInitiated)
    private let actionQueue = DispatchQueue(label: "JankWatch.actions", qos: .userInitiated)
    private var timer: DispatchSourceTimer?

    private var config: JankConfig
    private let kb = KnowledgeBase.builtin
    private let gate = ActivityGate()
    public let frontmost = FrontmostTracker()
    private let probe: ProbeSensor
    private let input: InputLatencySensor
    private let frontProbe: FrontAppProbe
    private var processSampler: ProcessSampler?
    private let systemSampler: SystemSampler
    private var deltas = ProcessDeltaComputer()
    private var baseline: ProbeBaseline
    private var evaluator: SignalEvaluator
    private var detector: LagDetector
    private var attributor: Attributor
    private var alertPolicy: AlertPolicy
    private var ledger: ActionLedger
    private let controller = ProcessController()
    private var ring = RingBuffer<Tick>(capacity: 300)

    private var gateState: GateState = .off
    private var probeStartedAt: Double = 0
    private var activity: NSObjectProtocol?
    private var axPermitted = false
    private var status = EngineStatus()
    private var scores: [Double] = []
    private var tickCount = 0

    private var currentAlert: AlertModel?
    private var currentDiagnosis: Diagnosis?
    private var currentAlerted = false
    private var currentAlertedAt: Date?
    private var currentActions: [String] = []
    private var pendingRecords: [(due: Double, startT: Double, record: EpisodeRecord)] = []
    private var recentEpisodes: [EpisodeSummary] = []
    private var lastSelfCPU: (t: Double, nanos: UInt64)?
    private let ownGroupKey: String
    private let currentUID = MachineInfo.currentUID

    public init(store: EventStore) {
        self.store = store
        let c = store.loadConfig()
        config = c
        probe = ProbeSensor(intervalMs: c.probeIntervalMs, workEvery: c.probeWorkEvery, workIterations: c.probeWorkIterations)
        input = InputLatencySensor(clock: c.inputClock)
        frontProbe = FrontAppProbe(timeoutMs: c.frontProbeTimeoutMs)
        systemSampler = SystemSampler(thermPollInterval: c.intelThermPollSec)
        baseline = store.loadBaseline()
        evaluator = SignalEvaluator(config: c)
        detector = LagDetector(config: c)
        attributor = Attributor(config: c)
        alertPolicy = AlertPolicy(config: c)
        ledger = store.loadLedger()
        let bundle = Bundle.main.bundlePath
        ownGroupKey = bundle.hasSuffix(".app") ? "app:" + bundle : "proc:" + ProcessInfo.processInfo.processName
    }

    public var dataDirectory: URL { store.root }

    // MARK: Lifecycle

    /// Call on the main thread.
    public func start() {
        gate.start()
        frontmost.onActivate = { [weak self] info in
            self?.queue.async { self?.handleActivation(info) }
        }
        frontmost.start()
        if config.inputEnabled && InputLatencySensor.hasPermission() { input.install() }
        queue.async { [weak self] in
            guard let self else { return }
            self.processSampler = ProcessSampler(rusageUnit: self.config.rusageTimeUnit, fallbackInterval: self.config.privilegedFallbackIntervalSec)
            self.resumeLeftoverPauses()
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now() + 1, repeating: 1.0, leeway: .milliseconds(20))
            t.setEventHandler { [weak self] in self?.tick() }
            self.timer = t
            t.resume()
        }
    }

    /// Call when the app quits: resumes anything we paused.
    public func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
            probe.stop()
            input.setEnabled(false)
            store.saveBaseline(baseline)
        }
        let pauses = queue.sync { ledger.activePauses }
        for r in pauses {
            _ = actionQueue.sync { controller.resume(r.pids, name: r.displayName) }
            queue.sync { ledger.markReverted(r.id, at: Date()) }
        }
        queue.sync { store.saveLedger(ledger) }
    }

    private func resumeLeftoverPauses() {
        let pauses = ledger.activePauses
        guard !pauses.isEmpty else { return }
        for r in pauses {
            let alive = r.pids.filter(ProcessOps.isAlive)
            if !alive.isEmpty { _ = actionQueue.sync { controller.resume(alive, name: r.displayName) } }
            ledger.markReverted(r.id, at: Date())
        }
        store.saveLedger(ledger)
        message("已恢复上次暂停的 \(pauses.count) 项")
    }

    private func transition(to state: GateState, at t: Double) {
        if state == .active {
            probe.start()
            probeStartedAt = t
            input.setEnabled(true)
            deltas.reset()
            systemSampler.reset()
            if activity == nil {
                // Keep timers precise (App Nap would distort the probe) without preventing idle sleep.
                activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
                                                                 reason: "JankWatch responsiveness monitoring")
            }
        } else {
            probe.stop()
            input.setEnabled(false)
            if let a = activity {
                ProcessInfo.processInfo.endActivity(a)
                activity = nil
            }
        }
    }

    // MARK: Tick

    private func tick() {
        tickCount += 1
        let t = MachClock.uptimeSeconds()
        let wall = Date()
        let (state, idle) = gate.evaluate(idleAfter: config.idleAfterSec)
        if state != gateState {
            transition(to: state, at: t)
            gateState = state
        }
        if tickCount % 10 == 1 { refreshPermissions() }

        var tick = Tick(t: t, wall: wall, gate: state, idleSeconds: idle, userActive: idle < config.userActiveWindowSec)
        if state == .active {
            let scaled = config.scaled
            let (lat, work) = probe.drain()
            // Skip the first partial second after the probe starts (would look like starvation).
            if t - probeStartedAt >= 1.5 {
                tick.probe = ProbeWindowStats.from(latenessMs: lat, workMs: work, expected: probe.expectedPerSecond)
            }
            tick.input = InputWindowStats.from(input.drain(), moderateMs: scaled.inputModerateMs, severeMs: scaled.inputSevereMs)
            tick.front = sampleFront()
            if let ps = processSampler {
                let samples = deltas.compute(ps.sample(), nowWall: wall.timeIntervalSince1970)
                tick.groups = ProcessAggregator.aggregate(samples, kb: kb, currentUID: currentUID)
                status.processesTotal = ps.lastStats.total
                status.processesDenied = ps.lastStats.rusageDenied
            }
            tick.system = systemSampler.sample()
        } else {
            _ = probe.drain()
            _ = input.drain()
        }

        let sig = evaluator.evaluate(tick, baseline: baseline)
        tick.signals = sig
        if state == .active, tick.userActive, sig.total == 0, let p = tick.probe {
            baseline.observeCalm(p, config: config)
        }
        ring.append(tick)
        scores.append(state == .active ? sig.total : 0)
        if scores.count > 120 { scores.removeFirst(scores.count - 120) }
        if config.recordTicks && state != .off { store.appendTick(tick.compact()) }

        for ev in detector.process(tick, sig) { handle(ev, now: t) }
        flushPendingRecords(now: t)
        revertDue(now: wall)
        updateSelfCPU(t)

        if tickCount % 300 == 0 { store.saveBaseline(baseline) }
        if tickCount % 3600 == 10 {
            store.pruneTicks(retentionDays: config.tickRetentionDays)
            ledger.prune(now: wall)
            store.saveLedger(ledger)
        }
        publishStatus(sig)
    }

    private func refreshPermissions() {
        let p = PermissionStatus.current()
        axPermitted = p.accessibility
        status.permissions = p
        if config.inputEnabled && p.inputMonitoring && !input.isInstalled {
            input.install()
            input.setEnabled(gateState == .active)
        }
        status.inputTapInstalled = input.isInstalled
    }

    private func sampleFront() -> FrontAppStats? {
        guard let info = frontmost.current else { return nil }
        let results = frontProbe.drain().filter { $0.pid == info.pid }
        var stats = FrontAppStats(pid: info.pid, bundleID: info.bundleID, name: info.name, bundlePath: info.bundlePath,
                                  maxRoundTripMs: results.map(\.roundTripMs).max(), timedOut: results.contains { $0.timedOut })
        let skip = info.pid == getpid() || (info.bundleID.map { config.frontProbeSkipBundleIDs.contains($0) } ?? false)
        if config.frontProbeEnabled && axPermitted && !skip {
            frontProbe.probe(pid: info.pid)
        } else {
            stats.maxRoundTripMs = nil
            stats.timedOut = false
        }
        return stats
    }

    private func updateSelfCPU(_ t: Double) {
        let n = MachClock.processCPUNanos()
        if let last = lastSelfCPU, t > last.t {
            let pct = Double(n &- last.nanos) / 1e9 / (t - last.t) * 100
            status.selfCPUPercent = status.selfCPUPercent * 0.9 + pct * 0.1
        }
        lastSelfCPU = (t, n)
    }

    private func publishStatus(_ sig: TickSignals) {
        status.gate = gateState
        status.phase = detector.phase
        status.lastSignals = sig
        status.recentScores = scores
        status.inputClock = input.clockDecision
        status.inputClockFailed = input.clockCalibrationFailed
        status.rusageUnit = processSampler?.rusageUnit
        status.baselineLatencyMs = baseline.latenessP95Ms(minSamples: config.baselineMinSamples)
        status.baselineSamples = baseline.latenessP95.count
        status.recentEpisodes = recentEpisodes
        status.ledger = Array(ledger.records.suffix(20).reversed())
        status.config = config
        let s = status
        DispatchQueue.main.async { [weak self] in self?.delegate?.engineDidUpdate(s) }
    }

    private func message(_ m: String) {
        DispatchQueue.main.async { [weak self] in self?.delegate?.engineMessage(m) }
    }

    // MARK: Episodes

    private var attributionContext: AttributionContext {
        let f = frontmost.current
        return AttributionContext(frontmostPID: f?.pid, frontmostBundlePath: f?.bundlePath, ownGroupKey: ownGroupKey)
    }

    private func handle(_ ev: DetectorEvent, now: Double) {
        switch ev {
        case .started(let ep):
            let d = attributor.diagnose(ring.elements, context: attributionContext)
            currentDiagnosis = d
            currentActions = []
            currentAlerted = false
            currentAlertedAt = nil
            maybeAlert(ep, d, now: now)
        case .updated(let ep):
            guard ep.lagTicks % 3 == 0 else { return }
            let d = attributor.diagnose(ring.elements, context: attributionContext)
            currentDiagnosis = d
            if var a = currentAlert, a.id == ep.id {
                if currentActions.isEmpty {  // do not reshuffle the panel under the user's cursor after they acted
                    a.episode = ep
                    a.diagnosis = d
                    currentAlert = a
                    let copy = a
                    DispatchQueue.main.async { [weak self] in self?.delegate?.engineUpdateAlert(copy) }
                }
            } else {
                maybeAlert(ep, d, now: now)
            }
        case .ended(let ep):
            let record = EpisodeRecord(episode: ep, diagnosis: currentDiagnosis, alerted: currentAlerted, alertedAt: currentAlertedAt,
                                       actionIDs: currentActions, meta: runMeta, ticks: [])
            pendingRecords.append((now + Double(config.episodePostSec), ep.startT, record))
            recentEpisodes.insert(EpisodeSummary(id: ep.id, startWall: ep.startWall, durationSec: ep.durationSec,
                                                 headline: currentDiagnosis?.headline ?? "卡顿", cause: currentDiagnosis?.cause), at: 0)
            if recentEpisodes.count > 10 { recentEpisodes.removeLast(recentEpisodes.count - 10) }
            if var a = currentAlert, a.id == ep.id {
                a.ended = true
                a.episode = ep
                currentAlert = a
                let copy = a
                DispatchQueue.main.async { [weak self] in self?.delegate?.engineUpdateAlert(copy) }
            }
            currentDiagnosis = nil
        }
    }

    private func maybeAlert(_ ep: Episode, _ d: Diagnosis, now: Double) {
        guard alertPolicy.shouldAlert(d, now: now) else { return }
        let a = AlertModel(id: ep.id, episode: ep, diagnosis: d, ended: false, isTest: false, lastMessage: nil)
        currentAlert = a
        currentAlerted = true
        currentAlertedAt = Date()
        DispatchQueue.main.async { [weak self] in self?.delegate?.engineShowAlert(a) }
    }

    private var runMeta: RunMeta {
        MachineInfo.runMeta(inputClock: input.clockDecision, rusageUnit: processSampler?.rusageUnit)
    }

    private func flushPendingRecords(now: Double) {
        let due = pendingRecords.filter { $0.due <= now || gateState == .off }
        guard !due.isEmpty else { return }
        pendingRecords.removeAll { $0.due <= now || gateState == .off }
        for p in due {
            var r = p.record
            let from = p.startT - Double(config.episodePreSec)
            r.ticks = ring.elements.filter { $0.t >= from }
            store.writeEpisode(r)
        }
    }

    // MARK: User commands (any thread)

    /// "I just felt lag" hotkey.
    public func mark() {
        queue.async { [self] in
            let m = MarkRecord(wall: Date(), t: MachClock.uptimeSeconds(), phase: detector.phase)
            store.appendMark(m)
            store.writeMarkSnapshot(m, ticks: ring.last(config.episodePreSec), meta: runMeta)
            message(detector.phase == .lagging ? "已记录（JankWatch 也检测到了这次卡顿）" : "已记录这次卡顿，用于改进检测")
        }
    }

    public func feedbackNotLag(alertID: String) {
        queue.async { [self] in
            store.appendFeedback(FeedbackRecord(wall: Date(), episodeID: alertID, kind: .notLag, detail: nil))
            message("感谢反馈，已记录为误报")
        }
    }

    public func dismissed(alertID: String) {
        queue.async { [self] in
            store.appendFeedback(FeedbackRecord(wall: Date(), episodeID: alertID, kind: .dismissed, detail: nil))
            if currentAlert?.id == alertID { currentAlert = nil }
        }
    }

    public func ignore(groupKey: String, name: String, alertID: String?) {
        queue.async { [self] in
            if !config.ignoredGroups.contains(groupKey) { config.ignoredGroups.append(groupKey) }
            applyConfig(config)
            store.appendFeedback(FeedbackRecord(wall: Date(), episodeID: alertID, kind: .ignoredGroup, detail: groupKey))
            message("以后不再把「\(name)」当作元凶")
        }
    }

    public func unignore(groupKey: String) {
        queue.async { [self] in
            config.ignoredGroups.removeAll { $0 == groupKey }
            applyConfig(config)
        }
    }

    public func updateConfig(_ c: JankConfig) {
        queue.async { [self] in applyConfig(c) }
    }

    public func reloadConfig() {
        queue.async { [self] in applyConfig(store.loadConfig()) }
    }

    private func applyConfig(_ c: JankConfig) {
        config = c
        store.saveConfig(c)
        evaluator = SignalEvaluator(config: c)
        detector = LagDetector(config: c)
        attributor = Attributor(config: c)
        alertPolicy.updateConfig(c)
        frontProbe.timeoutMs = c.frontProbeTimeoutMs
    }

    /// Show an alert built from the current data, for checking the panel UI (docs/VALIDATION.md V7).
    public func showTestAlert() {
        queue.async { [self] in
            var ep = Episode(id: "test-" + UUID().uuidString, startT: MachClock.uptimeSeconds(), startWall: Date())
            ep.maxInputLatencyMs = 123
            var d = attributor.diagnose(ring.elements, context: attributionContext)
            if d.culprits.isEmpty {
                // Use the busiest background group so action buttons can be exercised.
                let all = ring.last(5)
                let candidateTicks = all.map { t -> Tick in
                    var t = t
                    t.system?.cpuBusy = 1
                    return t
                }
                d = attributor.diagnose(candidateTicks, context: attributionContext)
            }
            d.headline = "【测试弹窗】" + d.headline
            let a = AlertModel(id: ep.id, episode: ep, diagnosis: d, ended: false, isTest: true, lastMessage: nil)
            currentAlert = a
            DispatchQueue.main.async { [weak self] in self?.delegate?.engineShowAlert(a) }
        }
    }

    /// Global recover hotkey: perform the current alert's safe (reversible) action.
    public func recoverHotkey() {
        queue.async { [self] in
            guard let a = currentAlert, let c = a.diagnosis.primaryCulprit, let k = c.hotkeyAction else {
                message("当前没有可以一键恢复的卡顿")
                return
            }
            performOnQueue(k, culprit: c, alertID: a.id)
        }
    }

    public func perform(_ kind: ActionKind, culprit: Culprit, alertID: String?) {
        queue.async { [self] in performOnQueue(kind, culprit: culprit, alertID: alertID) }
    }

    private func performOnQueue(_ kind: ActionKind, culprit c: Culprit, alertID: String?) {
        let cfg = config
        actionQueue.async { [weak self] in
            guard let self else { return }
            let finish: (ProcessController.Outcome) -> Void = { outcome in
                self.queue.async { self.recordAction(kind, culprit: c, outcome: outcome, alertID: alertID, config: cfg) }
            }
            switch kind {
            case .background:
                finish(self.controller.background(c.pids, name: c.displayName, on: true))
            case .pause:
                finish(self.controller.pause(c.pids, name: c.displayName))
            case .quit, .forceQuit:
                self.controller.quit(mainPID: c.mainPID, refs: c.pids, name: c.displayName, force: kind == .forceQuit,
                                     grace: cfg.quitGraceSec, escalate: false, completion: finish)
            case .adminFix:
                guard let fix = c.adminFix else { return }
                finish(self.controller.runAdminFix(fix.command, title: fix.title))
            }
        }
    }

    private func recordAction(_ kind: ActionKind, culprit c: Culprit, outcome: ProcessController.Outcome, alertID: String?, config cfg: JankConfig) {
        if outcome.ok {
            let r = ActionRecord(kind: kind, groupKey: c.groupKey, displayName: c.displayName,
                                 pids: outcome.affected.isEmpty ? c.pids : outcome.affected, appliedAt: Date(),
                                 autoRevertAt: kind == .pause ? Date().addingTimeInterval(cfg.pauseAutoResumeMinutes * 60) : nil,
                                 viaAdmin: outcome.viaAdmin, undoCommand: kind == .adminFix ? c.adminFix?.undoCommand : nil,
                                 note: kind == .adminFix ? c.adminFix?.title : nil)
            ledger.add(r)
            // Quitting a paused app ends the pause.
            if kind == .quit || kind == .forceQuit {
                for p in ledger.activePauses where p.groupKey == c.groupKey { ledger.markReverted(p.id, at: Date()) }
            }
            store.saveLedger(ledger)
            if alertID == currentAlert?.id { currentActions.append(r.id) }
            store.appendFeedback(FeedbackRecord(wall: Date(), episodeID: alertID, kind: .actionTaken, detail: "\(kind.rawValue):\(c.groupKey)"))
        }
        var msg = outcome.message
        if outcome.ok && kind == .pause { msg += "，\(Int(cfg.pauseAutoResumeMinutes)) 分钟后或切到它时自动恢复" }
        if var a = currentAlert, a.id == alertID {
            a.lastMessage = msg
            currentAlert = a
            let copy = a
            DispatchQueue.main.async { [weak self] in self?.delegate?.engineUpdateAlert(copy) }
        }
        message(msg)
    }

    public func revert(recordID: String) {
        queue.async { [self] in
            guard let r = ledger.record(recordID), r.canRevert else { return }
            revertOnQueue(r, reason: nil)
        }
    }

    private func revertOnQueue(_ r: ActionRecord, reason: String?) {
        ledger.markReverted(r.id, at: Date())  // mark first so a slow admin prompt cannot trigger a second revert
        store.saveLedger(ledger)
        actionQueue.async { [weak self] in
            guard let self else { return }
            let outcome: ProcessController.Outcome
            switch r.kind {
            case .pause: outcome = self.controller.resume(r.pids, name: r.displayName)
            case .background: outcome = self.controller.background(r.pids, name: r.displayName, on: false)
            case .adminFix:
                guard let undo = r.undoCommand else { return }
                outcome = self.controller.runAdminFix(undo, title: "撤销：\(r.note ?? r.displayName)")
            default: return
            }
            self.message((reason.map { $0 + "：" } ?? "") + outcome.message)
        }
    }

    private func revertDue(now: Date) {
        for r in ledger.due(now: now) { revertOnQueue(r, reason: "自动恢复") }
    }

    private func handleActivation(_ info: FrontmostTracker.Info) {
        for r in ledger.activePauses(containing: info.pid) { revertOnQueue(r, reason: "你切换到了「\(r.displayName)」，已自动恢复") }
    }
}
#endif
