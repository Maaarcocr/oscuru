import Foundation
import XCTest

@testable import OscuruCore

final class TranscriptExportTests: XCTestCase {
    func testTheTimeOfEachStepIsReadFromWhenItsRecordWasWritten() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var count = 0
        func entry(_ after: Double, _ body: TranscriptEntry.Body) -> TranscriptEntry {
            count += 1
            return TranscriptEntry(id: "e\(count)", date: start.addingTimeInterval(after), body: body)
        }
        let call: JSONValue = [
            "role": "assistant", "content": .null,
            "tool_calls": [["id": "c1", "type": "function", "function": ["name": .string(Prompt.toolName), "arguments": #"{"code":"photo.current.adjust({ exposure: 0.3 })"}"#]]],
            "reasoning_details": [["type": "reasoning.encrypted", "data": .string(String(repeating: "x", count: 5000))]],
        ]
        let entries = [
            entry(0, .user(.init(text: "Make it moody", prompt: "Make it moody"))),
            // The model took 40 seconds to ask for a script; the phone took 6 to run and report it, 2 of them in the script.
            entry(40, .assistant(.init(message: call, model: "m", usage: Usage(promptTokens: 1000, completionTokens: 50, cost: 0.02)))),
            entry(46, .toolResult(.init(call: "c1", payload: ["status": "ok", "durationMs": 2000]))),
            // A request failed after 5 seconds, waited 4, and then took 20.
            entry(51, .failure(.init(kind: .server, message: "Overloaded", status: 529, retrying: true, delay: 4))),
            entry(75, .assistant(.init(message: ["role": "assistant", "content": "Done: moodier."], model: "m", usage: Usage(promptTokens: 1200, completionTokens: 20, cost: 0.03)))),
        ]
        let steps = TranscriptExport.steps(of: entries)
        XCTAssertEqual(steps.map(\.kind), ["message", "request", "script", "failure", "request"])
        XCTAssertEqual(steps.map(\.seconds), [nil, 40, 6, 5, 20])
        XCTAssertEqual(steps[2].note, "photo.current.adjust({ exposure: 0.3 })")
        let summary = TranscriptExport.summary(of: steps)
        XCTAssertEqual(summary.model, 60)
        XCTAssertEqual(summary.phone, 6)
        XCTAssertEqual(summary.script, 2)
        XCTAssertEqual(summary.retries, 9)
        XCTAssertEqual(summary.cost, 0.05, accuracy: 1e-9)

        let data = TranscriptExport.data(photos: [.init(id: "p1", name: "Lake.dng", entries: entries)], app: "0.1.0 (51)", device: "iPhone19,2", system: "iOS 27.0.1", date: start)
        let document = try XCTUnwrap(JSONValue(text: String(decoding: data, as: UTF8.self)))
        XCTAssertEqual(document["summary"]?["seconds"]?["model"], 60)
        XCTAssertEqual(document["photos"]?.arrayValue?.first?["steps"]?.arrayValue?.count, 5)
        let records = try XCTUnwrap(document["photos"]?.arrayValue?.first?["records"]?.arrayValue)
        XCTAssertEqual(records.count, 5)
        XCTAssertEqual(records[1]["data"]?["message"]?["reasoning_details"]?.arrayValue?.first?["data"], "[5000 characters]", "opaque reasoning is cut")
    }

    func testATranscriptIsReadWithoutTouchingIt() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        XCTAssertTrue(Transcript.entries(in: folder).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path), "nothing is created")
        let transcript = try Transcript(folder: folder)
        try await transcript.append(.stop)
        // A line still being written is left out, and left in the file.
        let handle = try FileHandle(forWritingTo: transcript.file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"id":"half"#.utf8))
        try handle.close()
        let size = try Data(contentsOf: transcript.file).count
        XCTAssertEqual(Transcript.entries(in: folder).count, 1)
        XCTAssertEqual(try Data(contentsOf: transcript.file).count, size)
    }
}
