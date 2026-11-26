import SwiftUI

/// The person's prompts, to change: the title and words of each, more of their own, fewer, another
/// order. What is here when the sheet closes is what the composer offers.
struct PromptsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var drafts: [SavedPrompt] = []
    /// The prompt being written, when one is open.
    @State private var path: [UUID] = []

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    ForEach(drafts) { prompt in
                        NavigationLink(value: prompt.id) {
                            VStack(alignment: .leading, spacing: 2) {
                                if !prompt.title.isEmpty {
                                    Text(verbatim: prompt.title).font(.subheadline.weight(.semibold))
                                }
                                Text(verbatim: prompt.text)
                                    .lineLimit(2)
                                    .foregroundStyle(prompt.title.isEmpty ? .primary : .secondary)
                            }
                        }
                        .accessibilityIdentifier("prompts.row")
                    }
                    .onDelete { drafts.remove(atOffsets: $0) }
                    .onMove { drafts.move(fromOffsets: $0, toOffset: $1) }
                    Button(L10n.promptAdd, systemImage: "plus") {
                        let new = SavedPrompt(text: "")
                        drafts.append(new)
                        path.append(new.id)
                    }
                    .accessibilityIdentifier("prompts.add")
                } footer: {
                    Text(L10n.promptsFooter)
                }
            }
            .navigationDestination(for: UUID.self) { id in
                if let index = drafts.firstIndex(where: { $0.id == id }) {
                    PromptEditor(prompt: $drafts[index])
                }
            }
            .navigationTitle(L10n.prompts)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { EditButton() }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.done) { dismiss() }
                        .accessibilityIdentifier("prompts.done")
                }
            }
            // A prompt left without words is not one: it goes as soon as the list is back.
            .onChange(of: path) { _, open in
                if open.isEmpty { drafts.removeAll { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }
            }
        }
        .onAppear { drafts = model.prompts.prompts }
        // However the sheet is closed, what was written is kept.
        .onDisappear { model.prompts.set(drafts) }
    }
}

/// One prompt being written: a short title for its button, and the words it sends.
private struct PromptEditor: View {
    @Binding var prompt: SavedPrompt
    @FocusState private var focused: Bool

    var body: some View {
        Form {
            Section {
                TextField(L10n.promptTitlePlaceholder, text: $prompt.title)
                    .accessibilityIdentifier("prompts.title")
            } header: {
                Text(L10n.promptTitleHeader)
            }
            Section {
                TextEditor(text: $prompt.text)
                    .frame(minHeight: 140)
                    .focused($focused)
                    .accessibilityIdentifier("prompts.text")
            } header: {
                Text(L10n.promptWordsHeader)
            }
        }
        .navigationTitle(prompt.title.isEmpty ? L10n.promptNew : prompt.title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if prompt.text.isEmpty { focused = true } }
    }
}
