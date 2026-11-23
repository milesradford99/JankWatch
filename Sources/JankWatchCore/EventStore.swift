import Foundation

public struct RunMeta: Codable, Equatable, Sendable {
    public var appVersion: String
    public var arch: String
    public var osVersion: String
    public var timebase: TimeBase
    public var inputClock: InputClockMode?
    public var rusageUnit: RusageTimeUnit?

    public init(appVersion: String, arch: String, osVersion: String, timebase: TimeBase, inputClock: InputClockMode?, rusageUnit: RusageTimeUnit?) {
        self.appVersion = appVersion
        self.arch = arch
        self.osVersion = osVersion
        self.timebase = timebase
        self.inputClock = inputClock
        self.rusageUnit = rusageUnit
    }
}

/// Everything about one episode, written when it ends (+ post-roll).
public struct EpisodeRecord: Codable, Equatable, Sendable {
    public var version: Int = 1
    public var episode: Episode
    public var diagnosis: Diagnosis?
    public var alerted: Bool
    public var alertedAt: Date?
    public var actionIDs: [String]
    public var meta: RunMeta
    public var ticks: [Tick]

    public init(episode: Episode, diagnosis: Diagnosis?, alerted: Bool, alertedAt: Date?, actionIDs: [String], meta: RunMeta, ticks: [Tick]) {
        self.episode = episode
        self.diagnosis = diagnosis
        self.alerted = alerted
        self.alertedAt = alertedAt
        self.actionIDs = actionIDs
        self.meta = meta
        self.ticks = ticks
    }
}

/// The user pressed the "I just felt lag" hotkey.
public struct MarkRecord: Codable, Equatable, Sendable {
    public var wall: Date
    public var t: Double
    public var phase: DetectorPhase
    public init(wall: Date, t: Double, phase: DetectorPhase) {
        self.wall = wall
        self.t = t
        self.phase = phase
    }
}

public enum FeedbackKind: String, Codable, Sendable {
    case notLag, ignoredGroup, actionTaken, dismissed
}

public struct FeedbackRecord: Codable, Equatable, Sendable {
    public var wall: Date
    public var episodeID: String?
    public var kind: FeedbackKind
    public var detail: String?
    public init(wall: Date, episodeID: String?, kind: FeedbackKind, detail: String?) {
        self.wall = wall
        self.episodeID = episodeID
        self.kind = kind
        self.detail = detail
    }
}

/// Local persistence under ~/Library/Application Support/JankWatch (or any root, for tests and evaluation).
/// Not thread-safe: use from one queue.
public final class EventStore {
    public let root: URL
    private var tickHandle: FileHandle?
    private var tickDay: String?
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let dayFormatter: DateFormatter

    public init(root: URL) {
        self.root = root
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.dateFormat = "yyyy-MM-dd"
        try? FileManager.default.createDirectory(at: episodesDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: ticksDir, withIntermediateDirectories: true)
    }

    deinit { try? tickHandle?.close() }

    public static func defaultRoot() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("JankWatch", isDirectory: true)
    }

    public var episodesDir: URL { root.appendingPathComponent("episodes", isDirectory: true) }
    public var ticksDir: URL { root.appendingPathComponent("ticks", isDirectory: true) }
    public var configURL: URL { root.appendingPathComponent("config.json") }
    var baselineURL: URL { root.appendingPathComponent("baseline.json") }
    var ledgerURL: URL { root.appendingPathComponent("actions.json") }
    var marksURL: URL { root.appendingPathComponent("marks.jsonl") }
    var feedbackURL: URL { root.appendingPathComponent("feedback.jsonl") }

    // MARK: Config / state

    public func loadConfig() -> JankConfig {
        if let data = try? Data(contentsOf: configURL), let c = try? JankConfig.load(from: data) { return c }
        let c = JankConfig()
        saveConfig(c)
        return c
    }

    public func saveConfig(_ c: JankConfig) {
        if let data = try? c.encoded() { try? data.write(to: configURL, options: .atomic) }
    }

    public func loadBaseline() -> ProbeBaseline {
        (try? Data(contentsOf: baselineURL)).flatMap { try? decoder.decode(ProbeBaseline.self, from: $0) } ?? ProbeBaseline()
    }

    public func saveBaseline(_ b: ProbeBaseline) {
        if let d = try? encoder.encode(b) { try? d.write(to: baselineURL, options: .atomic) }
    }

    public func loadLedger() -> ActionLedger {
        (try? Data(contentsOf: ledgerURL)).flatMap { try? decoder.decode(ActionLedger.self, from: $0) } ?? ActionLedger()
    }

    public func saveLedger(_ l: ActionLedger) {
        if let d = try? encoder.encode(l) { try? d.write(to: ledgerURL, options: .atomic) }
    }

    // MARK: Records

    @discardableResult
    public func writeEpisode(_ r: EpisodeRecord) -> URL? {
        let stamp = ISO8601DateFormatter().string(from: r.episode.startWall).replacingOccurrences(of: ":", with: "-")
        let url = episodesDir.appendingPathComponent("\(stamp)_\(r.episode.id.prefix(8)).json")
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(r) else { return nil }
        try? data.write(to: url, options: .atomic)
        return url
    }

    private func appendLine<T: Encodable>(_ value: T, to url: URL) {
        guard var data = try? encoder.encode(value) else { return }
        data.append(0x0A)
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }

    public func appendMark(_ m: MarkRecord) { appendLine(m, to: marksURL) }

    public var markSnapshotsDir: URL { root.appendingPathComponent("marks", isDirectory: true) }

    /// Save the ticks around a user mark, so missed lags can be analysed later.
    public func writeMarkSnapshot(_ m: MarkRecord, ticks: [Tick], meta: RunMeta) {
        struct Snapshot: Codable { var mark: MarkRecord; var meta: RunMeta; var ticks: [Tick] }
        try? FileManager.default.createDirectory(at: markSnapshotsDir, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: m.wall).replacingOccurrences(of: ":", with: "-")
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(Snapshot(mark: m, meta: meta, ticks: ticks)) {
            try? data.write(to: markSnapshotsDir.appendingPathComponent("\(stamp).json"), options: .atomic)
        }
    }
    public func appendFeedback(_ f: FeedbackRecord) { appendLine(f, to: feedbackURL) }

    /// Append to ticks/YYYY-MM-DD.jsonl (local date).
    public func appendTick(_ t: Tick) {
        let day = dayFormatter.string(from: t.wall)
        if day != tickDay {
            try? tickHandle?.close()
            tickHandle = nil
            tickDay = day
            let url = ticksDir.appendingPathComponent("\(day).jsonl")
            if !FileManager.default.fileExists(atPath: url.path) { _ = FileManager.default.createFile(atPath: url.path, contents: nil) }
            tickHandle = try? FileHandle(forWritingTo: url)
            _ = try? tickHandle?.seekToEnd()
        }
        guard let h = tickHandle, var data = try? encoder.encode(t) else { return }
        data.append(0x0A)
        try? h.write(contentsOf: data)
    }

    public func pruneTicks(retentionDays: Int, now: Date = Date()) {
        guard let files = try? FileManager.default.contentsOfDirectory(at: ticksDir, includingPropertiesForKeys: nil) else { return }
        let cutoff = now.addingTimeInterval(-Double(retentionDays) * 86400)
        for f in files where f.pathExtension == "jsonl" {
            let name = f.deletingPathExtension().lastPathComponent
            if let d = dayFormatter.date(from: name), d < cutoff { try? FileManager.default.removeItem(at: f) }
        }
    }

    // MARK: Reading (evaluation)

    public func loadEpisodes() -> [EpisodeRecord] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: episodesDir, includingPropertiesForKeys: nil) else { return [] }
        return files.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { (try? Data(contentsOf: $0)).flatMap { try? decoder.decode(EpisodeRecord.self, from: $0) } }
    }

    private func loadLines<T: Decodable>(_ url: URL, as: T.Type) -> [T] {
        guard let s = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return s.split(whereSeparator: \.isNewline).compactMap { try? decoder.decode(T.self, from: Data($0.utf8)) }
    }

    public func loadMarks() -> [MarkRecord] { loadLines(marksURL, as: MarkRecord.self) }
    public func loadFeedback() -> [FeedbackRecord] { loadLines(feedbackURL, as: FeedbackRecord.self) }

    /// Number of logged ticks in the active gate state (≈ active seconds).
    public func countActiveTicks() -> Int {
        guard let files = try? FileManager.default.contentsOfDirectory(at: ticksDir, includingPropertiesForKeys: nil) else { return 0 }
        var n = 0
        for f in files where f.pathExtension == "jsonl" {
            guard let s = try? String(contentsOf: f, encoding: .utf8) else { continue }
            for line in s.split(whereSeparator: \.isNewline) where line.contains("\"gate\":\"active\"") { n += 1 }
        }
        return n
    }
}

// MARK: - Evaluation

public struct EvaluationReport: Codable, Equatable, Sendable {
    public var marks: Int
    public var episodes: Int
    public var alertedEpisodes: Int
    public var matchedMarks: Int
    public var recall: Double?
    public var episodesConfirmedByMark: Int
    public var episodesMarkedNotLag: Int
    public var activeHours: Double
    public var alertsPerActiveHour: Double?
    public var notLagPerActiveHour: Double?
    public var medianAlertDelaySec: Double?
    public var episodesByCause: [String: Int]
    public var unmatchedMarkTimes: [Date]
}

public enum Evaluator {
    public static func evaluate(_ records: [EpisodeRecord], marks: [MarkRecord], feedback: [FeedbackRecord], activeTicks: Int,
                                preToleranceSec: Double = 5, postToleranceSec: Double = 20) -> EvaluationReport {
        func matches(_ m: Date, _ e: Episode) -> Bool {
            let start = e.startWall.addingTimeInterval(-preToleranceSec)
            let end = (e.endWall ?? e.startWall).addingTimeInterval(postToleranceSec)
            return m >= start && m <= end
        }
        let eps = records.map(\.episode)
        var matched = 0
        var unmatched: [Date] = []
        for m in marks {
            if eps.contains(where: { matches(m.wall, $0) }) { matched += 1 } else { unmatched.append(m.wall) }
        }
        let confirmed = eps.filter { e in marks.contains { matches($0.wall, e) } }.count
        let notLagIDs = Set(feedback.filter { $0.kind == .notLag }.compactMap(\.episodeID))
        let hours = Double(activeTicks) / 3600
        let delays = records.compactMap { r in r.alertedAt.map { $0.timeIntervalSince(r.episode.startWall) } }
        var byCause: [String: Int] = [:]
        for r in records { byCause[r.diagnosis?.cause.rawValue ?? "none", default: 0] += 1 }
        let alerted = records.filter(\.alerted).count
        return EvaluationReport(
            marks: marks.count, episodes: records.count, alertedEpisodes: alerted, matchedMarks: matched,
            recall: marks.isEmpty ? nil : Double(matched) / Double(marks.count),
            episodesConfirmedByMark: confirmed, episodesMarkedNotLag: notLagIDs.count, activeHours: hours,
            alertsPerActiveHour: hours > 0 ? Double(alerted) / hours : nil,
            notLagPerActiveHour: hours > 0 ? Double(notLagIDs.count) / hours : nil,
            medianAlertDelaySec: Stats.median(delays), episodesByCause: byCause, unmatchedMarkTimes: unmatched)
    }
}
