import Foundation
import XCTest

@testable import OscuruCore

/// A clock the connection watch reads and moves on with each look: one second a look, or a
/// longer jump where a test has the app suspended.
private final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time = Date(timeIntervalSince1970: 1_000_000)
    private var looks = 0
    /// Seconds to jump instead, at a given look.
    private let jumps: [Int: Double]

    init(jumps: [Int: Double] = [:]) {
        self.jumps = jumps
    }

    var now: Date { lock.withLock { time } }
    var count: Int { lock.withLock { looks } }

    func advance(_ seconds: Double) {
        lock.withLock {
            looks += 1
            time = time.addingTimeInterval(jumps[looks] ?? seconds)
        }
    }

    func watch(lastDisruption: @escaping @Sendable () -> Date? = { nil }) -> StreamWatch {
        StreamWatch(
            lastDisruption: lastDisruption, now: { self.now },
            sleep: { seconds in
                self.advance(seconds)
                await Task.yield()
            })
    }
}

/// A stream transport that answers with lines, optionally only once the clock has looked a
/// number of times (a model taking its time), or never (a dead connection).
private func streaming(status: Int = 200, _ lines: [String], after looks: Int = 0, clock: FakeClock? = nil, never: Bool = false, requests: Requests? = nil)
    -> HTTPStreamTransport
{
    { request, progress in
        requests?.add(request)
        progress()
        let stream = AsyncThrowingStream<String, Error> { continuation in
            let task = Task {
                if never {
                    while !Task.isCancelled { await Task.yield() }
                    return
                }
                while let clock, clock.count < looks, !Task.isCancelled { await Task.yield() }
                for line in lines { continuation.yield(line) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return HTTPStreamResponse(status: status, lines: stream)
    }
}

private final class Requests: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [HTTPRequest] = []
    var all: [HTTPRequest] { lock.withLock { list } }
    func add(_ request: HTTPRequest) { lock.withLock { list.append(request) } }
}

private func data(_ chunk: JSONValue) -> String { "data: \(chunk.text())" }

final class StreamingTests: XCTestCase {
    private let request = ChatRequest(model: "anthropic/claude-opus-5.5", messages: [["role": "user", "content": "hi"]], tools: [Prompt.tool], sessionID: "photo-1")

    /// An answer as Claude streams it through OpenRouter: thinking with its signature, words, a
    /// script in pieces, and the usage last.
    private var answer: [String] {
        [
            ": OPENROUTER PROCESSING",
            "",
            data(["id": "gen-1", "model": "anthropic/claude-opus-5.5", "choices": [["delta": ["role": "assistant", "content": ""]]]]),
            data(["choices": [["delta": ["reasoning": "Look ", "reasoning_details": [["type": "reasoning.text", "text": "Look ", "index": 0, "format": "anthropic-claude-v1"]]]]]]),
            data(["choices": [["delta": ["reasoning": "first.", "reasoning_details": [["type": "reasoning.text", "text": "first.", "index": 0]]]]]]),
            data(["choices": [["delta": ["reasoning_details": [["type": "reasoning.text", "signature": "sig-1", "index": 0]]]]]]),
            data(["choices": [["delta": ["content": "Working "]]]]),
            data(["choices": [["delta": ["content": "on it."]]]]),
            data(["choices": [["delta": ["tool_calls": [["index": 0, "id": "call-1", "type": "function", "function": ["name": "execute_edit_script", "arguments": "{\"co"]]]]]]]),
            data(["choices": [["delta": ["tool_calls": [["index": 0, "function": ["arguments": "de\":\"1\"}"]]]]]]]),
            ": OPENROUTER PROCESSING",
            data(["choices": [["delta": [:], "finish_reason": "tool_calls"]]]),
            data(["choices": [["delta": [:], "finish_reason": "tool_calls"]], "usage": ["prompt_tokens": 12000, "completion_tokens": 80, "cost": 0.0123]]),
            "data: [DONE]",
        ]
    }

    func testAStreamedAnswerIsPutBackTogetherAsItWouldHaveCome() async throws {
        let requests = Requests()
        let client = OpenRouter(apiKey: "k", transport: { _ in XCTFail("not streamed"); return HTTPResponse(status: 500, body: Data()) }, stream: streaming(answer, requests: requests))
        let response = try await client.chat(request)
        XCTAssertEqual(response.id, "gen-1")
        XCTAssertEqual(response.model, "anthropic/claude-opus-5.5")
        XCTAssertEqual(response.usage, Usage(promptTokens: 12000, completionTokens: 80, cost: 0.0123))
        let message = response.message
        XCTAssertEqual(message["role"], "assistant")
        XCTAssertEqual(message["content"], "Working on it.")
        XCTAssertEqual(message["reasoning"], "Look first.")
        XCTAssertEqual(message["reasoning_details"], [["type": "reasoning.text", "text": "Look first.", "signature": "sig-1", "index": 0, "format": "anthropic-claude-v1"]])
        let calls = Conversation(
            [TranscriptEntry(id: "a", date: Date(), body: .assistant(.init(message: Agent.normalized(message), model: response.model, usage: response.usage)))]
        ).pendingCalls
        XCTAssertEqual(calls, [ToolCall(id: "call-1", name: "execute_edit_script", arguments: "{\"code\":\"1\"}")])
        let body = try XCTUnwrap(JSONValue(text: String(decoding: requests.all[0].body ?? Data(), as: UTF8.self)))
        XCTAssertEqual(body["stream"], true)
        XCTAssertEqual(body["session_id"], "photo-1")
        XCTAssertEqual(requests.all[0].headers["Authorization"], "Bearer k")
    }

    func testEncryptedReasoningComesBackWholeAndWordsAlone() async throws {
        let lines = [
            data(["choices": [["delta": ["reasoning_details": [["type": "reasoning.encrypted", "data": "opaque==", "id": "r1", "index": 0]]]]]]),
            data(["choices": [["delta": ["content": "Done."], "finish_reason": "stop"]]]),
            "data: [DONE]",
        ]
        let response = try await OpenRouter(apiKey: "k", transport: { _ in HTTPResponse(status: 500, body: Data()) }, stream: streaming(lines)).chat(request)
        XCTAssertEqual(response.message["reasoning_details"], [["type": "reasoning.encrypted", "data": "opaque==", "id": "r1", "index": 0]])
        XCTAssertEqual(response.message["content"], "Done.")
        XCTAssertNil(response.message["tool_calls"])
        XCTAssertNil(response.usage)
    }

    func testErrorsBeforeAndDuringTheStreamAreClassed() async throws {
        func failure(_ transport: @escaping HTTPStreamTransport) async -> ModelError? {
            do {
                _ = try await OpenRouter(apiKey: "k", transport: { _ in HTTPResponse(status: 500, body: Data()) }, stream: transport).chat(request)
                return nil
            } catch {
                return error as? ModelError
            }
        }
        let refused = await failure(streaming(status: 402, ["{\"error\":{\"code\":402,\"message\":\"Insufficient credits\"}}"]))
        XCTAssertEqual(refused, ModelError(.payment, "Insufficient credits", status: 402))
        XCTAssertFalse(refused?.isTransient ?? true)

        let midway = await failure(
            streaming([
                data(["choices": [["delta": ["content": "Wor"]]]]),
                data(["error": ["code": 502, "message": "Provider disconnected unexpectedly"], "choices": [["delta": ["content": ""], "finish_reason": "error"]]]),
            ]))
        XCTAssertEqual(midway?.kind, .server)
        XCTAssertEqual(midway?.message, "Provider disconnected unexpectedly")
        XCTAssertTrue(midway?.isTransient ?? false)

        let cut = await failure(streaming([data(["choices": [["delta": ["content": "Wor"]]]])]))
        XCTAssertEqual(cut?.kind, .network, "a stream that ends before the answer does is a dropped connection")
        XCTAssertTrue(cut?.isTransient ?? false)

        let offline = await failure({ _, _ in throw URLError(.notConnectedToInternet) })
        XCTAssertEqual(offline?.kind, .network)
    }

    func testAConnectionThatSaysNothingAfterTheAppWasSuspendedIsGivenUpOnAndSentAgain() async throws {
        // The fifth look comes five minutes after the fourth: the app was suspended in between.
        let clock = FakeClock(jumps: [5: 300])
        let client = OpenRouter(apiKey: "k", transport: { _ in HTTPResponse(status: 500, body: Data()) }, stream: streaming([], clock: clock, never: true), watch: clock.watch())
        do {
            _ = try await client.chat(request)
            XCTFail("expected the dead connection to be noticed")
        } catch let error as ModelError {
            XCTAssertEqual(error, ModelError(.network, StreamWatch.quietMessage))
            XCTAssertTrue(error.isTransient)
            // Noticed once the grace after coming back ran out, not before.
            XCTAssertGreaterThan(clock.count, 5 + 20)
            XCTAssertLessThan(clock.count, 5 + 25)
        }
    }

    func testAModelThatThinksForLongIsNeverCutOff() async throws {
        // Ten minutes of nothing, but nothing happened to the app or the network: the answer is waited for.
        let clock = FakeClock()
        let client = OpenRouter(apiKey: "k", transport: { _ in HTTPResponse(status: 500, body: Data()) }, stream: streaming(answer, after: 600, clock: clock), watch: clock.watch())
        let response = try await client.chat(request)
        XCTAssertEqual(response.message["content"], "Working on it.")
        XCTAssertGreaterThanOrEqual(clock.count, 600)
    }

    func testAfterTheNetworkChangesAConnectionThatKeepsTalkingCarriesOn() async throws {
        // The network changed just after the request went out.
        let start = Date(timeIntervalSince1970: 1_000_000)
        let changed: @Sendable () -> Date? = { start.addingTimeInterval(3) }
        let alive = FakeClock()
        let lines = (0..<40).map { _ in ": OPENROUTER PROCESSING" } + answer
        let talking = OpenRouter(apiKey: "k", transport: { _ in HTTPResponse(status: 500, body: Data()) }, stream: streaming(lines, after: 10, clock: alive), watch: alive.watch(lastDisruption: changed))
        let response = try await talking.chat(request)
        XCTAssertEqual(response.message["content"], "Working on it.")

        let dead = FakeClock()
        let silent = OpenRouter(apiKey: "k", transport: { _ in HTTPResponse(status: 500, body: Data()) }, stream: streaming([], clock: dead, never: true), watch: dead.watch(lastDisruption: changed))
        do {
            _ = try await silent.chat(request)
            XCTFail("expected the dead connection to be noticed")
        } catch let error as ModelError {
            XCTAssertEqual(error.message, StreamWatch.quietMessage)
            XCTAssertLessThan(dead.count, 30)
        }
    }

    func testStoppingWhileStreamingIsACancellationNotAFailure() async throws {
        let clock = FakeClock()
        let client = OpenRouter(apiKey: "k", transport: { _ in HTTPResponse(status: 500, body: Data()) }, stream: streaming([], clock: clock, never: true), watch: clock.watch())
        let request = self.request
        let task = Task { [client, request] in try await client.chat(request) }
        while clock.count < 3 { await Task.yield() }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected a cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
    }
}
