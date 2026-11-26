import SwiftUI

/// The person's prompts, to change: the words of each, more of their own, fewer, another order.
/// What is here when the sheet closes is what the composer offers.
struct PromptsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var drafts: [Draft] = []
    @FocusState private var focused: UUID?

    /// A prompt while it is being written: a new one starts empty, and two may read the same for a while.
    private struct Draft: Identifiable {
        let id = UUID()
        var text: String
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach($drafts) { $draft in
                        TextField(L10n.promptPlaceholder, text: $draft.text, axis: .vertical)
                            .lineLimit(1...8)
                            .focused($focused, equals: draft.id)
                            .accessibilityIdentifier("prompts.text")
                    }
                    .onDelete { drafts.remove(atOffsets: $0) }
                    .onMove { drafts.move(fromOffsets: $0, toOffset: $1) }
                    Button(L10n.promptAdd, systemImage: "plus") {
                        let new = Draft(text: "")
                        drafts.append(new)
                        // Once its row is there, the keyboard is on it.
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
        .onAppear { drafts = model.prompts.prompts.map { Draft(text: $0) } }
        // However the sheet is closed, what was written is kept.
        .onDisappear { model.prompts.set(drafts.map(\.text)) }
    }
}
