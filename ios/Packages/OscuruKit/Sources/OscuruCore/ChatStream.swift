import Foundation

/// An answer read as OpenRouter streams it (server-sent events, one `data:` line per chunk), put
/// back together into the message a non-streamed answer would have been: its words, its
/// reasoning (which has to go back to the model unchanged), its tool calls, and the usage that
/// comes in a last chunk of its own.
struct ChatStream {
    enum Line: Equatable {
        /// Keep reading.
        case more
        /// The stream said it is over.
        case done
    }

    var id = ""
    var model: String
    var content = ""
    var hasContent = false
    var reasoning = ""
    var refusal = ""
    /// Reasoning details in the order they first came, merged by their index.
    var details: [[String: JSONValue]] = []
    var detailPositions: [Int: Int] = [:]
    /// Tool calls by their index: id, name, and arguments as written so far.
    var calls: [Int: (id: String, name: String, arguments: String)] = [:]
    var usage: Usage?
    var finishReason: String?
    /// Whether the stream said it is over.
    var ended = false

    init(model: String) {
        self.model = model
    }

    /// Reads one line of the stream. Comments (OpenRouter's keep-alives) and blank lines are
    /// skipped; an error the stream reports is thrown.
    mutating func read(_ line: String) throws -> Line {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let payload: Substring
        if trimmed.hasPrefix("data:") {
            payload = trimmed.dropFirst(5).drop { $0 == " " }
        } else if trimmed.hasPrefix("{") {
            // Not an event: an error some servers send as a plain object.
            payload = Substring(trimmed)
        } else {
            return .more
        }
        if payload == "[DONE]" {
            ended = true
            return .done
        }
        guard let chunk = JSONValue(text: String(payload)), chunk.objectValue != nil else { return .more }
        try add(chunk)
        return .more
    }

    mutating func add(_ chunk: JSONValue) throws {
        if let error = chunk["error"], error.objectValue != nil || error.stringValue != nil {
            let status = Int(error["code"]?.doubleValue ?? 500)
            let message = error["message"]?.stringValue ?? error.stringValue ?? "The model's provider reported an error"
            throw ModelError(ModelError.kind(forStatus: status), message, status: status)
        }
        if let id = chunk["id"]?.stringValue, !id.isEmpty { self.id = id }
        if let model = chunk["model"]?.stringValue, !model.isEmpty { self.model = model }
        if let reported = chunk["usage"], reported.objectValue != nil {
            usage = Usage(
                promptTokens: Int(reported["prompt_tokens"]?.doubleValue ?? 0),
                completionTokens: Int(reported["completion_tokens"]?.doubleValue ?? 0),
                cost: reported["cost"]?.doubleValue)
        }
        guard let choice = chunk["choices"]?.arrayValue?.first else { return }
        if let reason = choice["finish_reason"]?.stringValue {
            if reason == "error" { throw ModelError(.server, "The model's provider stopped the answer with an error") }
            finishReason = reason
        }
        let delta = choice["delta"] ?? choice["message"] ?? .null
        if let text = delta["content"]?.stringValue {
            content += text
            hasContent = true
        }
        if let text = delta["reasoning"]?.stringValue { reasoning += text }
        if let text = delta["refusal"]?.stringValue { refusal += text }
        for detail in delta["reasoning_details"]?.arrayValue ?? [] {
            guard let members = detail.objectValue else { continue }
            merge(members)
        }
        for call in delta["tool_calls"]?.arrayValue ?? [] {
            let index = Int(call["index"]?.doubleValue ?? Double(calls.count))
            var current = calls[index] ?? (id: "", name: "", arguments: "")
            if let id = call["id"]?.stringValue, !id.isEmpty { current.id = id }
            if let name = call["function"]?["name"]?.stringValue, !name.isEmpty { current.name = current.name.isEmpty ? name : current.name }
            if let arguments = call["function"]?["arguments"]?.stringValue { current.arguments += arguments }
            calls[index] = current
        }
    }

    /// A piece of reasoning: its text and summary come in parts and are joined; everything else
    /// (a signature, encrypted data, its id) comes whole and is kept as it came.
    mutating func merge(_ members: [String: JSONValue]) {
        guard let index = members["index"]?.doubleValue.map({ Int($0) }), let position = detailPositions[index],
            details[position]["type"] == members["type"]
        else {
            if let index = members["index"]?.doubleValue.map({ Int($0) }) { detailPositions[index] = details.count }
            details.append(members)
            return
        }
        var current = details[position]
        for (key, value) in members {
            switch (key, current[key]?.stringValue, value.stringValue) {
            case ("text", let old?, let new?), ("summary", let old?, let new?):
                current[key] = .string(old + new)
            default:
                if value != .null || current[key] == nil { current[key] = value }
            }
        }
        details[position] = current
    }

    /// Whether what came is a whole answer: the stream said it is over, or why the answer finished.
    var isComplete: Bool { ended || finishReason != nil }

    /// The answer as a non-streamed response would have carried it.
    var message: JSONValue {
        var message: [String: JSONValue] = ["role": "assistant", "content": hasContent ? .string(content) : .null]
        if !reasoning.isEmpty { message["reasoning"] = .string(reasoning) }
        if !refusal.isEmpty { message["refusal"] = .string(refusal) }
        if !details.isEmpty { message["reasoning_details"] = .array(details.map { .object($0) }) }
        if !calls.isEmpty {
            message["tool_calls"] = .array(
                calls.keys.sorted().compactMap { index in
                    guard let call = calls[index] else { return nil }
                    return [
                        "id": .string(call.id), "type": "function", "index": .number(Double(index)),
                        "function": ["name": .string(call.name), "arguments": .string(call.arguments)],
                    ]
                })
        }
        return .object(message)
    }

    var response: ChatResponse { ChatResponse(id: id, model: model, message: message, usage: usage) }
}

extension OpenRouter {
    /// Sends a request with the answer streamed, and puts the answer together as it comes. While
    /// it waits, the watch looks out for a connection that died without saying so.
    func streamed(_ request: ChatRequest, _ stream: @escaping HTTPStreamTransport) async throws -> ChatResponse {
        var body = request.json.objectValue ?? [:]
        body["stream"] = true
        let http = HTTPRequest(method: "POST", url: OpenRouter.base + "/chat/completions", headers: headers, body: Data(JSONValue.object(body).text().utf8))
        let watch = self.watch
        let activity = StreamWatch.Activity(watch.now())
        let model = request.model
        do {
            return try await withThrowingTaskGroup(of: ChatResponse?.self) { group in
                group.addTask {
                    let response = try await stream(http) { activity.touch(watch.now()) }
                    activity.touch(watch.now())
                    guard (200..<300).contains(response.status) else {
                        var text = ""
                        for try await line in response.lines {
                            activity.touch(watch.now())
                            text += line + "\n"
                        }
                        let json = JSONValue(text: text) ?? .null
                        let message = json["error"]?["message"]?.stringValue ?? "OpenRouter answered \(response.status)"
                        throw ModelError(ModelError.kind(forStatus: response.status), message, status: response.status)
                    }
                    var answer = ChatStream(model: model)
                    for try await line in response.lines {
                        activity.touch(watch.now())
                        if try answer.read(line) == .done { break }
                    }
                    guard answer.isComplete else { throw ModelError(.network, "The stream was interrupted before the answer was complete") }
                    return answer.response
                }
                group.addTask {
                    try await watch.watch(activity)
                    return nil
                }
                defer { group.cancelAll() }
                while let result = try await group.next() {
                    if let result { return result }
                }
                throw ModelError(.invalidResponse, "OpenRouter returned no message")
            }
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            if let error = error as? ModelError { throw error }
            throw ModelError(.network, error.localizedDescription)
        }
    }
}
