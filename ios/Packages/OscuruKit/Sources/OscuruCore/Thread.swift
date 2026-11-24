import Foundation

/// One setting a script changed.
public struct StepChange: Codable, Equatable, Sendable {
    public let path: String
    public let from: JSONValue
    public let to: JSONValue

    public init(path: String, from: JSONValue, to: JSONValue) {
        self.path = path
        self.from = from
        self.to = to
    }
}

/// One script the assistant ran.
public struct Step: Codable, Equatable, Sendable {
    public enum Outcome: Codable, Equatable, Sendable {
        case running
        case applied
        case unchanged
        case failed(String)
        /// It never finished: the person stopped the assistant or the app closed first.
        case stopped
        /// Only in threads saved by earlier versions: refused because the photo had changed.
        case stale
    }

    public var code: String
    public var outcome: Outcome
    public var changes: [StepChange] = []
    public var logs: [String] = []
    /// What the assistant said as it started this script.
    public var note: String?
    /// The tool call it answers.
    public var call: String?

    public init(code: String, outcome: Outcome, changes: [StepChange] = [], logs: [String] = [], note: String? = nil, call: String? = nil) {
        self.code = code
        self.outcome = outcome
        self.changes = changes
        self.logs = logs
        self.note = note
        self.call = call
    }
}

/// One thing that happened to the photo, as the thread shows it. A turn that changed the photo
/// keeps the settings it left, so every version can be shown again and restored.
public struct Turn: Codable, Identifiable, Equatable, Sendable {
    public enum Kind: Codable, Equatable, Sendable {
        case original
        case instruction(String)
        /// A style was put on the photo.
        case style(String)
        /// An earlier version was made current again.
        case restore
        /// Edits made before the photo had a thread.
        case earlier
        /// Only in threads saved by earlier versions: back to the original, now a restore like any other.
        case startOver

        // A style keeps the name it was first saved under.
        private enum CodingKeys: String, CodingKey {
            case original, instruction, style = "filter", restore, earlier, startOver
        }
    }

    public enum Status: Codable, Equatable, Sendable {
        case working
        case done
        case stopped
        case failed(String)
    }

    public var id: String
    public var kind: Kind
    /// What the assistant said that is not a step's note: once it has finished, its reply.
    public var messages: [String] = []
    public var steps: [Step] = []
    /// The photo after this turn, when the turn changed it (and the original, for the first turn).
    public var result: EditingState?
    public var status: Status = .done
    public var cost: Double?

    public init(id: String, kind: Kind, messages: [String] = [], steps: [Step] = [], result: EditingState? = nil, status: Status = .done, cost: Double? = nil) {
        self.id = id
        self.kind = kind
        self.messages = messages
        self.steps = steps
        self.result = result
        self.status = status
        self.cost = cost
    }
}

extension Step {
    /// What a script's report says it did.
    mutating func finish(with payload: JSONValue) {
        changes = (payload["changes"]?.arrayValue ?? []).map { change in
            StepChange(path: change["path"]?.stringValue ?? "", from: change["from"] ?? .null, to: change["to"] ?? .null)
        }
        logs = (payload["logs"]?.arrayValue ?? []).compactMap(\.stringValue)
        switch payload["status"]?.stringValue {
        case "ok": outcome = payload["applied"] == true ? .applied : .unchanged
        default: outcome = .failed(payload["error"]?["message"]?.stringValue ?? "")
        }
    }
}

extension Conversation {
    /// The thread as the person sees it, in the order the model saw it. `working` says whether the
    /// assistant is at work now; `price` turns a request's usage into dollars; `failure` says in
    /// the person's words why a run ended without an answer.
    public func turns(working: Bool, price: (Usage, String) -> Double, failure: (TranscriptEntry.Failure) -> String) -> [Turn] {
        var turns: [Turn] = []
        // The instruction turn the assistant's work belongs to, while there is one.
        var current: Int?
        func spend(_ usage: Usage?, _ model: String) {
            guard let usage, let index = current else { return }
            turns[index].cost = (turns[index].cost ?? 0) + price(usage, model)
        }

        for entry in placed {
            switch entry.body {
            case .imported(let thread):
                for var turn in thread.turns {
                    // A turn still working when the app closed was cut off.
                    if turn.status == .working { turn.status = .stopped }
                    for index in turn.steps.indices where turn.steps[index].outcome == .running {
                        turn.steps[index].outcome = .stopped
                    }
                    turns.append(turn)
                }
                current = nil
            case .edit(let edit):
                turns.append(Turn(id: entry.id, kind: edit.kind, result: edit.state))
                current = nil
            case .user(let user):
                turns.append(Turn(id: entry.id, kind: .instruction(user.text)))
                current = turns.count - 1
            case .assistant(let assistant):
                guard let index = current else { continue }
                spend(assistant.usage, assistant.model)
                let said = assistant.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let calls = assistant.calls
                // Words that come with a script are that step's note; words on their own are the reply.
                if calls.isEmpty {
                    if !said.isEmpty { turns[index].messages.append(said) }
                }
                for (position, call) in calls.enumerated() {
                    let code = JSONValue(text: call.arguments)?["code"]?.stringValue ?? ""
                    turns[index].steps.append(Step(code: code, outcome: .running, note: position == 0 && !said.isEmpty ? said : nil, call: call.id))
                }
            case .toolResult(let result):
                guard let index = current, let step = turns[index].steps.lastIndex(where: { $0.call == result.call }) else { continue }
                turns[index].steps[step].finish(with: result.payload)
                if let state = result.state { turns[index].result = state }
            case .failure(let failed):
                spend(failed.usage, failed.model ?? "")
                guard let index = current, !failed.retrying else { continue }
                turns[index].status = .failed(failure(failed))
            case .compaction(let compaction):
                spend(compaction.usage, compaction.model)
            case .stop:
                if let index = current { turns[index].status = .stopped }
            case .resume:
                if let index = current { turns[index].status = .done }
            case .placed:
                break
            }
        }

        // Scripts that never reported: still going, or cut off.
        for index in turns.indices {
            let live = working && index == current
            for step in turns[index].steps.indices where turns[index].steps[step].outcome == .running {
                if !live { turns[index].steps[step].outcome = .stopped }
            }
        }
        if let index = current {
            if working {
                turns[index].status = .working
            } else if wasInterrupted {
                // Cut off without anyone stopping it, and not picked up yet.
                turns[index].status = .stopped
            }
        }
        return turns
    }
}
