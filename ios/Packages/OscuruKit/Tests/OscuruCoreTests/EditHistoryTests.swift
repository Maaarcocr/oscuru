import Foundation
import XCTest

@testable import OscuruCore

final class EditHistoryTests: XCTestCase {
    private let opened = EditingState(defaults: PhotoDefaults(temperature: 5200, tint: 8))

    /// The opened state with a given exposure: a cheap way to make states that differ.
    private func exposure(_ value: Double) throws -> EditingState {
        try edited(opened) { try $0.adjust(["exposureEV": .number(value)]) }
    }

    private func script(_ run: String, _ name: String = "s") -> EditHistory.Source {
        .assistant(run: run, script: name)
    }

    // MARK: Opening

    func testStartsWithTheOpenedStateAtRevisionOne() {
        let history = EditHistory(state: opened)
        XCTAssertEqual(history.state, opened)
        XCTAssertEqual(history.revision, 1)
        XCTAssertEqual(history.position, 0)
        XCTAssertEqual(history.entries.count, 1)
        XCTAssertEqual(history.entries.first?.source, .opened)
        XCTAssertEqual(history.entries.first?.id, 0)
        XCTAssertFalse(history.canUndo)
        XCTAssertFalse(history.canRedo)
    }

    func testCanStartAtAGivenRevision() throws {
        var history = EditHistory(state: opened, revision: 41)
        XCTAssertEqual(history.revision, 41)
        history.push(try exposure(1), source: .reset)
        XCTAssertEqual(history.revision, 42)
    }

    // MARK: Push, undo, redo

    func testPushMakesANewStepAndANewRevision() throws {
        var history = EditHistory(state: opened)
        XCTAssertTrue(history.push(try exposure(0.5), source: script("run-1", "first")))
        XCTAssertEqual(history.state, try exposure(0.5))
        XCTAssertEqual(history.revision, 2)
        XCTAssertEqual(history.position, 1)
        XCTAssertEqual(history.entries.count, 2)
        XCTAssertEqual(history.entries.last?.source, .assistant(run: "run-1", script: "first"))
        XCTAssertTrue(history.canUndo)
        XCTAssertFalse(history.canRedo)

        XCTAssertTrue(history.push(try exposure(1), source: .filter(name: "Warm film")))
        XCTAssertEqual(history.revision, 3)
        XCTAssertEqual(history.entries.map(\.source), [.opened, .assistant(run: "run-1", script: "first"), .filter(name: "Warm film")])
        XCTAssertEqual(history.entries.map(\.id), [0, 1, 2])
    }

    func testPushingAnEqualStateIsANoOp() throws {
        var history = EditHistory(state: opened)
        XCTAssertFalse(history.push(opened, source: script("run-1")))
        XCTAssertEqual(history.revision, 1)
        XCTAssertEqual(history.entries.count, 1)

        history.push(try exposure(0.5), source: script("run-1"))
        let before = history
        XCTAssertFalse(history.push(try exposure(0.5), source: .reset))
        XCTAssertEqual(history, before)
        XCTAssertEqual(history.revision, 2)
    }

    func testUndoAndRedoMoveThroughTheStepsAndEachGivesANewRevision() throws {
        var history = EditHistory(state: opened)
        history.push(try exposure(0.5), source: script("run-1"))
        history.push(try exposure(1), source: script("run-1"))
        XCTAssertEqual(history.revision, 3)

        XCTAssertTrue(history.undo())
        XCTAssertEqual(history.state, try exposure(0.5))
        XCTAssertEqual(history.revision, 4)
        XCTAssertTrue(history.canUndo)
        XCTAssertTrue(history.canRedo)

        XCTAssertTrue(history.undo())
        XCTAssertEqual(history.state, opened)
        XCTAssertEqual(history.revision, 5)
        XCTAssertFalse(history.canUndo)

        XCTAssertTrue(history.redo())
        XCTAssertEqual(history.state, try exposure(0.5))
        XCTAssertEqual(history.revision, 6)
        XCTAssertTrue(history.redo())
        XCTAssertEqual(history.state, try exposure(1))
        XCTAssertEqual(history.revision, 7)
        XCTAssertFalse(history.canRedo)
        XCTAssertEqual(history.entries.count, 3, "moving through the steps adds none")
    }

    func testUndoAndRedoAtTheEndsDoNothing() throws {
        var history = EditHistory(state: opened)
        XCTAssertFalse(history.undo())
        XCTAssertFalse(history.redo())
        XCTAssertEqual(history.revision, 1)

        history.push(try exposure(0.5), source: .reset)
        XCTAssertFalse(history.redo())
        XCTAssertEqual(history.revision, 2)
        XCTAssertTrue(history.undo())
        XCTAssertFalse(history.undo())
        XCTAssertEqual(history.revision, 3)
        XCTAssertEqual(history.state, opened)
    }

    func testANewStepDropsTheRedoBranch() throws {
        var history = EditHistory(state: opened)
        history.push(try exposure(0.5), source: script("run-1"))
        history.push(try exposure(1), source: script("run-1"))
        history.undo()
        history.undo()
        XCTAssertTrue(history.canRedo)

        history.push(try exposure(-1), source: script("run-2"))
        XCTAssertFalse(history.canRedo)
        XCTAssertFalse(history.redo())
        XCTAssertEqual(history.entries.map(\.state), [opened, try exposure(-1)])
        XCTAssertEqual(history.position, 1)
        XCTAssertEqual(history.revision, 6)
        XCTAssertEqual(history.entries.map(\.id), [0, 3], "identifiers of dropped steps are not reused")
    }

    func testPushingTheStateOneUndidIsStillANewStep() throws {
        var history = EditHistory(state: opened)
        history.push(try exposure(0.5), source: .reset)
        history.undo()
        // Equal to the step ahead, but not to the current state.
        XCTAssertTrue(history.push(try exposure(0.5), source: .reset))
        XCTAssertEqual(history.entries.count, 2)
        XCTAssertEqual(history.revision, 4)
    }

    // MARK: Reverting an instruction

    func testRevertTakesThePhotoBackToBeforeTheInstructionAsAStepThatCanBeUndone() throws {
        var history = EditHistory(state: opened)
        history.push(try exposure(0.2), source: .filter(name: "Warm film"))
        history.push(try exposure(0.5), source: script("run-1", "first"))
        history.push(try exposure(0.8), source: script("run-1", "second"))
        XCTAssertEqual(history.revision, 4)
        XCTAssertTrue(history.canRevert(run: "run-1"))
        XCTAssertEqual(history.stateBefore(run: "run-1"), try exposure(0.2))

        XCTAssertTrue(history.revert(run: "run-1"))
        XCTAssertEqual(history.state, try exposure(0.2))
        XCTAssertEqual(history.revision, 5)
        XCTAssertEqual(history.entries.count, 5)
        XCTAssertEqual(history.entries.last?.source, .reverted)
        XCTAssertFalse(history.canRevert(run: "run-1"), "there is nothing left to revert")
        XCTAssertFalse(history.revert(run: "run-1"))
        XCTAssertEqual(history.revision, 5)

        XCTAssertTrue(history.undo())
        XCTAssertEqual(history.state, try exposure(0.8), "undoing the revert brings the edits back")
        XCTAssertTrue(history.canRevert(run: "run-1"))
    }

    func testRevertOfAnEarlierInstructionAlsoRemovesWhatCameAfter() throws {
        var history = EditHistory(state: opened)
        history.push(try exposure(0.5), source: script("run-1"))
        history.push(try exposure(1), source: script("run-2"))
        XCTAssertEqual(history.stateBefore(run: "run-1"), opened)
        XCTAssertEqual(history.stateBefore(run: "run-2"), try exposure(0.5))

        XCTAssertTrue(history.revert(run: "run-1"))
        XCTAssertEqual(history.state, opened)

        XCTAssertTrue(history.undo())
        XCTAssertTrue(history.revert(run: "run-2"))
        XCTAssertEqual(history.state, try exposure(0.5))
    }

    func testAnInstructionThatMadeNoEditsCannotBeReverted() throws {
        var history = EditHistory(state: opened)
        history.push(try exposure(0.5), source: script("run-1"))
        XCTAssertFalse(history.canRevert(run: "run-9"))
        XCTAssertFalse(history.revert(run: "run-9"))
        XCTAssertEqual(history.stateBefore(run: "run-9"), try exposure(0.5), "the state before it is the current one")
        XCTAssertEqual(history.revision, 2)
        XCTAssertEqual(history.entries.count, 2)
    }

    func testAnInstructionWhoseEditsWereUndoneCannotBeReverted() throws {
        var history = EditHistory(state: opened)
        history.push(try exposure(0.5), source: script("run-1"))
        history.undo()
        XCTAssertFalse(history.canRevert(run: "run-1"))
        XCTAssertFalse(history.revert(run: "run-1"))
        XCTAssertEqual(history.stateBefore(run: "run-1"), opened)
        history.redo()
        XCTAssertTrue(history.canRevert(run: "run-1"))
    }

    func testAnInstructionThatEndedWhereItBeganCannotBeReverted() throws {
        var history = EditHistory(state: opened)
        history.push(try exposure(0.5), source: script("run-1", "first"))
        history.push(opened, source: script("run-1", "second"))
        XCTAssertFalse(history.canRevert(run: "run-1"))
        XCTAssertFalse(history.revert(run: "run-1"))
        XCTAssertEqual(history.entries.count, 3)
    }

    func testOnlyAssistantStepsBelongToAnInstruction() throws {
        var history = EditHistory(state: opened)
        history.push(try exposure(0.5), source: .filter(name: "run-1"))
        history.push(try exposure(1), source: .reset)
        XCTAssertFalse(history.canRevert(run: "run-1"))
        XCTAssertEqual(history.stateBefore(run: "run-1"), try exposure(1))
    }

    // MARK: Size

    func testKeepsAtMostTwoHundredSteps() throws {
        var history = EditHistory(state: opened)
        for step in 1...250 { XCTAssertTrue(history.push(try exposure(Double(step) / 100), source: script("run-\(step)"))) }
        XCTAssertEqual(history.entries.count, 200)
        XCTAssertEqual(history.position, 199)
        XCTAssertEqual(history.revision, 251, "revisions keep counting when old steps are dropped")
        XCTAssertEqual(history.state, try exposure(2.5))
        XCTAssertEqual(history.entries.first?.state, try exposure(0.51), "the oldest steps are the ones dropped")
        XCTAssertEqual(Set(history.entries.map(\.id)).count, 200)

        var undone = 0
        while history.undo() { undone += 1 }
        XCTAssertEqual(undone, 199)
        XCTAssertEqual(history.state, try exposure(0.51))
        XCTAssertEqual(history.revision, 450)
    }

    func testHistoriesWithTheSameStepsAreEqual() throws {
        var first = EditHistory(state: opened)
        var second = EditHistory(state: opened)
        XCTAssertEqual(first, second)
        first.push(try exposure(0.5), source: .reset)
        XCTAssertNotEqual(first, second)
        second.push(try exposure(0.5), source: .reset)
        XCTAssertEqual(first, second)
    }
}
