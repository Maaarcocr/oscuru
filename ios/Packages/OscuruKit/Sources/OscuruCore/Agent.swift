import Foundation

/// A picture sent to the model, with the words that say what it shows.
public struct LabeledImage: Equatable, Sendable {
    public var label: String
    public var jpeg: Data

    public init(label: String, jpeg: Data) {
        self.label = label
        self.jpeg = jpeg
    }

}

/// What one tool call did, for the model: a JSON report and the pictures that go with it.
public struct ToolExecution: Sendable {
    public var payload: JSONValue
    public var images: [LabeledImage]
    /// The photo after the script, when it changed it.
    public var state: EditingState?

    public init(payload: JSONValue, images: [LabeledImage], state: EditingState? = nil) {
        self.payload = payload
        self.images = images
        self.state = state
    }
}

/// What the model is told about the photo when an instruction starts.
public struct AgentContext: Sendable {
    public var state: EditingState
    public var metadata: JSONValue
    public var statistics: JSONValue?
    public var styles: [String]

    public init(state: EditingState, metadata: JSONValue, statistics: JSONValue?, styles: [String]) {
        self.state = state
        self.metadata = metadata
        self.statistics = statistics
        self.styles = styles
    }

    var json: JSONValue {
        ["state": state.json, "metadata": metadata, "statistics": statistics ?? .null, "savedStyles": .array(styles.map { .string($0) })]
    }
}

/// The phone's side of the conversation: what the agent can learn about the photo and do to it.
public protocol AgentPort: Sendable {
    /// Runs one script. The arguments are whatever the model sent; checking them is the port's job.
    func execute(arguments: JSONValue) async -> ToolExecution
}

public enum AgentEvent: Sendable {
    /// A request is on its way to the model.
    case requesting
    /// A script is running.
    case running(call: String)
    /// A request failed in a way that usually passes; it is sent again after `delay` seconds.
    case retrying(attempt: Int, delay: Double, message: String)
    /// Older messages are being summarized to make room.
    case summarizing
}

/// How often and how patiently a failed request is tried again: after 2, 4 and 8 seconds.
public struct RetryPolicy: Sendable {
    public var attempts: Int
    public var baseDelay: Double
    public var maxDelay: Double

    public init(attempts: Int = 3, baseDelay: Double = 2, maxDelay: Double = 60) {
        self.attempts = attempts
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
    }

    public func delay(attempt: Int) -> Double { min(baseDelay * pow(2, Double(max(0, attempt - 1))), maxDelay) }
}

/// The assistant's loop. It reads the transcript, does the one thing the conversation asks for
/// next (ask the model, or run the script it asked for), writes down what happened, and goes
/// round again, until the model answers without a script. Every step is on disk before the next
/// begins, so the same loop that runs an instruction also picks up one the app was closed
/// during: it starts from whatever the transcript says.
///
/// Nothing here limits how long that takes or what it costs. It ends when the model answers,
/// when the person stops it (cancelling the task), or when a request fails for good.
public enum Agent {
    /// The words in a message, without its pictures.
    public static func text(of message: JSONValue) -> String {
        if let text = message["content"]?.stringValue { return text }
        return (message["content"]?.arrayValue ?? []).compactMap { $0["type"] == "text" ? $0["text"]?.stringValue : nil }.joined()
    }

    /// The record for words that start a run: they go to the model with the photo's context and
    /// its pictures, so it starts from what the person sees.
    public static func instruction(_ text: String, context: AgentContext, pictures: [PictureRef]) -> TranscriptEntry.User {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let preface = pictures.isEmpty ? "\n\n[No picture could be rendered. Work from the statistics, and say so in your note.]" : ""
        return TranscriptEntry.User(text: words, prompt: "\(words)\n\n[Photo context]\n\(context.json.text())\(preface)", pictures: pictures)
    }

    /// The record for words sent while the assistant works: they join between two steps.
    public static func steer(_ text: String) -> TranscriptEntry.User {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return TranscriptEntry.User(text: words, prompt: words, queued: true)
    }

    /// Works on the conversation until there is nothing left to do. Cancelling the task stops it,
    /// and the stop is written down. Throws only when the transcript cannot be written.
    public static func run(
        transcript: Transcript, client: ModelClient, model: String, contextWindow: Int?, port: AgentPort, sessionID: String,
        retry: RetryPolicy = RetryPolicy(), sleep: @escaping @Sendable (Double) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
        onEvent: @escaping @Sendable (AgentEvent) async -> Void
    ) async throws {
        var attempt = 0
        var recoveredOverflow = false
        while true {
            let conversation = Conversation(await transcript.entries)
            if Task.isCancelled {
                if conversation.wasInterrupted { try await transcript.append(.stop) }
                return
            }
            guard conversation.halt == nil else { return }
            // Messages sent meanwhile join between steps, never between a script and its report.
            if conversation.pendingCalls.isEmpty, !conversation.queued.isEmpty {
                try await transcript.append(.placed(conversation.queued.map(\.id)))
                continue
            }
            switch conversation.next {
            case .nothing:
                return

            case .tools(let calls):
                let call = calls[0]
                await onEvent(.running(call: call.id))
                let execution = await execute(call, port: port)
                var pictures: [PictureRef] = []
                for image in execution.images { pictures.append(try await transcript.store(image)) }
                try await transcript.append(.toolResult(.init(call: call.id, payload: execution.payload, pictures: pictures, state: execution.state)))

            case .answer:
                if let window = contextWindow, let used = conversation.lastPromptTokens, used > window - Compaction.reserveTokens {
                    await onEvent(.summarizing)
                    // A summary that fails here is not the end: the request may still fit.
                    if (try? await summarize(conversation, transcript: transcript, client: client, model: model, sessionID: sessionID)) == true { continue }
                    if Task.isCancelled { continue }
                }
                await onEvent(.requesting)
                let request = ChatRequest(
                    model: model, messages: conversation.messages(system: Prompt.system, picture: transcript.picture), tools: [Prompt.tool], sessionID: sessionID)
                do {
                    let response = try await client.chat(request)
                    attempt = 0
                    // Kept even after a stop: it was paid for, and Continue runs its scripts.
                    try await transcript.append(.assistant(.init(message: normalized(response.message), model: response.model, usage: response.usage)))
                } catch {
                    if Task.isCancelled || error is CancellationError { continue }
                    let failure = error as? ModelError ?? ModelError(.network, String(describing: error))
                    if failure.isContextOverflow, !recoveredOverflow {
                        recoveredOverflow = true
                        await onEvent(.summarizing)
                        if (try? await summarize(conversation, transcript: transcript, client: client, model: model, sessionID: sessionID)) == true { continue }
                        if Task.isCancelled { continue }
                    }
                    if failure.isTransient, attempt < retry.attempts {
                        attempt += 1
                        let delay = retry.delay(attempt: attempt)
                        try await transcript.append(.failure(.init(kind: failure.kind, message: failure.message, status: failure.status, retrying: true, delay: delay)))
                        await onEvent(.retrying(attempt: attempt, delay: delay, message: failure.message))
                        try? await sleep(delay)
                        continue
                    }
                    try await transcript.append(.failure(.init(kind: failure.kind, message: failure.message, status: failure.status, retrying: false)))
                    return
                }
            }
        }
    }

    /// Summarizes the older part of the conversation, if there is one, and adds the summary.
    public static func summarize(_ conversation: Conversation, transcript: Transcript, client: ModelClient, model: String, sessionID: String?) async throws -> Bool {
        guard let cut = Compaction.cut(conversation) else { return false }
        let response = try await client.chat(Compaction.request(conversation, cut: cut.index, model: model, sessionID: sessionID))
        let summary = text(of: response.message).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else { throw ModelError(.invalidResponse, "The model wrote an empty summary") }
        try await transcript.append(
            .compaction(.init(summary: summary, firstKept: conversation.placed[cut.index].id, tokensBefore: cut.tokensBefore, usage: response.usage, model: response.model)))
        return true
    }

    /// The assistant message as it goes back to the model: exactly as it came, in the shape the
    /// API expects. Some providers attach reasoning that must return unchanged with the reports.
    static func normalized(_ message: JSONValue) -> JSONValue {
        var assistant = message.objectValue ?? [:]
        assistant["role"] = "assistant"
        if assistant["content"] == nil { assistant["content"] = .null }
        if (assistant["tool_calls"]?.arrayValue ?? []).isEmpty { assistant["tool_calls"] = nil }
        return .object(assistant)
    }

    static func execute(_ call: ToolCall, port: AgentPort) async -> ToolExecution {
        func invalid(_ message: String) -> ToolExecution {
            ToolExecution(payload: ["status": "invalid_request", "applied": false, "error": ["message": .string(message)]], images: [])
        }
        guard call.name == Prompt.toolName else { return invalid("Unknown tool \"\(call.name)\". The only tool is \(Prompt.toolName).") }
        guard let arguments = JSONValue(text: call.arguments), arguments.objectValue != nil else {
            return invalid("The tool arguments were not a valid JSON object.")
        }
        return await port.execute(arguments: arguments)
    }
}
