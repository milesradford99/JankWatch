import Foundation

/// A change JankWatch made to a process, kept so it can be shown and undone.
public struct ActionRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var kind: ActionKind
    public var groupKey: String
    public var displayName: String
    public var pids: [PIDRef]
    public var appliedAt: Date
    public var autoRevertAt: Date?
    public var revertedAt: Date?
    public var viaAdmin: Bool
    /// For `.adminFix`: the undo command, if any.
    public var undoCommand: [String]?
    public var note: String?

    public init(id: String = UUID().uuidString, kind: ActionKind, groupKey: String, displayName: String, pids: [PIDRef],
                appliedAt: Date, autoRevertAt: Date? = nil, viaAdmin: Bool = false, undoCommand: [String]? = nil, note: String? = nil) {
        self.id = id
        self.kind = kind
        self.groupKey = groupKey
        self.displayName = displayName
        self.pids = pids
        self.appliedAt = appliedAt
        self.autoRevertAt = autoRevertAt
        self.viaAdmin = viaAdmin
        self.undoCommand = undoCommand
        self.note = note
    }

    public var canRevert: Bool {
        revertedAt == nil && (kind.isReversible || (kind == .adminFix && undoCommand != nil))
    }
}

public struct ActionLedger: Codable, Equatable, Sendable {
    public var records: [ActionRecord] = []

    public init() {}

    public mutating func add(_ r: ActionRecord) {
        records.append(r)
    }

    public mutating func markReverted(_ id: String, at: Date) {
        if let i = records.firstIndex(where: { $0.id == id }) { records[i].revertedAt = at }
    }

    public func record(_ id: String) -> ActionRecord? { records.first { $0.id == id } }

    /// Active (not reverted) pauses.
    public var activePauses: [ActionRecord] { records.filter { $0.kind == .pause && $0.revertedAt == nil } }

    /// Reversible records whose auto-revert time has passed.
    public func due(now: Date) -> [ActionRecord] {
        records.filter { $0.revertedAt == nil && ($0.autoRevertAt.map { $0 <= now } ?? false) }
    }

    /// Active pauses that include `pid` (used to auto-resume an app when it is brought to front).
    public func activePauses(containing pid: Int32) -> [ActionRecord] {
        activePauses.filter { r in r.pids.contains { $0.pid == pid } }
    }

    /// Drop finished records older than `maxAge` seconds; keep at most `maxCount`.
    public mutating func prune(now: Date, maxAge: Double = 86400 * 3, maxCount: Int = 200) {
        records.removeAll { r in
            let finished = r.revertedAt != nil || !r.canRevert
            return finished && now.timeIntervalSince(r.appliedAt) > maxAge
        }
        if records.count > maxCount { records.removeFirst(records.count - maxCount) }
    }
}
