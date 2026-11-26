import Foundation
import Observation

/// An instruction kept to send again with a tap: its words, and a short title for its button when
/// the words are too long or too plain to stand there themselves.
struct Prompt: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    /// Empty for none: the button then shows the words.
    var title = ""
    var text: String

    /// What its button says.
    var name: String { title.isEmpty ? text : title }
}

/// The person's prompts, above the composer of a photo that has not been given an instruction
/// yet. They start as a few ideas in the app's language, and from the first change on they are
/// whatever the person has made of them.
@MainActor
@Observable
final class PromptStore {
    private(set) var prompts: [Prompt]
    /// Where they are kept; nil keeps them only while the app runs (UI tests start from the ideas each time).
    @ObservationIgnored private let defaults: UserDefaults?
    static let key = "composer.prompts.titled"
    /// Where a version that knew no titles kept them, as their words alone.
    static let untitledKey = "composer.prompts"

    init(defaults: UserDefaults?) {
        self.defaults = defaults
        if let data = defaults?.data(forKey: Self.key), let kept = try? JSONDecoder().decode([Prompt].self, from: data) {
            prompts = kept
        } else if let words = defaults?.stringArray(forKey: Self.untitledKey) {
            prompts = words.map { Prompt(text: $0) }
        } else {
            prompts = L10n.promptIdeas
        }
    }

    /// Replaces them all, in this order: each trimmed, and none without words.
    func set(_ wanted: [Prompt]) {
        let kept = wanted.compactMap { prompt -> Prompt? in
            let text = prompt.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return Prompt(id: prompt.id, title: prompt.title.trimmingCharacters(in: .whitespacesAndNewlines), text: text)
        }
        guard kept != prompts else { return }
        prompts = kept
        if let data = try? JSONEncoder().encode(kept) { defaults?.set(data, forKey: Self.key) }
    }
}
