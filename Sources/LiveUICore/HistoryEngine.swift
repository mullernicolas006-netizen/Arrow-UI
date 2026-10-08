import Foundation
import LiveUIModels

/// The undo/redo timeline (§27, §54-55). Every entry carries full old/new
/// source snapshots, so undo and redo are pure text restores — they never
/// re-invoke the mutation logic, which is what makes them safe even if a
/// mutation's *forward* direction later stops resolving (e.g. because the
/// user hand-edited the file in between).
public final class HistoryEngine {
    private var records: [MutationRecord] = []
    private var undone: [MutationRecord] = []

    /// The current in-memory source per file, reflecting every applied (and
    /// not-undone) mutation. Callers fall back to disk when a file has no
    /// entry here yet.
    public private(set) var currentSource: [String: String] = [:]

    public init() {}

    public func record(_ record: MutationRecord) {
        records.append(record)
        undone.removeAll()
        currentSource[record.file] = record.newSource
    }

    public var canUndo: Bool { !records.isEmpty }
    public var canRedo: Bool { !undone.isEmpty }
    public var timeline: [MutationRecord] { records }

    @discardableResult
    public func undo() -> MutationRecord? {
        guard let last = records.popLast() else { return nil }
        undone.append(last)
        currentSource[last.file] = last.oldSource
        return last
    }

    @discardableResult
    public func redo() -> MutationRecord? {
        guard let last = undone.popLast() else { return nil }
        records.append(last)
        currentSource[last.file] = last.newSource
        return last
    }
}
