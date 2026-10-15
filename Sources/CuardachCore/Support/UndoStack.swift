import Foundation

/// Snapshot-based undo/redo (PRD A15). Author mode records the whole
/// Experience value before each edit; values are small and copy-on-write,
/// so this is simpler and more reliable than inverse operations.
public struct UndoStack<Value: Equatable & Sendable>: Sendable {
    public let limit: Int
    private var past: [(label: String, value: Value)] = []
    private var future: [(label: String, value: Value)] = []

    public init(limit: Int = 50) { self.limit = limit }

    public var canUndo: Bool { !past.isEmpty }
    public var canRedo: Bool { !future.isEmpty }
    public var undoLabel: String? { past.last?.label }
    public var redoLabel: String? { future.last?.label }

    /// Records `before` as the state to return to. Consecutive edits with the
    /// same label within one gesture (e.g. a drag) can be coalesced.
    public mutating func record(_ before: Value, label: String, coalesce: Bool = false) {
        if coalesce, past.last?.label == label { future.removeAll(); return }
        if past.last?.value == before, past.last?.label == label { return }
        past.append((label, before))
        if past.count > limit { past.removeFirst(past.count - limit) }
        future.removeAll()
    }

    /// Returns the state to restore, given the current one.
    public mutating func undo(current: Value) -> Value? {
        guard let last = past.popLast() else { return nil }
        future.append((last.label, current))
        return last.value
    }

    public mutating func redo(current: Value) -> Value? {
        guard let next = future.popLast() else { return nil }
        past.append((next.label, current))
        return next.value
    }
}
