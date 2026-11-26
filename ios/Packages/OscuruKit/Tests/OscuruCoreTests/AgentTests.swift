import Foundation
import XCTest

@testable import OscuruCore

/// A model that plays back prepared replies and records every request it receives.
private final class FakeModel: ModelClient, @unchecked Sendable {
    typealias Reply = @Sendable (ChatRequest) throws -> JSONValue
    private let lock = NSLock()
    private var replies: [Reply]
    private(set) var requests: [ChatRequest] = []
    var delay: Duration = .zero

    init(_ replies: [Reply]) {
        self.replies = replies
    }

    private func take(_ request: ChatRequest) -> Reply? {
        lock.withLock {
            requests.append(request)
            return replies.isEmpty ? nil : replies.removeFirst()
        }
    }

    func chat(_ request: ChatRequest) async throws -> ChatResponse {
        let reply = take(request)
        if delay > .zero { try await Task.sleep(for: delay) }
        guard let reply else { throw ModelError(.badRequest, "the fake model ran out of replies") }
        return ChatResponse(id: "gen", model: request.model, message: try reply(request), usage: Usage(promptTokens: 1000, completionTokens: 100, cost: 0.01))
    }
}

private func toolCall(_ id: String, code: String, name: String = Prompt.toolName, arguments: String? = nil) -> JSONValue {
    let args = arguments ?? JSONValue.object(["code": .string(code)]).text()
    return [
        "role": "assistant", "content": "Working on it.",
        "tool_calls": [["id": .string(id), "type": "function", "function": ["name": .string(name), "arguments": .string(args)]]],
    ]
}

private func note(_ text: String) -> JSONValue { ["role": "assistant", "content": .string(text)] }

/// The phone, in memory: each script bumps contrast by one and returns before/after pictures.
private actor FakePort: AgentPort {
    var state = EditingState()
    var revision = 1
    private(set) var executed: [JSONValue] = []

    func execute(arguments: JSONValue) async -> ToolExecution {
        executed.append(arguments)
        try? state.adjust(["contrast": .number(state.value("contrast") + 1)])
        revision += 1
        return ToolExecution(
            payload: ["status": "ok", "applied": true, "changes": [["path": "global.contrast", "from": 0, "to": 1]]],
            images: [LabeledImage(label: "Before:", jpeg: Data([1])), LabeledImage(label: "After:", jpeg: Data([2]))], state: state)
    }

    func executedCount() -> Int { executed.count }
}

private final class Sleeps: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [Double] = []
    var delays: [Double] { lock.withLock { list } }
    func add(_ delay: Double) { lock.withLock { list.append(delay) } }
}

final class AgentTests: XCTestCase {
    private var folder: URL!

    override func setUp() {
        folder = FileManager.default.temporaryDirectory.appending(path: "transcript-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
    }

    private let context = AgentContext(state: EditingState(), metadata: ["isRaw": true], statistics: ["meanLuminance": 0.4], styles: ["Dusk"])

    /// Writes an instruction the way the editor does: the words, the photo's context, its picture.
    @discardableResult
    private func instruct(_ transcript: Transcript, _ text: String = "Make it cinematic") async throws -> TranscriptEntry {
        let picture = try await transcript.store(LabeledImage(label: "The photo as it is now:", jpeg: Data([0xFF, 0xD8, 1])))
        return try await transcript.append(.user(Agent.instruction(text, context: context, pictures: [picture])))
    }

    private func run(_ transcript: Transcript, _ model: FakeModel, _ port: FakePort = FakePort(), window: Int? = nil, sleeps: Sleeps = Sleeps()) async throws {
        try await Agent.run(
            transcript: transcript, client: model, model: "anthropic/claude-sonnet-5.5", contextWindow: window, port: port, sessionID: "photo-1",
            sleep: { sleeps.add($0) }, onEvent: { _ in })
    }

    private func parts(_ message: JSONValue) -> [JSONValue] { message["content"]?.arrayValue ?? [] }
    private func images(_ messages: [JSONValue]) -> Int { messages.flatMap(parts).filter { $0["type"] == "image_url" }.count }
    private func turns(_ transcript: Transcript, working: Bool = false) async -> [Turn] {
        Conversation(await transcript.entries).turns(working: working, price: { usage, _ in usage.cost ?? 0 }, failure: { $0.message })
    }

    func testTheModelSeesThePhotoRunsAScriptAndSeesBeforeAndAfter() async throws {
        let transcript = try Transcript(folder: folder)
        try await instruct(transcript)
        let model = FakeModel([{ _ in toolCall("call-1", code: "photo.current.adjust({ contrast: 1 })") }, { _ in note("Done: a gentle grade.") }])
        try await run(transcript, model)

        let first = model.requests[0]
        XCTAssertEqual(first.messages[0]["role"], "system")
        XCTAssertTrue(first.messages[0]["content"]?.stringValue?.contains("interface PhotoDocument") ?? false)
        XCTAssertEqual(first.tools.count, 1)
        let opening = parts(first.messages[1])
        let text = opening[0]["text"]?.stringValue ?? ""
        XCTAssertTrue(text.hasPrefix("Make it cinematic\n\n[Photo context]\n"))
        XCTAssertTrue(text.contains("\"savedStyles\":[\"Dusk\"]"))
        XCTAssertEqual(opening[1]["text"], "The photo as it is now:")
        XCTAssertEqual(opening[2]["image_url"]?["url"]?.stringValue, "data:image/jpeg;base64,\(Data([0xFF, 0xD8, 1]).base64EncodedString())")

        // The report, then the pictures before and after.
        let second = model.requests[1].messages
        XCTAssertEqual(second[second.count - 2]["tool_call_id"], "call-1")
        XCTAssertEqual(JSONValue(text: second[second.count - 2]["content"]?.stringValue ?? "")?["applied"], true)
        XCTAssertEqual(parts(second[second.count - 1]).compactMap { $0["text"]?.stringValue }, ["[Pictures from the phone for the script above.]", "Before:", "After:"])

        // The thread, from the same records.
        let thread = await turns(transcript)
        XCTAssertEqual(thread.count, 1)
        XCTAssertEqual(thread[0].kind, .instruction("Make it cinematic"))
        XCTAssertEqual(thread[0].steps.map(\.outcome), [.applied])
        XCTAssertEqual(thread[0].steps[0].note, "Working on it.")
        XCTAssertEqual(thread[0].messages, ["Done: a gentle grade."])
        XCTAssertEqual(thread[0].result?.value("contrast"), 1)
        XCTAssertEqual(thread[0].cost ?? 0, 0.02, accuracy: 1e-9)
        XCTAssertEqual(thread[0].status, .done)
    }

    func testThereIsNoLimitAndTheAssistantMessageGoesBackUnchanged() async throws {
        let transcript = try Transcript(folder: folder)
        try await instruct(transcript)
        var members = toolCall("call-0", code: "1").objectValue!
        members["reasoning_details"] = [["type": "reasoning.encrypted", "data": "opaque"]]
        let first = JSONValue.object(members)
        var replies: [FakeModel.Reply] = [{ _ in first }]
        for index in 1..<40 { replies.append { _ in toolCall("call-\(index)", code: "1") } }
        replies.append { _ in note("Finally happy.") }
        let model = FakeModel(replies)
        let port = FakePort()
        try await run(transcript, model, port)
        let executed = await port.executedCount()
        XCTAssertEqual(executed, 40)
        let last = model.requests.last!
        XCTAssertNil(last.json["max_tokens"])
        XCTAssertEqual(last.json["tool_choice"], "auto")
        // Every picture of the run is still there for the model to compare.
        XCTAssertEqual(images(last.messages), 1 + 40 * 2)
        XCTAssertEqual(last.messages.first { $0["role"] == "assistant" }?["reasoning_details"], [["type": "reasoning.encrypted", "data": "opaque"]])
    }

    func testMalformedToolCallsGetAnErrorTheModelCanRead() async throws {
        let transcript = try Transcript(folder: folder)
        try await instruct(transcript)
        let model = FakeModel([
            { _ in toolCall("c1", code: "", name: "render_preview") }, { _ in toolCall("c2", code: "", arguments: "{not json") }, { _ in note("Sorry.") },
        ])
        let port = FakePort()
        try await run(transcript, model, port)
        let executed = await port.executedCount()
        XCTAssertEqual(executed, 0)
        let tools = model.requests[2].messages.filter { $0["role"] == "tool" }
        XCTAssertEqual(tools.map { $0["tool_call_id"] }, ["c1", "c2"])
        XCTAssertTrue(tools[0]["content"]?.stringValue?.contains("Unknown tool") ?? false)
        XCTAssertTrue(tools[1]["content"]?.stringValue?.contains("not a valid JSON object") ?? false)
    }

    func testADroppedConnectionIsRetriedAfterAPauseAndTheFailedAttemptsAreLeftOut() async throws {
        let transcript = try Transcript(folder: folder)
        try await instruct(transcript)
        let model = FakeModel([
            { _ in throw ModelError(.network, "The network connection was lost.") }, { _ in throw ModelError(.server, "Provider returned error", status: 502) },
            { _ in note("Done.") },
        ])
        let sleeps = Sleeps()
        try await run(transcript, model, sleeps: sleeps)
        XCTAssertEqual(sleeps.delays, [2, 4])
        XCTAssertEqual(model.requests.count, 3)
        XCTAssertEqual(model.requests[2].messages, model.requests[0].messages, "the same request, nothing of the failures in it")
        let thread = await turns(transcript)
        XCTAssertEqual(thread[0].status, .done)
        XCTAssertEqual(thread[0].messages, ["Done."])
    }

    func testAFailureThatDoesNotPassEndsTheRunAndContinuePicksItUp() async throws {
        let transcript = try Transcript(folder: folder)
        try await instruct(transcript)
        let sleeps = Sleeps()
        try await run(transcript, FakeModel([{ _ in throw ModelError(.unauthorized, "No auth credentials found", status: 401) }]), sleeps: sleeps)
        XCTAssertEqual(sleeps.delays, [], "a bad key is not worth retrying")
        var conversation = Conversation(await transcript.entries)
        XCTAssertTrue(conversation.canContinue)
        XCTAssertFalse(conversation.wasInterrupted)
        let seen1 = await turns(transcript)
        XCTAssertEqual(seen1[0].status, .failed("No auth credentials found"))

        // Retries run out too, and then the run waits for Continue.
        let flaky = FakeModel((0..<4).map { _ in { _ in throw ModelError(.server, "Overloaded", status: 529) } })
        try await transcript.append(.resume(automatic: false))
        try await run(transcript, flaky, sleeps: sleeps)
        XCTAssertEqual(sleeps.delays, [2, 4, 8])
        XCTAssertEqual(flaky.requests.count, 4)

        try await transcript.append(.resume(automatic: false))
        let model = FakeModel([{ _ in note("Now it works.") }])
        try await run(transcript, model)
        conversation = Conversation(await transcript.entries)
        XCTAssertFalse(conversation.canContinue)
        let thread = await turns(transcript)
        XCTAssertEqual(thread[0].status, .done)
        XCTAssertEqual(thread[0].messages, ["Now it works."])
        XCTAssertEqual(model.requests[0].messages.filter { $0["role"] == "user" }.count, 1)
    }

    func testStoppingKeepsTheConversationAndALaterInstructionCarriesOn() async throws {
        let transcript = try Transcript(folder: folder)
        try await instruct(transcript, "Go")
        let model = FakeModel([{ _ in toolCall("c1", code: "1") }, { _ in note("never") }])
        model.delay = .milliseconds(300)
        let task = Task {
            try await Agent.run(
                transcript: transcript, client: model, model: "m", contextWindow: nil, port: FakePort(), sessionID: "photo-1", sleep: { _ in }, onEvent: { _ in })
        }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        try await task.value
        var conversation = Conversation(await transcript.entries)
        XCTAssertEqual(conversation.halt, .stopped)
        let seen2 = await turns(transcript)
        XCTAssertEqual(seen2[0].status, .stopped)

        // Stopped while its script waited to run: the next request says it never ran.
        try await transcript.append(.assistant(.init(message: toolCall("c9", code: "1"), model: "m", usage: nil)))
        try await transcript.append(.stop)
        try await instruct(transcript, "Try again, warmer")
        conversation = Conversation(await transcript.entries)
        XCTAssertEqual(conversation.next, .answer)
        let later = FakeModel([{ _ in note("Warmer now.") }])
        try await run(transcript, later)
        let messages = later.requests[0].messages
        XCTAssertEqual(messages.filter { $0["role"] == "user" }.compactMap { parts($0).first?["text"]?.stringValue?.components(separatedBy: "\n").first }, ["Go", "Try again, warmer"])
        let notRun = messages.first { $0["tool_call_id"] == "c9" }
        XCTAssertEqual(JSONValue(text: notRun?["content"]?.stringValue ?? "")?["status"], "not_run")
        let seen3 = await turns(transcript)
        XCTAssertEqual(seen3.map(\.status), [.stopped, .done])
    }

    func testWorkTheAppClosedDuringCarriesOnFromTheTranscript() async throws {
        do {
            let transcript = try Transcript(folder: folder)
            try await instruct(transcript)
            try await transcript.append(.assistant(.init(message: toolCall("c1", code: "1"), model: "m", usage: nil)))
            // The app closes here, in the middle of a line.
            let handle = try FileHandle(forWritingTo: transcript.file)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data("{\"id\":\"half".utf8))
            try handle.close()
        }
        let transcript = try Transcript(folder: folder)
        let conversation = Conversation(await transcript.entries)
        XCTAssertEqual(conversation.entries.count, 2, "the cut-off line is dropped, nothing else")
        XCTAssertTrue(conversation.wasInterrupted)
        XCTAssertEqual(conversation.pendingCalls.map(\.id), ["c1"])
        let seen4 = await turns(transcript)
        XCTAssertEqual(seen4[0].steps.map(\.outcome), [.stopped])

        try await transcript.append(.resume(automatic: true))
        let model = FakeModel([{ _ in note("Finished.") }])
        let port = FakePort()
        try await run(transcript, model, port)
        let executed = await port.executedCount()
        XCTAssertEqual(executed, 1, "the script the model asked for runs")
        let messages = model.requests[0].messages
        XCTAssertEqual(messages.last?["content"]?.stringValue, Conversation.resumedNote, "told after the round, not between a call and its report")
        let seen5 = await turns(transcript)
        XCTAssertEqual(seen5[0].messages, ["Finished."])
        // And the file reads back whole.
        let reread = try await Transcript(folder: folder).entries.count
        let written = await transcript.entries.count
        XCTAssertEqual(reread, written)
    }

    func testMessagesSentWhileItWorksJoinBetweenSteps() async throws {
        let transcript = try Transcript(folder: folder)
        try await instruct(transcript)
        try await transcript.append(.assistant(.init(message: toolCall("c1", code: "1"), model: "m", usage: nil)))
        try await transcript.append(.user(Agent.steer("Keep the sky blue")))
        var conversation = Conversation(await transcript.entries)
        XCTAssertEqual(conversation.queued.count, 1)
        let seen6 = await turns(transcript, working: true)
        XCTAssertEqual(seen6.count, 1, "not in the thread until it is read")

        let model = FakeModel([{ _ in note("Kept the sky blue.") }])
        try await run(transcript, model)
        let roles = model.requests[0].messages.map { $0["role"]?.stringValue ?? "" }
        XCTAssertEqual(roles, ["system", "user", "assistant", "tool", "user", "user"])
        XCTAssertEqual(model.requests[0].messages.last?["content"]?.arrayValue?.first?["text"], "Keep the sky blue")
        conversation = Conversation(await transcript.entries)
        XCTAssertTrue(conversation.queued.isEmpty)
        let thread = await turns(transcript)
        XCTAssertEqual(thread.map(\.kind), [.instruction("Make it cinematic"), .instruction("Keep the sky blue")])
        XCTAssertEqual(thread[1].messages, ["Kept the sky blue."])
    }

    func testAnotherInstructionSendsOnlyTheLatestEarlierPicturesAndPrunesTheRest() async throws {
        let transcript = try Transcript(folder: folder)
        try await instruct(transcript, "First")
        try await run(transcript, FakeModel([{ _ in toolCall("c1", code: "1") }, { _ in note("First done.") }]))
        try await instruct(transcript, "Second")
        let model = FakeModel([{ _ in note("Second done.") }])
        try await run(transcript, model)
        let messages = model.requests[0].messages
        // The first opening picture is a note now; the last before/after pair and the new opening stay.
        XCTAssertEqual(images(messages), 3)
        XCTAssertTrue(messages.flatMap(parts).contains { $0["text"]?.stringValue == Conversation.removedPictureNote })
        await transcript.prune()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.appending(path: "pictures").path).count, 4, "recent pictures stay")
        await transcript.prune(keepingNewerThan: -1)
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.appending(path: "pictures").path)
        XCTAssertEqual(files.count, 3)
    }

    func testPicturesOfALongRunAreSentNewestFirstWithinTheirRoom() async throws {
        let transcript = try Transcript(folder: folder)
        try await instruct(transcript, "Many steps")
        try await run(transcript, FakeModel([{ _ in toolCall("c1", code: "1") }, { _ in toolCall("c2", code: "2") }, { _ in note("Done.") }]))
        let conversation = Conversation(await transcript.entries)
        func urls(_ messages: [JSONValue]) -> [String] {
            messages.flatMap(parts).compactMap { $0["image_url"]?["url"]?.stringValue }
        }
        let all = urls(conversation.messages(system: "s", picture: transcript.picture))
        XCTAssertGreaterThan(all.count, 2, "a run's pictures all go, while they fit")
        // Room for the newest alone.
        let newest = all.last!.count - "data:image/jpeg;base64,".count
        let one = conversation.messages(system: "s", pictureBytes: newest, picture: transcript.picture)
        XCTAssertEqual(urls(one), [all.last!], "past the room, the newest")
        XCTAssertEqual(one.flatMap(parts).filter { $0["text"]?.stringValue == Conversation.removedPictureNote }.count, all.count - 1)
        XCTAssertTrue(urls(conversation.messages(system: "s", pictureBytes: newest - 1, picture: transcript.picture)).isEmpty)
    }

    func testALongConversationIsSummarizedAndTheModelSeesTheSummaryInstead() async throws {
        let transcript = try Transcript(folder: folder)
        for index in 0..<4 {
            try await instruct(transcript, "Instruction \(index) " + String(repeating: "word ", count: 6000))
            try await transcript.append(.assistant(.init(message: note("Answer \(index)"), model: "m", usage: Usage(promptTokens: 150_000, completionTokens: 10, cost: 0.5))))
        }
        try await instruct(transcript, "Now make it black and white")
        let model = FakeModel([
            { request in
                XCTAssertTrue(request.tools.isEmpty)
                XCTAssertTrue(request.messages[1]["content"]?.stringValue?.contains("Instruction 0") ?? false)
                return note("## Goal\nA moody look.")
            },
            { _ in note("Black and white.") },
        ])
        try await run(transcript, model, window: 160_000)
        XCTAssertEqual(model.requests.count, 2)
        let messages = model.requests[1].messages
        XCTAssertTrue(messages[1]["content"]?.stringValue?.hasPrefix(Conversation.summaryPreface) ?? false)
        XCTAssertFalse(messages.contains { Agent.text(of: $0).contains("Instruction 0") }, "summarized")
        XCTAssertTrue(messages.contains { Agent.text(of: $0).contains("Now make it black and white") })
        // The thread is still all there.
        let seen7 = await turns(transcript)
        XCTAssertEqual(seen7.count, 5)

        // A request the provider says is too long is summarized and sent again, once.
        try await instruct(transcript, "One more " + String(repeating: "word ", count: 6000))
        let overflow = FakeModel([
            { _ in throw ModelError(.badRequest, "This endpoint's maximum context length is 160000 tokens.", status: 400) },
            { _ in note("## Goal\nStill moody.") }, { _ in note("Done.") },
        ])
        try await run(transcript, overflow)
        XCTAssertEqual(overflow.requests.count, 3)
        let seen8 = await turns(transcript)
        XCTAssertEqual(seen8.last?.messages, ["Done."])
    }

    func testThreadsSavedBeforeTheTranscriptKeepTheirTurnsAndConversation() async throws {
        let transcript = try Transcript(folder: folder)
        let old = Turn(id: "t1", kind: .instruction("Warmer"), steps: [Step(code: "1", outcome: .running)], status: .working)
        let picture: JSONValue = ["role": "user", "content": [["type": "text", "text": "Pictures"], ["type": "image_url", "image_url": ["url": "data:x"]]]]
        try await transcript.append(.imported(.init(turns: [Turn(id: "original", kind: .original, result: EditingState()), old], conversation: [
            ["role": "system", "content": "old prompt"], ["role": "user", "content": "Warmer"], picture, ["role": "assistant", "content": "Warmer now."],
        ])))
        let thread = await turns(transcript)
        XCTAssertEqual(thread.map(\.id), ["original", "t1"])
        XCTAssertEqual(thread[1].status, .stopped)
        XCTAssertEqual(thread[1].steps[0].outcome, .stopped)
        try await instruct(transcript, "Cooler")
        let model = FakeModel([{ _ in note("Cooler.") }])
        try await run(transcript, model)
        let messages = model.requests[0].messages
        XCTAssertEqual(messages.filter { $0["role"] == "system" }.count, 1)
        XCTAssertEqual(messages[1]["content"], "Warmer")
        XCTAssertEqual(images(messages), 1, "only the new opening picture")
    }

    func testTheTranscriptIsThePhotosHistory() async throws {
        let transcript = try Transcript(folder: folder)
        var styled = EditingState()
        try styled.adjust(["saturation": -20])
        try await transcript.append(.edit(.init(kind: .original, state: EditingState())))
        try await transcript.append(.edit(.init(kind: .style("Dusk"), state: styled)))
        var conversation = Conversation(await transcript.entries)
        XCTAssertEqual(conversation.state, styled)
        XCTAssertNil(conversation.stateBeforeRun, "no run yet")

        try await instruct(transcript)
        let port = FakePort()
        try await run(transcript, FakeModel([{ _ in toolCall("c1", code: "1") }, { _ in toolCall("c2", code: "1") }, { _ in note("Done.") }]), port)
        conversation = Conversation(await transcript.entries)
        XCTAssertEqual(conversation.state?.value("contrast"), 2, "what the last script left")
        XCTAssertEqual(conversation.stateBeforeRun, styled, "what the photo was when the instruction came")

        // A script cut off before its report leaves the photo as the transcript last recorded it.
        try await instruct(transcript, "More")
        try await transcript.append(.assistant(.init(message: toolCall("c3", code: "1"), model: "m", usage: nil)))
        conversation = Conversation(await transcript.entries)
        XCTAssertEqual(conversation.state?.value("contrast"), 2)
        XCTAssertEqual(conversation.stateBeforeRun?.value("contrast"), 2)
        XCTAssertEqual(conversation.pendingCalls.map(\.id), ["c3"])
    }

    func testRecordsWrittenByEarlierVersionsStillRead() throws {
        // A style used to be called a filter, and going back to the original had a kind of its own.
        func kind(_ json: String) throws -> Turn.Kind { try JSONDecoder().decode(Turn.Kind.self, from: Data(json.utf8)) }
        XCTAssertEqual(try kind(#"{"filter":{"_0":"Dusk"}}"#), .style("Dusk"))
        XCTAssertEqual(try kind(#"{"startOver":{}}"#), .startOver)
        XCTAssertEqual(try kind(#"{"instruction":{"_0":"Warmer"}}"#), .instruction("Warmer"))
        XCTAssertEqual(String(decoding: try JSONEncoder().encode(Turn.Kind.style("Dusk")), as: UTF8.self), #"{"filter":{"_0":"Dusk"}}"#)
        XCTAssertEqual(try JSONDecoder().decode(Step.Outcome.self, from: Data(#"{"stale":{}}"#.utf8)), .stale)
    }

    func testRecordsReadBackAsTheyWereWritten() async throws {
        let transcript = try Transcript(folder: folder)
        try await instruct(transcript)
        try await transcript.append(.edit(.init(kind: .style("Dusk"), state: EditingState())))
        try await transcript.append(.failure(.init(kind: .rateLimit, message: "Slow down", status: 429, retrying: true, delay: 2)))
        try await transcript.append(.placed(["a"]))
        try await transcript.append(.stop)
        try await transcript.append(.resume(automatic: true))
        try await transcript.append(.compaction(.init(summary: "s", firstKept: "x", tokensBefore: 10, usage: nil, model: "m")))
        let reopened = try Transcript(folder: folder)
        let written = await transcript.entries
        let read = await reopened.entries
        XCTAssertEqual(read.map(\.body), written.map(\.body))
        XCTAssertEqual(read.map(\.id), written.map(\.id))
    }
}

final class OpenRouterTests: XCTestCase {
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var responses: [HTTPResponse]
        private(set) var requests: [HTTPRequest] = []
        init(_ responses: [(Int, JSONValue)]) {
            self.responses = responses.map { HTTPResponse(status: $0.0, body: Data($0.1.text().utf8)) }
        }
        private func next(_ request: HTTPRequest) -> HTTPResponse? {
            lock.withLock {
                requests.append(request)
                return responses.isEmpty ? nil : responses.removeFirst()
            }
        }
        var transport: HTTPTransport {
            { request in
                guard let response = self.next(request) else { throw URLError(.notConnectedToInternet) }
                return response
            }
        }
    }

    private let completion: JSONValue = [
        "id": "gen-1", "model": "anthropic/claude-sonnet-5.5",
        "choices": [["message": ["role": "assistant", "content": "Done."], "finish_reason": "stop"]],
        "usage": ["prompt_tokens": 10, "completion_tokens": 5, "cost": 0.0021],
    ]

    func testAChatRequestCarriesTheKeyTheToolAndNoLimits() async throws {
        let recorder = Recorder([(200, completion)])
        let client = OpenRouter(apiKey: "sk-or-test", transport: recorder.transport)
        let response = try await client.chat(ChatRequest(model: "anthropic/claude-sonnet-5.5", messages: [["role": "user", "content": "hi"]], tools: [Prompt.tool], sessionID: "photo-1"))
        XCTAssertEqual(response.message["content"], "Done.")
        XCTAssertEqual(response.usage, Usage(promptTokens: 10, completionTokens: 5, cost: 0.0021))
        let request = recorder.requests[0]
        XCTAssertEqual(request.url, "https://openrouter.ai/api/v1/chat/completions")
        XCTAssertEqual(request.headers["Authorization"], "Bearer sk-or-test")
        XCTAssertEqual(request.headers["X-OpenRouter-Title"], "Oscuru")
        let body = try XCTUnwrap(JSONValue(text: String(decoding: request.body ?? Data(), as: UTF8.self)))
        XCTAssertNil(body["max_tokens"])
        XCTAssertEqual(body["parallel_tool_calls"], false)
        XCTAssertEqual(body["session_id"], "photo-1")
        XCTAssertEqual(body["cache_control"], ["type": "ephemeral"])
        let other = ChatRequest(model: "google/gemini-4-carbon", messages: [], tools: []).json
        XCTAssertNil(other["cache_control"])
    }

    func testStatusCodesBecomeErrorKindsWithTheProvidersMessage() async {
        for (status, kind) in [(401, ModelError.Kind.unauthorized), (402, .payment), (429, .rateLimit), (400, .badRequest)] {
            let recorder = Recorder([(status, ["error": ["message": "because"]])])
            do {
                _ = try await OpenRouter(apiKey: "k", transport: recorder.transport).chat(ChatRequest(model: "m", messages: [], tools: []))
                XCTFail("expected an error for \(status)")
            } catch let error as ModelError {
                XCTAssertEqual(error.kind, kind)
                XCTAssertEqual(error.message, "because")
                XCTAssertEqual(recorder.requests.count, 1, "no retry for \(status)")
            } catch {
                XCTFail("unexpected \(error)")
            }
        }
    }

    func testFailuresAreClassedForTheLoopNotRetriedHere() async throws {
        let offline = Recorder([])
        do {
            _ = try await OpenRouter(apiKey: "k", transport: offline.transport).chat(ChatRequest(model: "m", messages: [], tools: []))
            XCTFail("expected an error")
        } catch let error as ModelError {
            XCTAssertEqual(error.kind, .network)
            XCTAssertEqual(offline.requests.count, 1, "the loop retries, where the person can see it")
            XCTAssertTrue(error.isTransient)
        }
        XCTAssertTrue(ModelError(.server, "Provider returned error", status: 502).isTransient)
        XCTAssertTrue(ModelError(.badRequest, "Provider returned error").isTransient)
        XCTAssertFalse(ModelError(.unauthorized, "No auth credentials found", status: 401).isTransient)
        XCTAssertFalse(ModelError(.payment, "Insufficient credits", status: 402).isTransient)
        let overflow = ModelError(.badRequest, "This endpoint's maximum context length is 200000 tokens. However, you requested about 250000 tokens.", status: 400)
        XCTAssertTrue(overflow.isContextOverflow)
        XCTAssertFalse(overflow.isTransient)
        // A request without tools sends no tool settings.
        XCTAssertNil(ChatRequest(model: "m", messages: [], tools: []).json["tool_choice"])
    }

    func testAnErrorInsideA200IsAnError() async {
        let recorder = Recorder([(200, ["error": ["code": 402, "message": "Insufficient credits"]])])
        do {
            _ = try await OpenRouter(apiKey: "k", transport: recorder.transport).chat(ChatRequest(model: "m", messages: [], tools: []))
            XCTFail("expected an error")
        } catch let error as ModelError {
            XCTAssertEqual(error.kind, .payment)
            XCTAssertEqual(error.message, "Insufficient credits")
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testKeyInfoModelsAndSignIn() async throws {
        let recorder = Recorder([
            (200, ["data": ["label": "sk-or-v1-abc…xyz", "usage": 1.5, "limit": nil, "limit_remaining": nil]]),
            (
                200,
                [
                    "data": [
                        ["id": "a/vision", "name": "A", "architecture": ["input_modalities": ["text", "image"]], "supported_parameters": ["tools"], "pricing": ["prompt": "0.000002", "completion": "0.00001"]],
                        ["id": "a/vision:batch", "name": "A batch", "architecture": ["input_modalities": ["image"]], "supported_parameters": ["tools"], "pricing": ["prompt": "0", "completion": "0"]],
                        ["id": "b/text", "name": "B", "architecture": ["input_modalities": ["text"]], "supported_parameters": ["tools"], "pricing": ["prompt": "0", "completion": "0"]],
                        ["id": "c/router", "name": "C", "architecture": ["input_modalities": ["image"]], "supported_parameters": ["tools"], "pricing": ["prompt": "-1", "completion": "-1"]],
                    ]
                ]
            ),
            (200, ["key": "sk-or-v1-new", "user_id": "user_1"]),
        ])
        let client = OpenRouter(apiKey: "k", transport: recorder.transport)
        let info = try await client.keyInfo()
        XCTAssertEqual(info, KeyInfo(label: "sk-or-v1-abc…xyz", usage: 1.5, limit: nil, limitRemaining: nil))
        let models = try await client.editingModels()
        XCTAssertEqual(models, [ModelInfo(id: "a/vision", name: "A", promptPrice: 2, completionPrice: 10)])
        let exchanged = try await client.exchange(code: "code-1", verifier: "verifier-1")
        XCTAssertEqual(exchanged.key, "sk-or-v1-new")
        XCTAssertEqual(exchanged.userID, "user_1")
        XCTAssertEqual(recorder.requests.map(\.url), [
            "https://openrouter.ai/api/v1/key", "https://openrouter.ai/api/v1/models?input_modalities=image&supported_parameters=tools", "https://openrouter.ai/api/v1/auth/keys",
        ])
        XCTAssertEqual(
            OpenRouter.signInURL(codeChallenge: "abc", callback: "oscuru://openrouter"),
            "https://openrouter.ai/auth?callback_url=oscuru%3A%2F%2Fopenrouter&code_challenge=abc&code_challenge_method=S256&key_label=Oscuru")
        XCTAssertEqual(OpenRouter.signInURL(codeChallenge: "abc", callback: nil), "https://openrouter.ai/auth?code_challenge=abc&code_challenge_method=S256&key_label=Oscuru")
    }

    func testCostIsWhatWasChargedOrTheTokensPriced() {
        let model = ModelInfo(id: "m", name: "m", promptPrice: 2, completionPrice: 10)
        XCTAssertEqual(OpenRouter.cost(of: Usage(promptTokens: 1000, completionTokens: 100, cost: 0.5), model: model), 0.5)
        XCTAssertEqual(OpenRouter.cost(of: Usage(promptTokens: 1000, completionTokens: 100, cost: nil), model: model), 0.003, accuracy: 1e-12)
        XCTAssertEqual(OpenRouter.cost(of: Usage(promptTokens: 1000, completionTokens: 100, cost: nil), model: nil), 0)
    }
}

final class PhotoAPITests: XCTestCase {
    func testTheDeclarationsStateTheSameRangesTheEditorEnforces() {
        let text = PhotoAPI.declarations
        XCTAssertTrue(text.contains("Range -5 to 5 stops. Default 0."))
        XCTAssertTrue(text.contains("Range 2000 to 25000 K. Starts at the as-shot value"))
        XCTAssertTrue(text.contains(#"type ColorRange = "red" | "orange" | "yellow" | "green" | "aqua" | "blue" | "purple" | "magenta";"#))
        XCTAssertTrue(text.contains("2 to 16 points"))
        XCTAssertTrue(text.contains("show(which?:"))
        XCTAssertTrue(text.contains("readonly styles:"))
        XCTAssertEqual(Prompt.tool["function"]?["parameters"]?["required"], ["code"], "the script is all the tool takes")
        XCTAssertTrue(Prompt.system.contains(text))
        XCTAssertTrue(Prompt.system.contains(Prompt.toolName))
        XCTAssertFalse(Prompt.system.lowercased().contains("maxscripts"))
    }

    /// docs/photo-api.d.ts is the API as a file people can read and tools can load.
    /// `UPDATE_API_DOCS=1 swift test` rewrites it; otherwise this fails when it has fallen behind.
    func testTheDocsFileIsCurrent() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { root.deleteLastPathComponent() }
        let target = root.appending(path: "docs/photo-api.d.ts")
        let expected = "// Generated from ios/Packages/OscuruKit/Sources/OscuruCore/PhotoAPI.swift by `UPDATE_API_DOCS=1 swift test`. Do not edit by hand.\n\n" + PhotoAPI.declarations
        if ProcessInfo.processInfo.environment["UPDATE_API_DOCS"] != nil {
            try expected.write(to: target, atomically: true, encoding: .utf8)
        }
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), expected)
    }
}
