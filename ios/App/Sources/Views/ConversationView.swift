import OscuruCore
import SwiftUI

/// Everything said and done on this photo: what you asked, what the assistant said, and each step it took.
struct ConversationView: View {
    @Environment(\.dismiss) private var dismiss
    let editor: PhotoEditor

    var body: some View {
        NavigationStack {
            Group {
                if editor.transcript.isEmpty {
                    ContentUnavailableView(L10n.conversationEmpty, systemImage: "text.bubble")
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            ForEach(rows) { row in
                                item(row.item, step: row.step)
                                if let cost = row.cost {
                                    Text(L10n.cost(UsageLedger.dollars(cost)))
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                        .frame(maxWidth: .infinity, alignment: .trailing)
                                        .padding(.bottom, 10)
                                }
                            }
                        }
                        .padding(20)
                    }
                    .defaultScrollAnchor(.bottom)
                }
            }
            .navigationTitle(L10n.conversation)
            .navigationBarTitleDisplayMode(.inline)
            // The conversation scrolls under a solid bar, so the title never sits on top of a message.
            .toolbarBackgroundVisibility(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.done) { dismiss() }
                        .accessibilityIdentifier("conversation.done")
                }
            }
        }
    }

    private struct Row: Identifiable {
        let item: TranscriptItem
        /// For scripts: their number within the instruction.
        let step: Int
        /// On the last line of a finished instruction: what it cost.
        let cost: Double?
        var id: String { item.id }
    }

    private var rows: [Row] {
        let items = editor.transcript
        var steps: [String: Int] = [:]
        return items.enumerated().map { index, item in
            var step = 0
            if case .script = item.kind {
                steps[item.run, default: 0] += 1
                step = steps[item.run]!
            }
            let lastOfRun = index == items.count - 1 || items[index + 1].run != item.run
            let cost = lastOfRun && editor.activeRun != item.run ? editor.costs[item.run] : nil
            return Row(item: item, step: step, cost: cost)
        }
    }

    @ViewBuilder
    private func item(_ item: TranscriptItem, step: Int) -> some View {
        switch item.kind {
        case .user(let text):
            Text(text)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.accentColor.opacity(0.22), in: RoundedRectangle(cornerRadius: 18))
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.leading, 48)
        case .assistant(let text):
            Text(text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .notice(let text, let isError):
            Text(text)
                .font(.footnote)
                .foregroundStyle(isError ? Color.red : Color.secondary)
        case .script(let code, let state, let changes, let logs):
            StepRow(step: step, code: code, state: state, changes: changes, logs: logs)
        }
    }
}

/// One script the assistant ran, in words: what it changed. The code is there for the curious.
private struct StepRow: View {
    let step: Int
    let code: String
    let state: TranscriptItem.ScriptState
    let changes: [StepChange]
    let logs: [String]
    @State private var showingScript = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: symbol).foregroundStyle(tint)
                Text(L10n.stepTitle(step, state)).font(.footnote.weight(.semibold))
            }
            if !changes.isEmpty {
                Text(summary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if case .failed(let message) = state, !message.isEmpty {
                Text(message).font(.caption).foregroundStyle(.red)
            }
            DisclosureGroup(L10n.showScript, isExpanded: $showingScript) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(logs.enumerated()), id: \.offset) { _, line in
                        Text(verbatim: "› \(line)").font(.caption2.monospaced()).foregroundStyle(.secondary)
                    }
                    Text(code)
                        .font(.caption2.monospaced())
                        .textSelection(.enabled)
                        .padding(.top, 4)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.caption)
            .tint(.secondary)
            .accessibilityIdentifier("conversation.script")
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(white: 0.11), in: RoundedRectangle(cornerRadius: 16))
    }

    private var summary: String {
        let shown = changes.prefix(6).map(L10n.describe)
        let rest = changes.count - shown.count
        return (shown + (rest > 0 ? [L10n.moreChanges(rest)] : [])).joined(separator: " · ")
    }

    private var symbol: String {
        switch state {
        case .running: return "hourglass"
        case .applied: return "checkmark.circle.fill"
        case .unchanged: return "eye"
        case .failed: return "exclamationmark.triangle.fill"
        case .stale: return "arrow.triangle.2.circlepath"
        }
    }

    private var tint: Color {
        switch state {
        case .applied: return .green
        case .failed: return .orange
        default: return .secondary
        }
    }
}
