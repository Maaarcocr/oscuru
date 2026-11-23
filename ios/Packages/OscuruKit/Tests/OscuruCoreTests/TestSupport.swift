import Foundation
import XCTest

@testable import OscuruCore

// Helpers shared by the OscuruCore tests.

/// Checks that `body` throws a `StateError` with exactly this message.
func assertStateError<T>(
    _ body: @autoclosure () throws -> T, _ expected: String, file: StaticString = #filePath, line: UInt = #line
) {
    guard let message = stateErrorMessage(body, file: file, line: line) else { return }
    XCTAssertEqual(message, expected, file: file, line: line)
}

/// Checks that `body` throws a `StateError` whose message contains every fragment.
func assertStateError<T>(
    _ body: @autoclosure () throws -> T, contains fragments: String..., file: StaticString = #filePath, line: UInt = #line
) {
    guard let message = stateErrorMessage(body, file: file, line: line) else { return }
    for fragment in fragments {
        XCTAssertTrue(message.contains(fragment), "\"\(message)\" does not contain \"\(fragment)\"", file: file, line: line)
    }
}

private func stateErrorMessage<T>(_ body: () throws -> T, file: StaticString, line: UInt) -> String? {
    do {
        _ = try body()
        XCTFail("expected a StateError, but nothing was thrown", file: file, line: line)
    } catch let error as StateError {
        return error.message
    } catch {
        XCTFail("expected a StateError, got \(error)", file: file, line: line)
    }
    return nil
}

/// A copy of `base` with `change` applied.
func edited(_ base: EditingState = EditingState(), _ change: (inout EditingState) throws -> Void) rethrows -> EditingState {
    var state = base
    try change(&state)
    return state
}

/// An untouched state with these global adjustments.
func global(_ settings: JSONValue) throws -> EditingState {
    try edited { try $0.adjust(settings) }
}

typealias RGB = (Double, Double, Double)

func assertColor(_ actual: RGB, _ expected: RGB, accuracy: Double = 0, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(actual.0, expected.0, accuracy: accuracy, "red", file: file, line: line)
    XCTAssertEqual(actual.1, expected.1, accuracy: accuracy, "green", file: file, line: line)
    XCTAssertEqual(actual.2, expected.2, accuracy: accuracy, "blue", file: file, line: line)
}

/// The floats stored in `data`, read without assuming the bytes are aligned.
func floats(in data: Data) -> [Float] {
    data.withUnsafeBytes { buffer in
        (0..<(buffer.count / MemoryLayout<Float>.size)).map { buffer.loadUnaligned(fromByteOffset: $0 * MemoryLayout<Float>.size, as: Float.self) }
    }
}

/// A fixed moment (2026-11-23 12:00 UTC), so no test depends on the clock.
let referenceDate = Date(timeIntervalSince1970: 1_795_435_200)
let day: TimeInterval = 86400

/// Runs `body` and returns the `ModelError` it throws, failing the test if it does not throw one.
func modelError(
    _ body: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line
) async -> ModelError? {
    do {
        try await body()
        XCTFail("expected a ModelError, but nothing was thrown", file: file, line: line)
    } catch let error as ModelError {
        return error
    } catch {
        XCTFail("expected a ModelError, got \(error)", file: file, line: line)
    }
    return nil
}
