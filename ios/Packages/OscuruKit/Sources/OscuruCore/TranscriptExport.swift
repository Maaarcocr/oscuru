import Foundation

/// Every photo's conversation in one document, to read outside the app: what was said and done,
/// and how long each step took, worked out from when its record was written. A request's time is
/// the model's (and the connection's); a script's time is the phone's. For each photo: a summary,
/// its steps in order (one line each), and its records as the transcript keeps them. The pictures
/// are not in it.
public enum TranscriptExport {
    public struct Photo: Sendable {
        public var id: String
        public var name: String
        public var entries: [TranscriptEntry]

        public init(id: String, name: String, entries: [TranscriptEntry]) {
            self.id = id
            self.name = name
            self.entries = entries
        }
    }

    /// One thing that happened in a conversation.
    public struct Step: Equatable, Sendable {
        public var at: Date
        /// "message", "request", "script", "failure", "summary", "stop", "resume", "edit" or "imported".
        public var kind: String
        /// How long it took: the time since the record before it (less the wait before a failed
        /// request was tried again). Nil for what takes no time (a message, a stop).
        public var seconds: Double?
        /// Of a script's time, the script itself as it reported; the rest is measuring the photo
        /// and making the pictures that go with the report.
        public var scriptSeconds: Double?
        /// The person's words, the start of the script, the answer or the failure.
        public var note = ""
        public var model: String?
        public var usage: Usage?
        /// Seconds waited before trying a failed request again.
        public var delay: Double?
    }

    /// Where the time of a conversation went, in seconds.
    public struct Summary: Equatable, Sendable {
        public var requests = 0
        public var scripts = 0
        public var failures = 0
        /// Requests: sending them (the pictures are most of what is sent) and the model's answer.
        public var model = 0.0
        /// The phone's own work: the scripts, and what goes with their reports.
        public var phone = 0.0
        /// Of the phone's work, the scripts themselves.
        public var script = 0.0
        /// Requests that failed, and the waits before trying again.
        public var retries = 0.0
        public var promptTokens = 0
        public var completionTokens = 0
        public var cost = 0.0

        public init() {}

        public mutating func add(_ other: Summary) {
            requests += other.requests
            scripts += other.scripts
            failures += other.failures
            model += other.model
            phone += other.phone
            script += other.script
            retries += other.retries
            promptTokens += other.promptTokens
            completionTokens += other.completionTokens
            cost += other.cost
        }

        public var json: JSONValue {
            func rounded(_ value: Double) -> JSONValue { .number((value * 10).rounded() / 10) }
            return [
                "requests": .number(Double(requests)),
                "scripts": .number(Double(scripts)),
                "failures": .number(Double(failures)),
                "seconds": ["model": rounded(model), "phone": rounded(phone), "phoneScripts": rounded(script), "retries": rounded(retries)],
                "promptTokens": .number(Double(promptTokens)),
                "completionTokens": .number(Double(completionTokens)),
                "cost": .number((cost * 10000).rounded() / 10000),
            ]
        }
    }

    /// What the document says of itself, for whoever reads it.
    static let about = """
        Oscuru's conversations with the assistant, one entry per photo. Times are in seconds, worked out from when each record was written: a step took the time since the record before it, so time the app spent suspended in the background counts. \
        In each summary, seconds.model is the requests to the model (sending them, pictures and all, and waiting for the answer), seconds.phone is the phone's own work (running the scripts, then measuring the photo and making the pictures that go with each report), seconds.phoneScripts is the part of that spent in the scripts themselves, and seconds.retries is failed requests and the waits before trying again. \
        steps lists what happened in order. records are the transcript as kept; long opaque reasoning data is cut.
        """

    /// The steps of a conversation, in order.
    public static func steps(of entries: [TranscriptEntry]) -> [Step] {
        var steps: [Step] = []
        // The scripts the model asked for, by call, to say which one a report is of.
        var scripts: [String: String] = [:]
        var previous: (date: Date, delay: Double)?
        func brief(_ text: String, _ limit: Int = 160) -> String {
            let line = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ⏎ ")
            return line.count > limit ? String(line.prefix(limit)) + "…" : line
        }
        for entry in entries {
            let gap = previous.map { max(0, entry.date.timeIntervalSince($0.date) - $0.delay) }
            var step = Step(at: entry.date, kind: "")
            var delay = 0.0
            switch entry.body {
            case .user(let user):
                step.kind = "message"
                step.note = brief(user.text)
            case .assistant(let assistant):
                step.kind = "request"
                step.seconds = gap
                step.model = assistant.model
                step.usage = assistant.usage
                for call in assistant.calls {
                    scripts[call.id] = JSONValue(text: call.arguments)?["code"]?.stringValue ?? call.arguments
                }
                let words = brief(assistant.text)
                step.note = assistant.calls.isEmpty ? words : "asks for \(assistant.calls.count == 1 ? "a script" : "\(assistant.calls.count) scripts")" + (words.isEmpty ? "" : ": \(words)")
            case .toolResult(let result):
                step.kind = "script"
                step.seconds = gap
                step.scriptSeconds = result.payload["durationMs"]?.doubleValue.map { $0 / 1000 }
                let status = result.payload["status"]?.stringValue ?? ""
                step.note = (status == "ok" || status.isEmpty ? "" : "[\(status)] ") + brief(scripts[result.call] ?? "")
            case .failure(let failure):
                step.kind = "failure"
                step.seconds = gap
                step.note = brief(failure.message)
                step.delay = failure.retrying ? failure.delay : nil
                step.usage = failure.usage
                step.model = failure.model
                delay = step.delay ?? 0
            case .compaction(let compaction):
                step.kind = "summary"
                step.seconds = gap
                step.model = compaction.model
                step.usage = compaction.usage
            case .stop:
                step.kind = "stop"
            case .resume(let automatic):
                step.kind = "resume"
                step.note = automatic ? "by itself, after the app was closed" : "Continue"
            case .edit(let edit):
                step.kind = "edit"
                step.note = String(describing: edit.kind)
            case .imported:
                step.kind = "imported"
            case .placed:
                previous = (entry.date, 0)
                continue
            }
            steps.append(step)
            previous = (entry.date, delay)
        }
        return steps
    }

    /// Where the time of some steps went.
    public static func summary(of steps: [Step]) -> Summary {
        var summary = Summary()
        for step in steps {
            let seconds = step.seconds ?? 0
            if let usage = step.usage {
                summary.promptTokens += usage.promptTokens
                summary.completionTokens += usage.completionTokens
                summary.cost += usage.cost ?? 0
            }
            switch step.kind {
            case "request":
                summary.requests += 1
                summary.model += seconds
            case "summary":
                summary.model += seconds
            case "script":
                summary.scripts += 1
                summary.phone += seconds
                summary.script += min(seconds, step.scriptSeconds ?? 0)
            case "failure":
                summary.failures += 1
                summary.retries += seconds + (step.delay ?? 0)
            default:
                break
            }
        }
        return summary
    }

    /// The whole document. `app`, `device` and `system` say what made it.
    public static func document(photos: [Photo], app: String, device: String, system: String, date: Date) -> JSONValue {
        let formatter = ISO8601DateFormatter()
        var total = Summary()
        var listed: [JSONValue] = []
        for photo in photos {
            let steps = steps(of: photo.entries)
            let summary = summary(of: steps)
            total.add(summary)
            listed.append([
                "id": .string(photo.id),
                "name": .string(photo.name),
                "summary": summary.json,
                "steps": .array(steps.map { json(of: $0, formatter: formatter) }),
                "records": .array(photo.entries.compactMap(record)),
            ])
        }
        return [
            "about": .string(about),
            "exported": .string(formatter.string(from: date)),
            "app": .string(app),
            "device": .string(device),
            "system": .string(system),
            "summary": total.json,
            "photos": .array(listed),
        ]
    }

    /// The document as the bytes of a JSON file.
    public static func data(photos: [Photo], app: String, device: String, system: String, date: Date = Date()) -> Data {
        Data(document(photos: photos, app: app, device: device, system: system, date: date).text(pretty: true).utf8)
    }

    static func json(of step: Step, formatter: ISO8601DateFormatter) -> JSONValue {
        func rounded(_ value: Double) -> JSONValue { .number((value * 100).rounded() / 100) }
        var members: [String: JSONValue] = ["at": .string(formatter.string(from: step.at)), "kind": .string(step.kind)]
        if !step.note.isEmpty { members["note"] = .string(step.note) }
        if let seconds = step.seconds { members["seconds"] = rounded(seconds) }
        if let seconds = step.scriptSeconds { members["scriptSeconds"] = rounded(seconds) }
        if let model = step.model { members["model"] = .string(model) }
        if let usage = step.usage {
            members["promptTokens"] = .number(Double(usage.promptTokens))
            members["completionTokens"] = .number(Double(usage.completionTokens))
            if let cost = usage.cost { members["cost"] = .number(cost) }
        }
        if let delay = step.delay { members["retryAfter"] = rounded(delay) }
        return .object(members)
    }

    /// A record as the transcript keeps it, with opaque reasoning data (long, and of no use to a
    /// reader) cut down to its length.
    static func record(_ entry: TranscriptEntry) -> JSONValue? {
        guard let data = try? Transcript.encoder.encode(entry), var record = try? JSONDecoder().decode(JSONValue.self, from: data).objectValue else { return nil }
        if var body = record["data"]?.objectValue, var message = body["message"]?.objectValue, let details = message["reasoning_details"]?.arrayValue {
            message["reasoning_details"] = .array(
                details.map { detail in
                    guard var members = detail.objectValue, let opaque = members["data"]?.stringValue, opaque.count > 200 else { return detail }
                    members["data"] = .string("[\(opaque.count) characters]")
                    return .object(members)
                })
            body["message"] = .object(message)
            record["data"] = .object(body)
        }
        return .object(record)
    }
}
