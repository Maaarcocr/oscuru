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
        guard let reply else { throw ModelError(.server, "the fake model ran out of replies") }
        return ChatResponse(id: "gen", model: request.model, message: try reply(request), usage: Usage(promptTokens: 1000, completionTokens: 100, cost: 0.01))
    }

    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return requests.count
    }
}

private func toolCall(_ id: String, code: String, revision: Int = 1, name: String = Prompt.toolName, arguments: String? = nil) -> JSONValue {
    let args = arguments ?? JSONValue.object(["sessionId": "photo-1", "baseRevision": .number(Double(revision)), "code": .string(code)]).text()
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

    func context() async -> AgentContext {
        AgentContext(sessionID: "photo-1", revision: revision, state: state, metadata: ["isRaw": true], statistics: ["meanLuminance": 0.4], filters: ["Dusk"])
    }

    func openingImages() async -> [LabeledImage] {
        [LabeledImage(label: "The photo as it is now:", jpeg: Data([0xFF, 0xD8, 1]))]
    }

    func execute(arguments: JSONValue) async -> ToolExecution {
        executed.append(arguments)
        try? state.adjust(["contrast": .number(state.value("contrast") + 1)])
        revision += 1
        return ToolExecution(
            payload: ["status": "ok", "applied": true, "revision": .number(Double(revision))],
            images: [LabeledImage(label: "Before:", jpeg: Data([1])), LabeledImage(label: "After:", jpeg: Data([2]))])
    }

    func executedCount() -> Int { executed.count }
}

private final class Events: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [AgentEvent] = []
    func add(_ event: AgentEvent) {
        lock.lock()
        list.append(event)
        lock.unlock()
    }
    var names: [String] {
        lock.lock()
        defer { lock.unlock() }
        return list.map { event in
            switch event {
            case .thinking: return "thinking"
            case .text: return "text"
            case .scriptStarted: return "started"
            case .scriptFinished: return "finished"
            case .usage: return "usage"
            }
        }
    }
}

final class AgentTests: XCTestCase {
    private func run(_ model: FakeModel, _ port: FakePort, conversation: [JSONValue] = [], instruction: String = "Make it cinematic", events: Events = Events()) async throws -> AgentTurn {
        try await Agent.run(client: model, model: "anthropic/claude-sonnet-5.5", port: port, conversation: conversation, instruction: instruction) { events.add($0) }
    }

    private func parts(_ message: JSONValue) -> [JSONValue] { message["content"]?.arrayValue ?? [] }

    func testTheModelSeesThePhotoRunsAScriptAndSeesBeforeAndAfter() async throws {
        let model = FakeModel([{ _ in toolCall("call-1", code: "photo.current.adjust({ contrast: 1 })") }, { _ in note("Done: a gentle grade.") }])
        let port = FakePort()
        let events = Events()
        let turn = try await run(model, port, events: events)

        XCTAssertEqual(turn.stop, .done)
        XCTAssertEqual(turn.text, "Done: a gentle grade.")
        XCTAssertEqual(turn.scripts, 1)
        XCTAssertEqual(events.names, ["thinking", "usage", "text", "started", "finished", "thinking", "usage", "text"])

        let first = model.requests[0]
        XCTAssertEqual(first.messages[0]["role"], "system")
        XCTAssertTrue(first.messages[0]["content"]?.stringValue?.contains("interface PhotoDocument") ?? false)
        XCTAssertEqual(first.tools.count, 1)
        XCTAssertEqual(first.tools[0]["function"]?["name"]?.stringValue, Prompt.toolName)
        let opening = parts(first.messages[1])
        let text = opening[0]["text"]?.stringValue ?? ""
        XCTAssertTrue(text.hasPrefix("Make it cinematic"))
        XCTAssertTrue(text.contains("\"sessionId\":\"photo-1\""))
        XCTAssertTrue(text.contains("\"savedFilters\":[\"Dusk\"]"))
        XCTAssertEqual(opening[1]["text"], "The photo as it is now:")
        XCTAssertEqual(opening[2]["image_url"]?["url"]?.stringValue, "data:image/jpeg;base64,\(Data([0xFF, 0xD8, 1]).base64EncodedString())")

        // The tool result, then the pictures before and after.
        let second = model.requests[1].messages
        let tool = second[second.count - 2]
        XCTAssertEqual(tool["role"], "tool")
        XCTAssertEqual(tool["tool_call_id"], "call-1")
        XCTAssertEqual(JSONValue(text: tool["content"]?.stringValue ?? "")?["applied"], true)
        let pictures = parts(second[second.count - 1])
        XCTAssertEqual(pictures.compactMap { $0["text"]?.stringValue }, ["[Pictures from the phone for the script above.]", "Before:", "After:"])
        XCTAssertEqual(pictures.filter { $0["type"] == "image_url" }.count, 2)
    }

    func testThereIsNoLimitOnHowManyScriptsATurnRuns() async throws {
        var replies: [FakeModel.Reply] = (0..<40).map { index in { _ in toolCall("call-\(index)", code: "1") } }
        replies.append { _ in note("Finally happy.") }
        let model = FakeModel(replies)
        let port = FakePort()
        let turn = try await run(model, port)
        XCTAssertEqual(turn.stop, .done)
        XCTAssertEqual(turn.scripts, 40)
        let executed = await port.executedCount()
        XCTAssertEqual(executed, 40)
        // Nothing in the request caps the answer or forces the model to stop.
        let last = model.requests.last!.json
        XCTAssertNil(last["max_tokens"])
        XCTAssertEqual(last["tool_choice"], "auto")
        // Every picture of the turn is still there for the model to compare.
        XCTAssertEqual(model.requests.last!.messages.flatMap(parts).filter { $0["type"] == "image_url" }.count, 1 + 40 * 2)
    }

    func testTheAssistantMessageGoesBackUnchanged() async throws {
        var members = toolCall("call-1", code: "1").objectValue!
        members["reasoning_details"] = [["type": "reasoning.encrypted", "data": "opaque"]]
        let call = JSONValue.object(members)
        let model = FakeModel([{ _ in call }, { _ in note("ok") }])
        _ = try await run(model, FakePort())
        let assistant = model.requests[1].messages.first { $0["role"] == "assistant" }
        XCTAssertEqual(assistant?["reasoning_details"], [["type": "reasoning.encrypted", "data": "opaque"]])
    }

    func testMalformedToolCallsGetAnErrorTheModelCanRead() async throws {
        let model = FakeModel([
            { _ in toolCall("c1", code: "", name: "render_preview") },
            { _ in toolCall("c2", code: "", arguments: "{not json") },
            { _ in note("Sorry.") },
        ])
        let port = FakePort()
        let turn = try await run(model, port)
        XCTAssertEqual(turn.scripts, 0)
        let executed = await port.executedCount()
        XCTAssertEqual(executed, 0)
        let tools = model.requests[2].messages.filter { $0["role"] == "tool" }
        XCTAssertEqual(tools.map { $0["tool_call_id"] }, ["c1", "c2"])
        XCTAssertTrue(tools[0]["content"]?.stringValue?.contains("Unknown tool") ?? false)
        XCTAssertTrue(tools[1]["content"]?.stringValue?.contains("not a valid JSON object") ?? false)
    }

    func testAModelErrorPropagatesAndTheConversationStaysUsable() async throws {
        let model = FakeModel([{ _ in throw ModelError(.unauthorized, "No auth credentials found", status: 401) }])
        do {
            _ = try await run(model, FakePort())
            XCTFail("expected an error")
        } catch let error as ModelError {
            XCTAssertEqual(error.kind, .unauthorized)
        }
        let retry = FakeModel([{ _ in note("Now it works.") }])
        let turn = try await run(retry, FakePort())
        XCTAssertEqual(turn.text, "Now it works.")
    }

    func testCancellingReturnsTheConversationAsItWas() async throws {
        let model = FakeModel([{ _ in toolCall("c1", code: "1") }, { _ in toolCall("c2", code: "1") }, { _ in note("never") }])
        model.delay = .milliseconds(300)
        let port = FakePort()
        let before: [JSONValue] = [["role": "system", "content": "earlier"], ["role": "user", "content": "hello"]]
        let task = Task {
            try await Agent.run(client: model, model: "m", port: port, conversation: before, instruction: "Go") { _ in }
        }
        try await Task.sleep(for: .milliseconds(450))
        task.cancel()
        let turn = try await task.value
        XCTAssertEqual(turn.stop, .cancelled)
        XCTAssertEqual(turn.conversation, before)
    }

    func testASecondInstructionContinuesTheConversationWithOnlyTheLatestEarlierPictures() async throws {
        let model = FakeModel([{ _ in toolCall("c1", code: "1") }, { _ in note("First done.") }, { _ in note("Second done.") }])
        let port = FakePort()
        let first = try await run(model, port, instruction: "First")
        _ = try await run(model, port, conversation: first.conversation, instruction: "Second")
        let messages = model.requests.last!.messages
        XCTAssertEqual(messages.filter { $0["role"] == "system" }.count, 1)
        // The first turn's opening picture is replaced by a note; its last before/after pair and the new opening stay.
        let images = messages.flatMap(parts).filter { $0["type"] == "image_url" }.count
        XCTAssertEqual(images, 3)
        XCTAssertTrue(messages.flatMap(parts).contains { $0["text"]?.stringValue == Agent.removedImageNote })
    }

    func testCompactingKeepsTheLatestMessageWithPictures() {
        func withImage(_ name: String) -> JSONValue {
            ["role": "user", "content": [["type": "text", "text": .string(name)], ["type": "image_url", "image_url": ["url": .string(name)]]]]
        }
        let compacted = Agent.compactEarlierImages([withImage("a"), ["role": "assistant", "content": "ok"], withImage("b"), withImage("c")])
        XCTAssertEqual(compacted.map { Agent.hasImage($0) }, [false, false, false, true])
        XCTAssertEqual(compacted[0]["content"]?.arrayValue?[1]["text"]?.stringValue, Agent.removedImageNote)
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

    func testOneRetryForServerAndNetworkFailures() async throws {
        let recovered = Recorder([(503, [:]), (200, completion)])
        _ = try await OpenRouter(apiKey: "k", transport: recovered.transport).chat(ChatRequest(model: "m", messages: [], tools: []))
        XCTAssertEqual(recovered.requests.count, 2)
        let offline = Recorder([])
        do {
            _ = try await OpenRouter(apiKey: "k", transport: offline.transport).chat(ChatRequest(model: "m", messages: [], tools: []))
            XCTFail("expected an error")
        } catch let error as ModelError {
            XCTAssertEqual(error.kind, .network)
            XCTAssertEqual(offline.requests.count, 2)
        }
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
        XCTAssertTrue(text.contains("readonly filters:"))
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
