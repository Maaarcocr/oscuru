import Foundation
import XCTest

@testable import OscuruCore

final class UsageLedgerTests: XCTestCase {
    /// Midnight UTC at the start of the reference day, and the first of that month.
    private let startOfDay = referenceDate.addingTimeInterval(-12 * 3600)
    private let startOfMonth = referenceDate.addingTimeInterval(-12 * 3600 - 22 * day)

    private func entry(
        _ cost: Double, at date: Date = referenceDate, user: String = "ada", run: String = "run-1", photo: String = "photo-1",
        model: String = "anthropic/claude-test"
    ) -> UsageLedger.Entry {
        UsageLedger.Entry(date: date, user: user, model: model, cost: cost, promptTokens: 1000, completionTokens: 200, run: run, photo: photo)
    }

    /// Ada: three weeks ago, then twice today. Grace: once today.
    private func ledger() -> UsageLedger {
        var ledger = UsageLedger()
        ledger.add(entry(5, at: referenceDate.addingTimeInterval(-40 * day), run: "old", photo: "photo-0"))
        ledger.add(entry(0.4, at: referenceDate.addingTimeInterval(-21 * day), run: "run-0", photo: "photo-1"))
        ledger.add(entry(0.1, run: "run-1", photo: "photo-1"))
        ledger.add(entry(0.2, at: referenceDate.addingTimeInterval(600), run: "run-2", photo: "photo-2"))
        ledger.add(entry(9, at: referenceDate.addingTimeInterval(900), user: "grace", run: "run-3", photo: "photo-1"))
        return ledger
    }

    func testStartsEmpty() {
        let ledger = UsageLedger()
        XCTAssertEqual(ledger.entries, [])
        XCTAssertEqual(ledger.total(for: "ada"), 0)
        XCTAssertEqual(ledger.requests(by: "ada", since: .distantPast), 0)
    }

    func testAddRecordsEntriesInOrder() {
        let ledger = ledger()
        XCTAssertEqual(ledger.entries.count, 5)
        XCTAssertEqual(ledger.entries.map(\.run), ["old", "run-0", "run-1", "run-2", "run-3"])
        XCTAssertEqual(ledger.entries[2], entry(0.1))
    }

    func testSumsWhatOnePersonSpentSinceADate() {
        let ledger = ledger()
        XCTAssertEqual(ledger.spent(by: "ada", since: startOfDay), 0.3, accuracy: 1e-9)
        XCTAssertEqual(ledger.spent(by: "ada", since: startOfMonth), 0.7, accuracy: 1e-9)
        XCTAssertEqual(ledger.spent(by: "ada", since: .distantPast), 5.7, accuracy: 1e-9)
        XCTAssertEqual(ledger.spent(by: "ada", since: referenceDate.addingTimeInterval(day)), 0)
        XCTAssertEqual(ledger.spent(by: "grace", since: startOfDay), 9)
        XCTAssertEqual(ledger.spent(by: "nobody", since: .distantPast), 0)
    }

    func testTheDateItselfIsIncluded() {
        let ledger = ledger()
        XCTAssertEqual(ledger.spent(by: "ada", since: referenceDate), 0.3, accuracy: 1e-9)
        XCTAssertEqual(ledger.spent(by: "ada", since: referenceDate.addingTimeInterval(1)), 0.2, accuracy: 1e-9)
        XCTAssertEqual(ledger.requests(by: "ada", since: referenceDate), 2)
        XCTAssertEqual(ledger.requests(by: "ada", since: referenceDate.addingTimeInterval(1)), 1)
    }

    func testSumsPerInstructionPerPhotoAndInTotal() {
        let ledger = ledger()
        XCTAssertEqual(ledger.spent(by: "ada", onRun: "run-2"), 0.2, accuracy: 1e-9)
        XCTAssertEqual(ledger.spent(by: "ada", onRun: "run-3"), 0, "another person's instruction")
        XCTAssertEqual(ledger.spent(by: "ada", onRun: "missing"), 0)
        XCTAssertEqual(ledger.spent(by: "ada", onPhoto: "photo-1"), 0.5, accuracy: 1e-9)
        XCTAssertEqual(ledger.spent(by: "ada", onPhoto: "photo-2"), 0.2, accuracy: 1e-9)
        XCTAssertEqual(ledger.spent(by: "grace", onPhoto: "photo-1"), 9)
        XCTAssertEqual(ledger.total(for: "ada"), 5.7, accuracy: 1e-9)
        XCTAssertEqual(ledger.total(for: "grace"), 9)
        XCTAssertEqual(ledger.total(for: "nobody"), 0)
    }

    func testAnInstructionThatTookSeveralModelRequestsAddsUpAndCountsOnce() {
        var ledger = UsageLedger()
        ledger.add(entry(0.01, run: "run-1"))
        ledger.add(entry(0.02, at: referenceDate.addingTimeInterval(5), run: "run-1"))
        ledger.add(entry(0.04, at: referenceDate.addingTimeInterval(9), run: "run-1"))
        ledger.add(entry(0.08, at: referenceDate.addingTimeInterval(60), run: "run-2"))
        ledger.add(entry(1, at: referenceDate.addingTimeInterval(70), user: "grace", run: "run-1"))
        XCTAssertEqual(ledger.spent(by: "ada", onRun: "run-1"), 0.07, accuracy: 1e-9)
        XCTAssertEqual(ledger.requests(by: "ada", since: startOfDay), 2)
        XCTAssertEqual(ledger.requests(by: "grace", since: startOfDay), 1)
        XCTAssertEqual(ledger.requests(by: "ada", since: referenceDate.addingTimeInterval(day)), 0)
    }

    func testOnlyRecordsAndSumsNothingLimitsSpending() {
        var ledger = UsageLedger()
        for step in 0..<1000 { ledger.add(entry(100, at: referenceDate.addingTimeInterval(Double(step)), run: "run-\(step)")) }
        XCTAssertEqual(ledger.entries.count, 1000)
        XCTAssertEqual(ledger.total(for: "ada"), 100_000, accuracy: 1e-6)
        XCTAssertEqual(ledger.spent(by: "ada", since: startOfDay), 100_000, accuracy: 1e-6)
        XCTAssertEqual(ledger.requests(by: "ada", since: startOfDay), 1000)
    }

    func testRoundTripsThroughCodable() throws {
        let ledger = ledger()
        let data = try JSONEncoder().encode(ledger)
        let restored = try JSONDecoder().decode(UsageLedger.self, from: data)
        XCTAssertEqual(restored, ledger)
        XCTAssertEqual(restored.entries.map(\.date), ledger.entries.map(\.date))
        XCTAssertEqual(restored.spent(by: "ada", onRun: "run-1"), 0.1)
        XCTAssertEqual(restored.entries.first?.promptTokens, 1000)
        XCTAssertEqual(restored.entries.first?.completionTokens, 200)
        XCTAssertEqual(restored.entries.first?.model, "anthropic/claude-test")
        XCTAssertEqual(try JSONDecoder().decode(UsageLedger.self, from: try JSONEncoder().encode(UsageLedger())), UsageLedger())
    }

    func testForgetsEntriesOlderThanFourHundredDays() {
        var ledger = UsageLedger()
        ledger.add(entry(1, at: referenceDate.addingTimeInterval(-401 * day), run: "ancient"))
        ledger.add(entry(2, at: referenceDate.addingTimeInterval(-399 * day), run: "last-year"))
        XCTAssertEqual(ledger.entries.map(\.run), ["ancient", "last-year"], "nothing is dropped until a newer entry makes it old")
        ledger.add(entry(4, run: "today"))
        XCTAssertEqual(ledger.entries.map(\.run), ["last-year", "today"])
        XCTAssertEqual(ledger.total(for: "ada"), 6)
    }

    func testKeepsAnEntryExactlyFourHundredDaysOld() {
        var ledger = UsageLedger()
        ledger.add(entry(1, at: referenceDate.addingTimeInterval(-400 * day), run: "edge"))
        ledger.add(entry(2, run: "today"))
        XCTAssertEqual(ledger.entries.map(\.run), ["edge", "today"])
    }

    func testFormatsDollarsWithEnoughDigitsToMeanSomething() {
        XCTAssertEqual(UsageLedger.dollars(0), "$0.00")
        XCTAssertEqual(UsageLedger.dollars(0.0042), "$0.0042")
        XCTAssertEqual(UsageLedger.dollars(0.00004), "$0.0000")
        XCTAssertEqual(UsageLedger.dollars(0.0099), "$0.0099")
        XCTAssertEqual(UsageLedger.dollars(0.01), "$0.01")
        XCTAssertEqual(UsageLedger.dollars(0.05), "$0.05")
        XCTAssertEqual(UsageLedger.dollars(1.239), "$1.24")
        XCTAssertEqual(UsageLedger.dollars(12), "$12.00")
        XCTAssertEqual(UsageLedger.dollars(1234.5), "$1234.50")
    }
}
