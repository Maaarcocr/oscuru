import Foundation

/// A picture sent to the model, with the words that say what it shows.
public struct LabeledImage: Equatable, Sendable {
    public var label: String
    public var jpeg: Data

    public init(label: String, jpeg: Data) {
        self.label = label
        self.jpeg = jpeg
    }

    var parts: [JSONValue] {
        [
            ["type": "text", "text": .string(label)],
            ["type": "image_url", "image_url": ["url": .string("data:image/jpeg;base64,\(jpeg.base64EncodedString())")]],
        ]
    }
}

/// What one tool call did, for the model: a JSON report and the pictures that go with it.
public struct ToolExecution: Sendable {
    public var payload: JSONValue
    public var images: [LabeledImage]

    public init(payload: JSONValue, images: [LabeledImage]) {
        self.payload = payload
        self.images = images
    }
}

public struct AgentContext: Sendable {
    public var sessionID: String
    public var revision: Int
    public var state: EditingState
    public var metadata: JSONValue
    public var statistics: JSONValue?
    public var filters: [String]

    public init(sessionID: String, revision: Int, state: EditingState, metadata: JSONValue, statistics: JSONValue?, filters: [String]) {
        self.sessionID = sessionID
        self.revision = revision
        self.state = state
        self.metadata = metadata
        self.statistics = statistics
        self.filters = filters
    }

    var json: JSONValue {
        [
            "sessionId": .string(sessionID),
            "revision": .number(Double(revision)),
            "state": state.json,
            "metadata": metadata,
            "statistics": statistics ?? .null,
            "savedFilters": .array(filters.map { .string($0) }),
        ]
    }
}

/// The phone's side of the conversation: what the agent can learn about the photo and do to it.
public protocol AgentPort: Sendable {
    /// The photo as it is now.
    func context() async -> AgentContext
    /// The pictures that open an instruction: the photo as it is, and the original when it has been edited.
    func openingImages() async -> [LabeledImage]
    /// Runs one script. The arguments are whatever the model sent; checking them is the port's job.
    func execute(arguments: JSONValue) async -> ToolExecution
}

public enum AgentEvent: Sendable {
    /// A request is on its way to the model.
    case thinking
    /// Something the model said, alongside tool calls or as its closing note.
    case text(String)
    case scriptStarted(id: String, code: String)
    case scriptFinished(id: String, payload: JSONValue)
    case usage(Usage, model: String)
}

public struct AgentTurn: Sendable {
    public enum Stop: Equatable, Sendable {
        case done
        case cancelled
    }

    public var stop: Stop
    /// The assistant's closing note, when it wrote one.
    public var text: String
    public var scripts: Int
    /// The conversation to continue from. After a cancelled turn this is the conversation as it was before.
    public var conversation: [JSONValue]
}

public enum Agent {
    static let removedImageNote = "[A picture from an earlier request was here. It was removed to save space; later pictures show the photo as it is now.]"

    /// The words in a message, without its pictures.
    public static func text(of message: JSONValue) -> String {
        if let text = message["content"]?.stringValue { return text }
        return (message["content"]?.arrayValue ?? []).compactMap { $0["type"] == "text" ? $0["text"]?.stringValue : nil }.joined()
    }

    static func hasImage(_ message: JSONValue) -> Bool {
        (message["content"]?.arrayValue ?? []).contains { $0["type"] == "image_url" }
    }

    /// Before a new instruction: drops the pictures of earlier ones, except the latest message that
    /// has any. Within an instruction nothing is dropped, so the model can compare every step.
    public static func compactEarlierImages(_ messages: [JSONValue]) -> [JSONValue] {
        var result = messages
        var kept = false
        for index in result.indices.reversed() where hasImage(result[index]) {
            if !kept {
                kept = true
                continue
            }
            guard var members = result[index].objectValue, let parts = members["content"]?.arrayValue else { continue }
            members["content"] = .array(parts.map { $0["type"] == "image_url" ? ["type": "text", "text": .string(removedImageNote)] : $0 })
            result[index] = .object(members)
        }
        return result
    }

    static func userMessage(text: String, images: [LabeledImage]) -> JSONValue {
        var parts: [JSONValue] = [["type": "text", "text": .string(text)]]
        for image in images { parts += image.parts }
        return ["role": "user", "content": .array(parts)]
    }

    /// Carries out one instruction: any number of model requests and scripts, until the model
    /// answers without calling the tool. Nothing here limits how long that takes or what it costs;
    /// cancelling the task is the only way it stops early.
    ///
    /// Throws `ModelError` when the model cannot be reached or refuses. The conversation passed in
    /// is not modified; the one to continue from is in the result.
    public static func run(
        client: ModelClient, model: String, port: AgentPort, conversation: [JSONValue], instruction: String,
        onEvent: @escaping @Sendable (AgentEvent) async -> Void
    ) async throws -> AgentTurn {
        var messages = compactEarlierImages(conversation)
        var scripts = 0
        var lastText = ""
        func cancelled() -> AgentTurn {
            // A half-finished exchange would confuse the next request, so the conversation stays as it was.
            AgentTurn(stop: .cancelled, text: lastText, scripts: scripts, conversation: conversation)
        }

        do {
            if messages.isEmpty { messages.append(["role": "system", "content": .string(Prompt.system)]) }
            let context = await port.context()
            let opening = await port.openingImages()
            if Task.isCancelled { return cancelled() }
            let preface = opening.isEmpty ? "\n\n[No picture could be rendered. Work from the statistics, and say so in your note.]" : ""
            messages.append(
                userMessage(text: "\(instruction.trimmingCharacters(in: .whitespacesAndNewlines))\n\n[Photo context]\n\(context.json.text())\(preface)", images: opening))

            while true {
                await onEvent(.thinking)
                let response = try await client.chat(ChatRequest(model: model, messages: messages, tools: [Prompt.tool], sessionID: context.sessionID))
                if let usage = response.usage { await onEvent(.usage(usage, model: response.model)) }
                if Task.isCancelled { return cancelled() }

                // The assistant message goes back exactly as it came: some providers attach reasoning
                // details that must return unchanged with the tool results.
                var assistant = response.message.objectValue ?? [:]
                assistant["role"] = "assistant"
                if assistant["content"] == nil { assistant["content"] = .null }
                let calls = assistant["tool_calls"]?.arrayValue ?? []
                if calls.isEmpty { assistant["tool_calls"] = nil }
                messages.append(.object(assistant))

                let said = text(of: .object(assistant)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !said.isEmpty {
                    lastText = said
                    await onEvent(.text(said))
                }
                if calls.isEmpty {
                    return AgentTurn(stop: .done, text: lastText, scripts: scripts, conversation: messages)
                }

                var images: [LabeledImage] = []
                for call in calls {
                    let id = call["id"]?.stringValue ?? ""
                    let name = call["function"]?["name"]?.stringValue ?? ""
                    func reply(_ payload: JSONValue) {
                        messages.append(["role": "tool", "tool_call_id": .string(id), "content": .string(payload.text())])
                    }
                    guard name == Prompt.toolName else {
                        reply(["status": "invalid_request", "applied": false, "error": ["message": .string("Unknown tool \"\(name)\". The only tool is \(Prompt.toolName).")]])
                        continue
                    }
                    guard let arguments = JSONValue(text: call["function"]?["arguments"]?.stringValue ?? "{}"), arguments.objectValue != nil else {
                        reply(["status": "invalid_request", "applied": false, "error": ["message": "The tool arguments were not a valid JSON object."]])
                        continue
                    }
                    scripts += 1
                    await onEvent(.scriptStarted(id: id, code: arguments["code"]?.stringValue ?? ""))
                    let execution = await port.execute(arguments: arguments)
                    await onEvent(.scriptFinished(id: id, payload: execution.payload))
                    reply(execution.payload)
                    images += execution.images
                    if Task.isCancelled { return cancelled() }
                }
                if !images.isEmpty {
                    messages.append(userMessage(text: "[Pictures from the phone for the script above.]", images: images))
                }
            }
        } catch is CancellationError {
            return cancelled()
        } catch {
            if Task.isCancelled { return cancelled() }
            throw error
        }
    }
}
