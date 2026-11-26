import Foundation

/// A transcript read for what it means now: the order the model saw things in, messages still
/// waiting to be read, what the assistant has to do next, and the messages for its next request.
/// Everything here is worked out from the records alone, so after the app closes, reading the
/// transcript again puts the work exactly where it was.
public struct Conversation: Sendable {
    /// What the conversation asks for next.
    public enum Need: Equatable, Sendable {
        /// The assistant has answered; nothing is waiting.
        case nothing
        /// The latest words, or the latest scripts' reports, are waiting for the model.
        case answer
        /// The model asked for these scripts and they have not run yet.
        case tools([ToolCall])
    }

    /// Why the latest run ended without an answer.
    public enum Halt: Equatable, Sendable {
        case stopped
        case failed(TranscriptEntry.Failure)
    }

    public let entries: [TranscriptEntry]
    /// The records in the order the model saw them: a queued message where it was placed.
    public let placed: [TranscriptEntry]
    /// Messages the person sent while the assistant worked that have not joined yet.
    public let queued: [TranscriptEntry]
    /// What the conversation asks for, whether or not the run was halted.
    public let need: Need
    public let halt: Halt?
    /// The record that started the latest run.
    public let runStart: String?
    /// The photo's settings now: the latest the transcript recorded. The transcript is the photo's
    /// history; anything else that holds its settings is a copy of this.
    public let state: EditingState?
    /// The photo's settings when the latest run started.
    public let stateBeforeRun: EditingState?
    /// How many times the run picked itself up after the app closed, since a step last landed.
    public let automaticResumes: Int
    /// Prompt tokens of the latest request since the latest summary.
    public let lastPromptTokens: Int?
    /// Where the model's view starts in `placed`: after a summary, the first record it kept.
    let start: Int
    let summary: TranscriptEntry.Compaction?
    /// The pictures still sent to the model; the others get a note in their place.
    public let keptPictures: Set<String>

    public init(_ entries: [TranscriptEntry]) {
        self.entries = entries
        var placed: [TranscriptEntry] = []
        var waiting: [String: TranscriptEntry] = [:]
        var order: [String] = []
        for entry in entries {
            switch entry.body {
            case .user(let user) where user.queued:
                waiting[entry.id] = entry
                order.append(entry.id)
            case .placed(let ids):
                for id in ids { if let message = waiting.removeValue(forKey: id) { placed.append(message) } }
            default:
                placed.append(entry)
            }
        }
        self.placed = placed
        queued = order.compactMap { waiting[$0] }

        var need = Need.nothing
        var pending: [ToolCall] = []
        var halt: Halt?
        var runStart: String?
        var open = false
        var resumes = 0
        var lastPrompt: Int?
        var summaryIndex: Int?
        var state: EditingState?
        var stateBeforeRun: EditingState?
        for (index, entry) in placed.enumerated() {
            switch entry.body {
            case .user:
                if !open {
                    runStart = entry.id
                    stateBeforeRun = state
                }
                open = true
                halt = nil
                pending = []
                need = .answer
            case .assistant(let assistant):
                pending = assistant.calls
                need = pending.isEmpty ? .nothing : .tools(pending)
                if pending.isEmpty { open = false }
                resumes = 0
                lastPrompt = assistant.usage?.promptTokens ?? lastPrompt
            case .toolResult(let result):
                guard pending.contains(where: { $0.id == result.call }) else { continue }
                pending.removeAll { $0.id == result.call }
                need = pending.isEmpty ? .answer : .tools(pending)
                resumes = 0
                state = result.state ?? state
            case .failure(let failure):
                guard !failure.retrying else { continue }
                halt = .failed(failure)
                open = false
            case .stop:
                halt = .stopped
                open = false
            case .resume(let automatic):
                halt = nil
                open = true
                if automatic { resumes += 1 }
            case .compaction:
                summaryIndex = index
                lastPrompt = nil
            case .edit(let edit):
                state = edit.state
            case .imported(let thread):
                state = thread.turns.last { $0.result != nil }?.result ?? state
            case .placed:
                break
            }
        }
        self.state = state
        self.stateBeforeRun = stateBeforeRun
        self.need = need
        self.halt = halt
        self.runStart = runStart
        automaticResumes = resumes
        lastPromptTokens = lastPrompt

        if let summaryIndex, case .compaction(let compaction) = placed[summaryIndex].body {
            summary = compaction
            start = placed.firstIndex { $0.id == compaction.firstKept } ?? summaryIndex + 1
        } else {
            summary = nil
            start = 0
        }

        // Pictures: what the person sent since the latest instruction (the photo as it was, and
        // anything they attached), and the latest few rounds of scripts' pictures, which show the
        // photo as it is now and the steps just before. Older ones are let go: the model is told
        // a picture was there, and can look again.
        let sent = placed[min(start, placed.count)...]
        let runIndex = runStart.flatMap { id in sent.firstIndex { $0.id == id } } ?? sent.endIndex
        var kept = Set<String>()
        for entry in sent[runIndex...] {
            if case .user(let user) = entry.body { kept.formUnion(user.pictures.map(\.file)) }
        }
        var rounds = 0
        var index = sent.endIndex
        while index > sent.startIndex, rounds < Conversation.recentRounds {
            index -= 1
            guard case .toolResult = sent[index].body, !Conversation.pictures(of: sent[index]).isEmpty else { continue }
            // A round's pictures come with each of its reports.
            var earlier = index
            while earlier > sent.startIndex, case .toolResult = sent[earlier - 1].body { earlier -= 1 }
            var later = index
            while later + 1 < sent.endIndex, case .toolResult = sent[later + 1].body { later += 1 }
            for report in sent[earlier...later] { kept.formUnion(Conversation.pictures(of: report).map(\.file)) }
            rounds += 1
            index = earlier
        }
        // Before any script has shown anything, the latest pictures from before the instruction.
        if rounds == 0 {
            var index = runIndex
            while index > sent.startIndex {
                index -= 1
                let pictures = Conversation.pictures(of: sent[index])
                guard !pictures.isEmpty else { continue }
                kept.formUnion(pictures.map(\.file))
                break
            }
        }
        keptPictures = kept
    }

    static func pictures(of entry: TranscriptEntry) -> [PictureRef] {
        switch entry.body {
        case .user(let user): return user.pictures
        case .toolResult(let result): return result.pictures
        default: return []
        }
    }

    /// What the assistant should do now: nothing after a stop or a failure, until Continue.
    public var next: Need { halt == nil ? need : .nothing }

    /// Whether Continue has something to pick up.
    public var canContinue: Bool { halt != nil && (need != .nothing || !queued.isEmpty) }

    /// Whether work was cut off without anyone stopping it, such as by the app closing: it
    /// carries on by itself.
    public var wasInterrupted: Bool { halt == nil && (need != .nothing || !queued.isEmpty) }

    /// The latest scripts the model asked for that have not run.
    public var pendingCalls: [ToolCall] {
        if case .tools(let calls) = need { return calls }
        return []
    }

    // MARK: The model's view

    static let summaryPreface = "[A summary of the conversation before this point, written when it grew too long to send in full.]"
    static let picturesNote = "[Pictures from the phone for the script above.]"
    static let removedPictureNote =
        "[An earlier picture was here. Only the pictures of the latest few steps are kept; later pictures show the photo as it is now. To see something again, show it again.]"
    /// How many rounds of scripts' pictures are sent: the latest, and the few before it to compare with.
    static let recentRounds = 3
    static let resumedNote =
        "[The app closed while you were working and has been opened again. Carry on from where you were. The script REPL started afresh, so variables from earlier scripts are gone; the photo's settings are as the latest report says.]"
    static let notRunPayload: JSONValue = [
        "status": "not_run", "applied": false,
        "error": ["message": "This script did not run: you were stopped, or the app closed, before it started. Nothing was applied."],
    ]

    /// How much of a request the pictures may take, written out (base64). Providers refuse a
    /// request past a size of their own (Google's is 20 MB), and a long run that looked at the
    /// photo at every step reaches it: past this, the oldest are let go.
    public static let pictureBytes = 12_000_000

    /// The messages for the next request, in the Chat Completions shape. A failed attempt is left
    /// out; a script that never reported gets a report saying so; pictures that were let go get
    /// a note. Of the pictures kept, the newest are sent, as many as fit in `pictureBytes`.
    public func messages(system: String, pictureBytes: Int = Conversation.pictureBytes, picture: (PictureRef) -> Data?) -> [JSONValue] {
        // The newest pictures first, until the room is used up.
        var sent: [String: Data] = [:]
        var room = pictureBytes
        newest: for entry in placed[min(start, placed.count)...].reversed() {
            for ref in Conversation.pictures(of: entry).reversed() where keptPictures.contains(ref.file) && sent[ref.file] == nil {
                guard let jpeg = picture(ref) else { continue }
                let size = (jpeg.count + 2) / 3 * 4
                guard size <= room else { break newest }
                room -= size
                sent[ref.file] = jpeg
            }
        }
        var out: [JSONValue] = [["role": "system", "content": .string(system)]]
        if let summary { out.append(["role": "user", "content": .string("\(Conversation.summaryPreface)\n\n\(summary.summary)")]) }

        var pending: [ToolCall] = []
        var roundPictures: [PictureRef] = []
        var held: [JSONValue] = []
        func parts(_ text: String, _ pictures: [PictureRef]) -> JSONValue {
            var parts: [JSONValue] = [["type": "text", "text": .string(text)]]
            for ref in pictures {
                parts.append(["type": "text", "text": .string(ref.label)])
                if let jpeg = sent[ref.file] {
                    parts.append(["type": "image_url", "image_url": ["url": .string("data:image/jpeg;base64,\(jpeg.base64EncodedString())")]])
                } else {
                    parts.append(["type": "text", "text": .string(Conversation.removedPictureNote)])
                }
            }
            return .array(parts)
        }
        // A round ends once every script has reported: then its pictures, then anything that
        // waited for it (a message must not come between a call and its report).
        func closeRound() {
            for call in pending {
                out.append(["role": "tool", "tool_call_id": .string(call.id), "content": .string(Conversation.notRunPayload.text())])
            }
            pending = []
            if !roundPictures.isEmpty {
                out.append(["role": "user", "content": parts(Conversation.picturesNote, roundPictures)])
                roundPictures = []
            }
            out += held
            held = []
        }

        for entry in placed[min(start, placed.count)...] {
            switch entry.body {
            case .user(let user):
                closeRound()
                out.append(["role": "user", "content": parts(user.prompt, user.pictures)])
            case .assistant(let assistant):
                closeRound()
                out.append(assistant.message)
                pending = assistant.calls
            case .toolResult(let result):
                guard pending.contains(where: { $0.id == result.call }) else { continue }
                pending.removeAll { $0.id == result.call }
                out.append(["role": "tool", "tool_call_id": .string(result.call), "content": .string(result.payload.text())])
                roundPictures += result.pictures
                if pending.isEmpty { closeRound() }
            case .resume(let automatic):
                guard automatic else { continue }
                held.append(["role": "user", "content": .string(Conversation.resumedNote)])
                if pending.isEmpty { closeRound() }
            case .imported(let thread):
                closeRound()
                // Saved before the transcript: its pictures are older than any sent now.
                out += thread.conversation.filter { $0["role"] != "system" }.map(Conversation.withoutPictures)
            case .failure, .stop, .compaction, .edit, .placed:
                break
            }
        }
        closeRound()
        return out
    }

    static func withoutPictures(_ message: JSONValue) -> JSONValue {
        guard var members = message.objectValue, let parts = members["content"]?.arrayValue else { return message }
        members["content"] = .array(parts.map { $0["type"] == "image_url" ? ["type": "text", "text": .string(removedPictureNote)] : $0 })
        return .object(members)
    }
}
