import Foundation

/// Keeping a long conversation within the model's context: older records are summarized, the
/// summary is added to the transcript, and the model sees it in their place. The records stay in
/// the transcript and in the thread.
public enum Compaction {
    /// A summary is made before a request once the previous one used more than the model's
    /// context minus this.
    public static let reserveTokens = 16_384
    /// Roughly how much of the latest conversation stays word for word.
    public static let keepRecentTokens = 20_000
    static let pictureTokens = 1_200
    static let reportCharacters = 2_000

    /// A rough count of the tokens a record takes in a request.
    static func tokens(of entry: TranscriptEntry) -> Int {
        switch entry.body {
        case .user(let user): return user.prompt.count / 4 + user.pictures.count * pictureTokens
        case .assistant(let assistant): return assistant.message.text().count / 4
        case .toolResult(let result): return result.payload.text().count / 4 + result.pictures.count * pictureTokens
        default: return 0
        }
    }

    /// Where a summary would end: the first record kept in full, and the tokens before it. Kept
    /// records run from a message or a model response (never from a report, which belongs with its
    /// call). Nil when there is nothing before that to summarize.
    static func cut(_ conversation: Conversation, keep: Int = keepRecentTokens) -> (index: Int, tokensBefore: Int)? {
        let placed = conversation.placed
        let start = min(conversation.start, placed.count)
        var kept = 0
        var index = placed.count
        while index > start {
            index -= 1
            kept += tokens(of: placed[index])
            if kept >= keep { break }
        }
        while index > start {
            if case .user = placed[index].body { break }
            if case .assistant = placed[index].body { break }
            index -= 1
        }
        guard index > start else { return nil }
        let before = placed[start..<index].reduce(0) { $0 + tokens(of: $1) }
        return (index, before)
    }

    static let instructions = """
        You write the memory of a conversation between a person and the colourist who edits their photo in Oscuru, an iPhone app for developing RAW photographs. The conversation has grown too long to send in full: your summary replaces its older part, and the colourist will carry on from it without seeing those messages.

        Use this structure:

        ## Goal
        What the person is after with this photo.

        ## Preferences
        What they liked, disliked, and asked to keep or avoid, in their own words where it matters.

        ## Done
        What was changed and why: the decisions, and the settings and values that matter.

        ## Open
        What was asked for and is not finished, questions waiting for an answer, and next steps.

        Be specific and brief. Keep exact numbers and names. Do not explain the scripting API. Do not answer or continue the conversation: write only the summary.
        """

    /// The conversation before the cut as plain text: what was said, the scripts, and their reports.
    static func text(of entries: ArraySlice<TranscriptEntry>) -> String {
        var lines: [String] = []
        for entry in entries {
            switch entry.body {
            case .user(let user):
                lines.append("[Person]\n\(user.text)")
            case .assistant(let assistant):
                let said = assistant.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !said.isEmpty { lines.append("[Colourist]\n\(said)") }
                for call in assistant.calls {
                    lines.append("[Script]\n\(JSONValue(text: call.arguments)?["code"]?.stringValue ?? call.arguments)")
                }
            case .toolResult(let result):
                var report = result.payload.text()
                if report.count > reportCharacters { report = String(report.prefix(reportCharacters)) + "… [cut]" }
                lines.append("[Script report]\n\(report)")
            case .imported(let thread):
                for message in thread.conversation where message["role"] == "user" || message["role"] == "assistant" {
                    let said = Agent.text(of: message).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !said.isEmpty { lines.append(message["role"] == "user" ? "[Person]\n\(said)" : "[Colourist]\n\(said)") }
                }
            case .failure, .stop, .resume, .compaction, .edit, .placed:
                break
            }
        }
        return lines.joined(separator: "\n\n")
    }

    /// The request that writes the summary of everything before `cut`.
    static func request(_ conversation: Conversation, cut: Int, model: String, sessionID: String?) -> ChatRequest {
        let earlier = conversation.placed[min(conversation.start, cut)..<cut]
        var prompt = "<conversation>\n\(text(of: earlier))\n</conversation>"
        if let previous = conversation.summary {
            prompt = "<earlier-summary>\n\(previous.summary)\n</earlier-summary>\n\n" + prompt
                + "\n\nThe earlier summary covers what came before this conversation. Fold what still matters from it into yours."
        }
        prompt += "\n\nWrite the summary now."
        return ChatRequest(
            model: model, messages: [["role": "system", "content": .string(instructions)], ["role": "user", "content": .string(prompt)]], tools: [],
            sessionID: sessionID)
    }
}
