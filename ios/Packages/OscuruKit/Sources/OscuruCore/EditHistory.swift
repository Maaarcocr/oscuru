import Foundation

/// The settings of one open photo over time: every change is a step that can be undone, and every
/// change gives the photo a new revision number.
///
/// Revisions are how the agent and the person avoid overwriting each other: a script names the
/// revision it was written against and is refused if the photo has moved on.
public struct EditHistory: Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        case opened
        /// One script from the assistant, as part of carrying out one instruction (`run`).
        case assistant(run: String, script: String)
        case filter(name: String)
        case reverted
        case reset
    }

    public struct Entry: Equatable, Sendable, Identifiable {
        public let id: Int
        public let state: EditingState
        public let source: Source
    }

    public private(set) var entries: [Entry]
    /// Index in `entries` of the current state.
    public private(set) var position = 0
    public private(set) var revision: Int
    private var nextID = 1

    static let maxEntries = 200

    public init(state: EditingState, revision: Int = 1) {
        entries = [Entry(id: 0, state: state, source: .opened)]
        self.revision = revision
    }

    public var state: EditingState { entries[position].state }
    public var canUndo: Bool { position > 0 }
    public var canRedo: Bool { position < entries.count - 1 }

    /// Makes `state` current as a new step. Returns false, changing nothing, when it equals the current state.
    @discardableResult
    public mutating func push(_ state: EditingState, source: Source) -> Bool {
        guard state != self.state else { return false }
        entries = Array(entries[...position])
        entries.append(Entry(id: nextID, state: state, source: source))
        nextID += 1
        if entries.count > EditHistory.maxEntries { entries.removeFirst(entries.count - EditHistory.maxEntries) }
        position = entries.count - 1
        revision += 1
        return true
    }

    @discardableResult
    public mutating func undo() -> Bool {
        guard canUndo else { return false }
        position -= 1
        revision += 1
        return true
    }

    @discardableResult
    public mutating func redo() -> Bool {
        guard canRedo else { return false }
        position += 1
        revision += 1
        return true
    }

    private func firstIndex(ofRun run: String) -> Int? {
        entries[...position].firstIndex { entry in
            if case .assistant(let entryRun, _) = entry.source { return entryRun == run }
            return false
        }
    }

    /// Whether reverting this instruction would change the photo: its edits were applied and are still in effect.
    public func canRevert(run: String) -> Bool {
        guard let first = firstIndex(ofRun: run), first > 0 else { return false }
        return entries[first - 1].state != state
    }

    /// Takes the photo back to how it was before one of the assistant's instructions, as a new step
    /// (so the revert itself can be undone).
    @discardableResult
    public mutating func revert(run: String) -> Bool {
        guard canRevert(run: run), let first = firstIndex(ofRun: run) else { return false }
        return push(entries[first - 1].state, source: .reverted)
    }

    /// The state the photo had before the given instruction started, or the current one if it made no edits.
    public func stateBefore(run: String) -> EditingState {
        guard let first = firstIndex(ofRun: run), first > 0 else { return state }
        return entries[first - 1].state
    }
}
