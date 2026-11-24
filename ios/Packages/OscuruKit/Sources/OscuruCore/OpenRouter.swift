import Foundation

/// A plain HTTP exchange. The app supplies one backed by URLSession; tests supply their own.
public struct HTTPRequest: Sendable, Equatable {
    public var method: String
    public var url: String
    public var headers: [String: String]
    public var body: Data?

    public init(method: String, url: String, headers: [String: String] = [:], body: Data? = nil) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }
}

public struct HTTPResponse: Sendable {
    public var status: Int
    public var body: Data

    public init(status: Int, body: Data) {
        self.status = status
        self.body = body
    }
}

public typealias HTTPTransport = @Sendable (HTTPRequest) async throws -> HTTPResponse

public struct ModelError: Error, Equatable, Sendable {
    public enum Kind: String, Codable, Equatable, Sendable {
        case unauthorized, payment, rateLimit, badRequest, server, network, invalidResponse
    }

    public let kind: Kind
    public let message: String
    public let status: Int?

    public init(_ kind: Kind, _ message: String, status: Int? = nil) {
        self.kind = kind
        self.message = message
        self.status = status
    }

    static func kind(forStatus status: Int) -> Kind {
        switch status {
        case 401, 403: return .unauthorized
        case 402: return .payment
        case 429: return .rateLimit
        case 500...: return .server
        default: return .badRequest
        }
    }
}

extension ModelError {
    /// Whether the request was too long for the model: the conversation needs a summary.
    public var isContextOverflow: Bool { ModelError.matches(message, ModelError.overflowPatterns) }

    /// Whether the failure usually passes by itself, so the same request is worth sending again:
    /// a dropped connection, a busy or failing server, a rate limit. A bad key, no credit or a
    /// request the model refuses are not.
    public var isTransient: Bool {
        guard !isContextOverflow else { return false }
        switch kind {
        case .network, .server, .rateLimit, .invalidResponse: return true
        case .unauthorized, .payment, .badRequest: return ModelError.matches(message, ModelError.transientPatterns)
        }
    }

    static func matches(_ text: String, _ patterns: [String]) -> Bool {
        patterns.contains { text.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }
    }

    // After pi's lists of provider wording (packages/ai/src/utils/retry.ts and overflow.ts).
    static let transientPatterns = [
        "overloaded", "server_busy", "currently experiencing high demand", "at capacity", "rate.?limit", "too many requests",
        "(^|[^a-z0-9])(429|500|502|503|504|520|524|525)([^a-z0-9]|$)", "temporarily unavailable", "service.?unavailable",
        "provider returned error", "upstream", "internal.?error", "server.?error", "connection", "network", "timed? ?out", "socket",
        "stream was interrupted",
    ]

    static let overflowPatterns = [
        "prompt (is )?too long", "request_too_large", "exceeds the context window", "maximum context length", "context window exceeded",
        "input token count.*exceeds the maximum", "context[_ ]length[_ ]exceeded", "too many tokens", "token limit exceeded",
        "longer than the model'?s context length", "reduce the length of the messages",
    ]
}

public struct Usage: Codable, Equatable, Sendable {
    public var promptTokens: Int
    public var completionTokens: Int
    /// What OpenRouter charged for the request, in US dollars of credit, when it said.
    public var cost: Double?

    public init(promptTokens: Int, completionTokens: Int, cost: Double?) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.cost = cost
    }
}

public struct ChatRequest: Sendable {
    public var model: String
    public var messages: [JSONValue]
    public var tools: [JSONValue]
    /// Lets one conversation stay on one provider so prompt caching keeps working.
    public var sessionID: String?

    public init(model: String, messages: [JSONValue], tools: [JSONValue], sessionID: String? = nil) {
        self.model = model
        self.messages = messages
        self.tools = tools
        self.sessionID = sessionID
    }

    /// The request body. Nothing here caps the answer: no token limit, no step limit.
    public var json: JSONValue {
        var body: [String: JSONValue] = [
            "model": .string(model),
            "messages": .array(messages),
        ]
        if !tools.isEmpty {
            body["tools"] = .array(tools)
            body["tool_choice"] = "auto"
            body["parallel_tool_calls"] = false
        }
        if let sessionID { body["session_id"] = .string(sessionID) }
        // Anthropic models cache the prompt only when asked to.
        if model.hasPrefix("anthropic/") { body["cache_control"] = ["type": "ephemeral"] }
        return .object(body)
    }
}

public struct ChatResponse: Sendable {
    public var id: String
    public var model: String
    /// The assistant message exactly as returned, so anything the provider needs sent back survives.
    public var message: JSONValue
    public var usage: Usage?

    public init(id: String, model: String, message: JSONValue, usage: Usage?) {
        self.id = id
        self.model = model
        self.message = message
        self.usage = usage
    }
}

/// The only thing the agent needs from a model provider. Swapping the provider is a new conformance.
public protocol ModelClient: Sendable {
    func chat(_ request: ChatRequest) async throws -> ChatResponse
}

public struct KeyInfo: Equatable, Sendable {
    public var label: String
    /// Credits used by this key, in US dollars.
    public var usage: Double
    /// The key's own spending cap on OpenRouter's side, if the person set one there.
    public var limit: Double?
    public var limitRemaining: Double?
}

public struct ModelInfo: Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    /// US dollars per million tokens.
    public var promptPrice: Double
    public var completionPrice: Double
    /// How many tokens a request can hold, when OpenRouter says.
    public var contextLength: Int?

    public init(id: String, name: String, promptPrice: Double, completionPrice: Double, contextLength: Int? = nil) {
        self.id = id
        self.name = name
        self.promptPrice = promptPrice
        self.completionPrice = completionPrice
        self.contextLength = contextLength
    }
}

/// OpenRouter's HTTP API: the only place the app talks to a model.
public struct OpenRouter: ModelClient {
    public static let base = "https://openrouter.ai/api/v1"
    public static let authPage = "https://openrouter.ai/auth"

    /// Shown on OpenRouter's side as the app that made the request.
    static let appHeaders = ["HTTP-Referer": "https://github.com/Maaarcocr/oscuru", "X-OpenRouter-Title": "Oscuru", "X-Title": "Oscuru"]

    let apiKey: String?
    let transport: HTTPTransport

    public init(apiKey: String?, transport: @escaping HTTPTransport) {
        self.apiKey = apiKey
        self.transport = transport
    }

    func send(_ method: String, _ path: String, body: JSONValue? = nil) async throws -> JSONValue {
        var headers = OpenRouter.appHeaders
        headers["Content-Type"] = "application/json"
        if let apiKey { headers["Authorization"] = "Bearer \(apiKey)" }
        let request = HTTPRequest(method: method, url: OpenRouter.base + path, headers: headers, body: body.map { Data($0.text().utf8) })
        let response: HTTPResponse
        do {
            response = try await transport(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ModelError {
            throw error
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw ModelError(.network, error.localizedDescription)
        }
        let json = (try? JSONDecoder().decode(JSONValue.self, from: response.body)) ?? .null
        let reported = json["error"]?["message"]?.stringValue
        guard (200..<300).contains(response.status) else {
            throw ModelError(ModelError.kind(forStatus: response.status), reported ?? "OpenRouter answered \(response.status)", status: response.status)
        }
        // OpenRouter can also report a provider error inside a 200 response.
        if json["error"] != nil, json["choices"] == nil, json["data"] == nil, json["key"] == nil {
            let status = Int(json["error"]?["code"]?.doubleValue ?? 500)
            throw ModelError(ModelError.kind(forStatus: status), reported ?? "OpenRouter reported an error", status: status)
        }
        return json
    }

    public func chat(_ request: ChatRequest) async throws -> ChatResponse {
        // Failures are not retried here: the agent's loop tries again, and says so on screen.
        let json = try await send("POST", "/chat/completions", body: request.json)
        guard let message = json["choices"]?.arrayValue?.first?["message"], message.objectValue != nil else {
            throw ModelError(.invalidResponse, "OpenRouter returned no message")
        }
        var usage: Usage?
        if let reported = json["usage"], reported.objectValue != nil {
            usage = Usage(
                promptTokens: Int(reported["prompt_tokens"]?.doubleValue ?? 0),
                completionTokens: Int(reported["completion_tokens"]?.doubleValue ?? 0),
                cost: reported["cost"]?.doubleValue)
        }
        return ChatResponse(
            id: json["id"]?.stringValue ?? "", model: json["model"]?.stringValue ?? request.model, message: message, usage: usage)
    }

    /// What OpenRouter knows about the key: also the way to check that a key works.
    public func keyInfo() async throws -> KeyInfo {
        let data = try await send("GET", "/key")["data"] ?? .null
        return KeyInfo(
            label: data["label"]?.stringValue ?? "", usage: data["usage"]?.doubleValue ?? 0, limit: data["limit"]?.doubleValue,
            limitRemaining: data["limit_remaining"]?.doubleValue)
    }

    /// Models that can do the job: they accept images and can call tools.
    public func editingModels() async throws -> [ModelInfo] {
        let list = try await send("GET", "/models?input_modalities=image&supported_parameters=tools")["data"]?.arrayValue ?? []
        return list.compactMap { entry in
            guard let id = entry["id"]?.stringValue, !id.hasSuffix(":batch"), !id.hasPrefix("~") else { return nil }
            let inputs = entry["architecture"]?["input_modalities"]?.arrayValue ?? []
            let parameters = entry["supported_parameters"]?.arrayValue ?? []
            guard inputs.contains("image"), parameters.contains("tools") else { return nil }
            guard let prompt = Double(entry["pricing"]?["prompt"]?.stringValue ?? ""), let completion = Double(entry["pricing"]?["completion"]?.stringValue ?? ""),
                prompt >= 0, completion >= 0
            else { return nil }
            return ModelInfo(
                id: id, name: entry["name"]?.stringValue ?? id, promptPrice: prompt * 1e6, completionPrice: completion * 1e6,
                contextLength: entry["context_length"]?.doubleValue.map { Int($0) })
        }
    }

    /// Trades the code from the sign-in page for the person's own API key.
    public func exchange(code: String, verifier: String) async throws -> (key: String, userID: String?) {
        let json = try await send("POST", "/auth/keys", body: ["code": .string(code), "code_verifier": .string(verifier), "code_challenge_method": "S256"])
        guard let key = json["key"]?.stringValue, !key.isEmpty else { throw ModelError(.invalidResponse, "OpenRouter returned no key") }
        return (key, json["user_id"]?.stringValue)
    }

    /// The address of OpenRouter's sign-in page for the PKCE flow. Without a callback, OpenRouter
    /// shows the code for the person to copy instead of redirecting.
    public static func signInURL(codeChallenge: String, callback: String?) -> String {
        var query: [(String, String)] = []
        if let callback { query.append(("callback_url", callback)) }
        query.append(("code_challenge", codeChallenge))
        query.append(("code_challenge_method", "S256"))
        query.append(("key_label", "Oscuru"))
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let text = query.map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.1)" }.joined(separator: "&")
        return "\(authPage)?\(text)"
    }

    /// What a request cost: what OpenRouter charged when it said, otherwise the tokens priced from the model list.
    public static func cost(of usage: Usage, model: ModelInfo?) -> Double {
        if let cost = usage.cost, cost.isFinite { return cost }
        guard let model else { return 0 }
        return (Double(usage.promptTokens) * model.promptPrice + Double(usage.completionTokens) * model.completionPrice) / 1e6
    }
}
