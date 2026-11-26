import SwiftUI

/// The person's prompts, to change: the words and the title of each, more of their own, fewer,
/// another order. What is here when the sheet closes is what the composer offers.
struct PromptsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var drafts: [Prompt] = []
    @FocusState private var focused: UUID?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach($drafts) { $draft in
                        VStack(alignment: .leading, spacing: 4) {
                            TextField(L10n.promptTitlePlaceholder, text: $draft.title)
                                .font(.subheadline.weight(.semibold))
                                .focused($focused, equals: draft.id)
                                .accessibilityIdentifier("prompts.title")
                            TextField(L10n.promptPlaceholder, text: $draft.text, axis: .vertical)
                                .lineLimit(1...8)
                                .accessibilityIdentifier("prompts.text")
                        }
                    }
                    .onDelete { drafts.remove(atOffsets: $0) }
                    .onMove { drafts.move(fromOffsets: $0, toOffset: $1) }
                    Button(L10n.promptAdd, systemImage: "plus") {
                        let new = Prompt(text: "")
                        drafts.append(new)
                        // Once its row is there, the keyboard is on its title.
                        Task { focused = new.id }
                    }
                    .accessibilityIdentifier("prompts.add")
                } footer: {
                    Text(L10n.promptsFooter)
                }
            }
            // Always ready to be changed: each prompt has its delete button and its handle to drag it
            // by in plain sight, and its words can still be typed over.
            .environment(\.editMode, .constant(.active))
            .navigationTitle(L10n.prompts)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.done) { dismiss() }
                        .accessibilityIdentifier("prompts.done")
                }
            }
        }
        .onAppear { drafts = model.prompts.prompts }
        // However the sheet is closed, what was written is kept.
        .onDisappear { model.prompts.set(drafts) }
    }
}
