import Foundation

/// A picture kept with the conversation: the words that say what it shows, and its file next to
/// the transcript.
public struct PictureRef: Codable, Equatable, Sendable {
    public var label: String
    public var file: String

    public init(label: String, file: String) {
        self.label = label
        self.file = file
    }
}

/// One tool call in an assistant message.
public struct ToolCall: Equatable, Sendable {
    public var id: String
    public var name: String
    /// The arguments as the model wrote them: JSON text, not always valid.
    public var arguments: String
}

/// One record of a photo's conversation: what the person said and did, what the model answered,
/// what its scripts did, and how runs ended. Records are only ever added, and each is on disk
/// before anything shows it, so nothing is lost when the app closes or the connection drops.
public struct TranscriptEntry: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var date: Date
    public var body: Body

    public enum Body: Equatable, Sendable {
        /// Words from the person. A message sent while the assistant works is `queued`: it joins
        /// the conversation at the `placed` record that names it, between two steps.
        case user(User)
        /// One model response, exactly as the provider sent it.
        case assistant(Assistant)
        /// What one script did.
        case toolResult(ToolResult)
        /// Queued messages join the conversation here, in this order.
        case placed([String])
        /// A model request failed. When `retrying`, another attempt follows; otherwise the run
        /// ended here, and Continue picks it up.
        case failure(Failure)
        /// The person stopped the assistant.
        case stop
        /// The run goes on: after Continue, or by itself when the app closed during it (`automatic`).
        case resume(automatic: Bool)
        /// Older messages, summarized so the conversation fits the model's context.
        case compaction(Compaction)
        /// A change to the photo the person made: a style, a restored version, starting over.
        case edit(Edit)
        /// A thread saved before the transcript existed, kept as it was.
        case imported(Imported)
    }

    public struct User: Codable, Equatable, Sendable {
        /// What the person wrote.
        public var text: String
        /// What the model gets: the words and, when they start a run, the photo's context.
        public var prompt: String
        public var pictures: [PictureRef]
        public var queued: Bool

        public init(text: String, prompt: String, pictures: [PictureRef] = [], queued: Bool = false) {
            self.text = text
            self.prompt = prompt
            self.pictures = pictures
            self.queued = queued
        }
    }

    public struct Assistant: Codable, Equatable, Sendable {
        /// The message as it came: some providers attach reasoning that must go back unchanged.
        public var message: JSONValue
        public var model: String
        public var usage: Usage?

        public init(message: JSONValue, model: String, usage: Usage?) {
            self.message = message
            self.model = model
            self.usage = usage
        }

        public var calls: [ToolCall] {
            (message["tool_calls"]?.arrayValue ?? []).map { call in
                ToolCall(
                    id: call["id"]?.stringValue ?? "", name: call["function"]?["name"]?.stringValue ?? "",
                    arguments: call["function"]?["arguments"]?.stringValue ?? "{}")
            }
        }

        public var text: String { Agent.text(of: message) }
    }

    public struct ToolResult: Codable, Equatable, Sendable {
        public var call: String
        /// The report the model reads.
        public var payload: JSONValue
        /// Pictures that go to the model after the round's reports.
        public var pictures: [PictureRef]
        /// The photo after the script, when it changed it.
        public var state: EditingState?

        public init(call: String, payload: JSONValue, pictures: [PictureRef] = [], state: EditingState? = nil) {
            self.call = call
            self.payload = payload
            self.pictures = pictures
            self.state = state
        }
    }

    public struct Failure: Codable, Equatable, Sendable {
        public var kind: ModelError.Kind
        public var message: String
        public var status: Int?
        public var retrying: Bool
        /// Seconds before the next attempt, when retrying.
        public var delay: Double?
        /// What a failed summary cost, when it was charged.
        public var usage: Usage?
        public var model: String?

        public init(kind: ModelError.Kind, message: String, status: Int? = nil, retrying: Bool, delay: Double? = nil, usage: Usage? = nil, model: String? = nil) {
            self.kind = kind
            self.message = message
            self.status = status
            self.retrying = retrying
            self.delay = delay
            self.usage = usage
            self.model = model
        }

        public var error: ModelError { ModelError(kind, message, status: status) }
    }

    public struct Compaction: Codable, Equatable, Sendable {
        public var summary: String
        /// The first record the model still sees in full; everything placed before it is the summary.
        public var firstKept: String
        /// Roughly how many tokens the summary replaced.
        public var tokensBefore: Int
        public var usage: Usage?
        public var model: String

        public init(summary: String, firstKept: String, tokensBefore: Int, usage: Usage?, model: String) {
            self.summary = summary
            self.firstKept = firstKept
            self.tokensBefore = tokensBefore
            self.usage = usage
            self.model = model
        }
    }

    public struct Edit: Codable, Equatable, Sendable {
        public var kind: Turn.Kind
        public var state: EditingState

        public init(kind: Turn.Kind, state: EditingState) {
            self.kind = kind
            self.state = state
        }
    }

    public struct Imported: Codable, Equatable, Sendable {
        public var turns: [Turn]
        /// The messages the model had been sent, as they were saved.
        public var conversation: [JSONValue]

        public init(turns: [Turn], conversation: [JSONValue]) {
            self.turns = turns
            self.conversation = conversation
        }
    }

    public init(id: String, date: Date, body: Body) {
        self.id = id
        self.date = date
        self.body = body
    }

    // One line of JSON per record: {"id", "date", "type", "data"}.
    private enum CodingKeys: String, CodingKey { case id, date, type, data }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        date = try container.decode(Date.self, forKey: .date)
        switch try container.decode(String.self, forKey: .type) {
        case "user": body = .user(try container.decode(User.self, forKey: .data))
        case "assistant": body = .assistant(try container.decode(Assistant.self, forKey: .data))
        case "toolResult": body = .toolResult(try container.decode(ToolResult.self, forKey: .data))
        case "placed": body = .placed(try container.decode([String].self, forKey: .data))
        case "failure": body = .failure(try container.decode(Failure.self, forKey: .data))
        case "stop": body = .stop
        case "resume": body = .resume(automatic: try container.decode(Bool.self, forKey: .data))
        case "compaction": body = .compaction(try container.decode(Compaction.self, forKey: .data))
        case "edit": body = .edit(try container.decode(Edit.self, forKey: .data))
        case "imported": body = .imported(try container.decode(Imported.self, forKey: .data))
        case let other: throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "unknown record type \(other)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(date, forKey: .date)
        switch body {
        case .user(let value): try container.encode("user", forKey: .type); try container.encode(value, forKey: .data)
        case .assistant(let value): try container.encode("assistant", forKey: .type); try container.encode(value, forKey: .data)
        case .toolResult(let value): try container.encode("toolResult", forKey: .type); try container.encode(value, forKey: .data)
        case .placed(let value): try container.encode("placed", forKey: .type); try container.encode(value, forKey: .data)
        case .failure(let value): try container.encode("failure", forKey: .type); try container.encode(value, forKey: .data)
        case .stop: try container.encode("stop", forKey: .type)
        case .resume(let automatic): try container.encode("resume", forKey: .type); try container.encode(automatic, forKey: .data)
        case .compaction(let value): try container.encode("compaction", forKey: .type); try container.encode(value, forKey: .data)
        case .edit(let value): try container.encode("edit", forKey: .type); try container.encode(value, forKey: .data)
        case .imported(let value): try container.encode("imported", forKey: .type); try container.encode(value, forKey: .data)
        }
    }
}

/// A photo's conversation on disk: `transcript.jsonl`, one record per line, only ever appended
/// to, and the pictures the model was sent in `pictures/`. Every record is flushed to storage
/// before `append` returns, and only then delivered to observers, so what anyone is shown has
/// been kept. The only writer of its folder: open one per folder.
public actor Transcript {
    public nonisolated let folder: URL
    public private(set) var entries: [TranscriptEntry]
    private var observers: [UUID: AsyncStream<TranscriptEntry>.Continuation] = [:]
    private let now: @Sendable () -> Date

    public nonisolated var file: URL { folder.appending(path: "transcript.jsonl") }
    nonisolated var picturesFolder: URL { folder.appending(path: "pictures", directoryHint: .isDirectory) }

    /// Opens the transcript in `folder`, creating the folder if needed. A last line cut off by the
    /// app closing mid-write is dropped; nothing before it is affected.
    public init(folder: URL, now: @escaping @Sendable () -> Date = { Date() }) throws {
        self.folder = folder
        self.now = now
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "transcript.jsonl")
        guard let data = try? Data(contentsOf: url) else {
            entries = []
            return
        }
        var entries: [TranscriptEntry] = []
        var kept = 0
        let decoder = TranscriptEntry.decoder
        var start = data.startIndex
        while start < data.endIndex {
            guard let end = data[start...].firstIndex(of: UInt8(ascii: "\n")) else { break }
            // A record that does not read (a newer app's) is skipped, not fatal.
            if let entry = try? decoder.decode(TranscriptEntry.self, from: data[start..<end]) { entries.append(entry) }
            start = end + 1
            kept = start - data.startIndex
        }
        if kept < data.count {
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: UInt64(kept))
            try handle.close()
        }
        self.entries = entries
    }

    public var isEmpty: Bool { entries.isEmpty }

    /// Writes a record and returns it once it is on disk.
    @discardableResult
    public func append(_ body: TranscriptEntry.Body) throws -> TranscriptEntry {
        let entry = TranscriptEntry(id: UUID().uuidString.lowercased(), date: now(), body: body)
        var line = try Transcript.encoder.encode(entry)
        line.append(UInt8(ascii: "\n"))
        if !FileManager.default.fileExists(atPath: file.path) {
            _ = FileManager.default.createFile(atPath: file.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
        try handle.synchronize()
        entries.append(entry)
        for observer in observers.values { observer.yield(entry) }
        return entry
    }

    /// The records so far, and every record appended from now on, in order.
    public func observe() -> (entries: [TranscriptEntry], updates: AsyncStream<TranscriptEntry>) {
        let (stream, continuation) = AsyncStream.makeStream(of: TranscriptEntry.self)
        let id = UUID()
        observers[id] = continuation
        continuation.onTermination = { _ in Task { await self.forget(id) } }
        return (entries, stream)
    }

    private func forget(_ id: UUID) {
        observers[id] = nil
    }

    /// Keeps a picture for the conversation and returns how records refer to it.
    public func store(_ picture: LabeledImage) throws -> PictureRef {
        try FileManager.default.createDirectory(at: picturesFolder, withIntermediateDirectories: true)
        let name = "\(UUID().uuidString.lowercased()).jpg"
        try picture.jpeg.write(to: picturesFolder.appending(path: name), options: .atomic)
        return PictureRef(label: picture.label, file: name)
    }

    /// A kept picture, or nil once it has been let go.
    public nonisolated func picture(_ ref: PictureRef) -> Data? {
        try? Data(contentsOf: picturesFolder.appending(path: ref.file))
    }

    /// Deletes the pictures the model will not be sent again (it gets a note in their place),
    /// so a long conversation does not fill the phone.
    /// Recent files are kept: a picture stored for a message not written yet must survive.
    public func prune(keepingNewerThan age: TimeInterval = 600) {
        let keep = Conversation(entries).keptPictures
        let files = (try? FileManager.default.contentsOfDirectory(atPath: picturesFolder.path)) ?? []
        let cutoff = now().addingTimeInterval(-age)
        for file in files where !keep.contains(file) {
            let url = picturesFolder.appending(path: file)
            let modified = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? .distantPast
            guard modified < cutoff else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

extension TranscriptEntry {
    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
