import Foundation
import Observation

/// The person's prompts: instructions kept to send again with a tap, above the composer of a photo
/// that has not been given one yet. They start as a few ideas in the app's language, and from
/// the first change on they are whatever the person has made of them.
@MainActor
@Observable
final class PromptStore {
    private(set) var prompts: [String]
    /// Where they are kept; nil keeps them only while the app runs (UI tests start from the ideas each time).
    @ObservationIgnored private let defaults: UserDefaults?
    static let key = "composer.prompts"

    init(defaults: UserDefaults?) {
        self.defaults = defaults
        prompts = defaults?.stringArray(forKey: Self.key) ?? L10n.promptIdeas
    }

    /// Replaces them all, in this order: each trimmed, and none empty or twice.
    func set(_ wanted: [String]) {
        var kept: [String] = []
        for prompt in wanted.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) where !prompt.isEmpty && !kept.contains(prompt) {
            kept.append(prompt)
        }
        guard kept != prompts else { return }
        prompts = kept
        defaults?.set(kept, forKey: Self.key)
    }
}
