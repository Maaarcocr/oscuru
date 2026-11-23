import OscuruCore
import SwiftUI

/// Everything said and done on this photo: instructions, the assistant's notes, and the scripts it ran.
struct ConversationView: View {
    @Environment(\.dismiss) private var dismiss
    let editor: PhotoEditor

    var body: some View {
        NavigationStack {
            Group {
                if editor.transcript.isEmpty {
                    ContentUnavailableView(L10n.conversationEmpty, systemImage: "text.bubble")
                } else {
                    List(editor.transcript) { item in
                        row(item)
                            .listRowSeparator(.hidden)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle(L10n.conversation)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.done) { dismiss() }
                        .accessibilityIdentifier("conversation.done")
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ item: TranscriptItem) -> some View {
        switch item.kind {
        case .user(let text):
            Text(text)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(white: 0.2), in: RoundedRectangle(cornerRadius: 16))
                .frame(maxWidth: .infinity, alignment: .trailing)
        case .assistant(let text):
            Text(text).textSelection(.enabled)
        case .notice(let text, let isError):
            Text(text)
                .font(.footnote)
                .foregroundStyle(isError ? Color.red : Color.secondary)
        case .script(let code, let state, let changes, let logs):
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 6) {
                    if case .failed(let message) = state, !message.isEmpty {
                        Text(message).font(.caption).foregroundStyle(.red)
                    }
                    ForEach(changes, id: \.self) { change in
                        Text(change).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                    ForEach(Array(logs.enumerated()), id: \.offset) { _, line in
                        Text(verbatim: "› \(line)").font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                    Text(code)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .padding(.top, 4)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Label(L10n.scriptTitle(state), systemImage: symbol(state))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("conversation.script")
        }
    }

    private func symbol(_ state: TranscriptItem.ScriptState) -> String {
        switch state {
        case .running: return "hourglass"
        case .applied: return "checkmark.circle"
        case .unchanged: return "eye"
        case .failed: return "exclamationmark.triangle"
        case .stale: return "arrow.triangle.2.circlepath"
        }
    }
}
