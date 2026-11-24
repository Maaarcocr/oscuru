import OscuruCore
import SwiftUI

/// A photo, as a conversation: the original, what you asked for, and every version since.
struct PhotoView: View {
    @Environment(AppModel.self) private var model
    let document: PhotoDocument
    @State private var editor: PhotoEditor?
    @State private var problem: String?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let editor {
                ThreadView(editor: editor)
            } else if let problem {
                ContentUnavailableView(L10n.photoUnreadable, systemImage: "exclamationmark.triangle", description: Text(problem))
            } else {
                ProgressView().tint(.white)
            }
        }
        .navigationTitle((document.name as NSString).deletingPathExtension)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard editor == nil else { return }
            do {
                let opened = try await model.open(document)
                // Left before it opened: let it go again.
                guard !Task.isCancelled else { return model.close(opened) }
                editor = opened
            } catch {
                problem = String(describing: error)
            }
        }
        .onDisappear {
            if let editor { model.close(editor) }
            editor = nil
        }
    }
}

/// The thread, with the composer below it and Share above. Tapping a version opens it full screen.
private struct ThreadView: View {
    let editor: PhotoEditor
    @State private var viewing: Viewed?
    @FocusState private var composing: Bool

    private static let end = "end"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    ForEach(editor.turns) { turn in
                        TurnView(turn: turn, editor: editor, open: open)
                            .id(turn.id)
                    }
                    if let sending = editor.sending {
                        Bubble(text: sending).opacity(0.6)
                    }
                    // Sent while the assistant works: read between two of its steps.
                    ForEach(Array(editor.queued.enumerated()), id: \.offset) { _, text in
                        VStack(alignment: .trailing, spacing: 4) {
                            Bubble(text: text).opacity(0.6)
                            Text(L10n.queuedNote).font(.caption).foregroundStyle(.secondary)
                        }
                        .accessibilityIdentifier("thread.queued")
                    }
                    if let problem = editor.storageProblem {
                        Text(L10n.storageProblem(problem))
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Color.clear.frame(height: 1).id(ThreadView.end)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 16)
            }
            .scrollDismissesKeyboard(.interactively)
            // A short thread starts at the top; a long one opens at its latest turn. New turns are
            // followed by scrolling on each change. Nothing in the thread changes size on a tap:
            // a row growing in the middle of a lazy stack while it scrolls can loop forever.
            .defaultScrollAnchor(.top, for: .alignment)
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .accessibilityIdentifier("thread")
            .onChange(of: editor.threadVersion) {
                withAnimation(.snappy) { proxy.scrollTo(ThreadView.end, anchor: .bottom) }
            }
            .onChange(of: composing) { _, focused in
                guard focused else { return }
                Task {
                    try? await Task.sleep(for: .milliseconds(350))
                    withAnimation(.snappy) { proxy.scrollTo(ThreadView.end, anchor: .bottom) }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Composer(editor: editor, focused: $composing)
            }
            // Kept clear of the top edge so the thread stops at the title bar instead of sliding under it.
            .padding(.top, 1)
        }
        .background(Color.black)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShareButton(photos: [editor.document.id])
            }
        }
        .sensoryFeedback(.success, trigger: editor.completedRuns)
        .fullScreenCover(item: $viewing) { item in
            PhotoViewer(editor: editor, item: item)
        }
    }

    private func open(_ turn: Turn) {
        guard let state = turn.result else { return }
        composing = false
        viewing = Viewed(state: state, before: editor.resultBefore(turn), isCurrent: state == editor.state)
    }
}

// MARK: - A turn

private struct TurnView: View {
    let turn: Turn
    let editor: PhotoEditor
    let open: (Turn) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch turn.kind {
            case .original:
                Caption(text: L10n.originalCaption(editor.info))
                card
            case .instruction(let text):
                Bubble(text: text)
                reply
            case .style(let name):
                Caption(text: L10n.appliedStyle(name))
                card
            case .restore, .startOver:
                Caption(text: turn.result == editor.original ? L10n.backToOriginal : L10n.restored)
                card
            case .earlier:
                Caption(text: L10n.earlierEdits)
                card
            }
        }
    }

    /// What the assistant said and did for an instruction.
    @ViewBuilder
    private var reply: some View {
        if turn.status == .working {
            // Its latest words while it works; they stay with the step once it is done.
            if let note = turn.messages.last ?? turn.steps.last(where: { $0.note != nil })?.note {
                Text(note)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentTransition(.opacity)
                    .animation(.easeInOut(duration: 0.3), value: note)
                    .accessibilityIdentifier("thread.message")
            }
            // The photo as it is now: it changes as each step lands.
            PhotoCard(editor: editor, state: editor.state)
                .overlay(alignment: .bottomLeading) { progress }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("thread.working")
            if let retry = editor.retry {
                Text(retry.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ForEach(Array(turn.messages.enumerated()), id: \.offset) { _, message in
                Text(message)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("thread.reply")
            }
            card
            switch turn.status {
            case .stopped: Caption(text: L10n.stopped)
            case .failed(let message):
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("thread.error")
            default: EmptyView()
            }
            if editor.canContinue, turn.id == editor.turns.last?.id {
                Button(L10n.continueRun) { editor.continueRun() }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .tint(.white)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("thread.continue")
            }
            if !turn.steps.isEmpty {
                StepsSummary(steps: turn.steps, cost: turn.cost)
            }
        }
    }

    /// What the assistant is doing now, over the photo it is doing it to.
    private var progress: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small).tint(.white)
            Text(editor.retry != nil ? L10n.reconnecting : editor.summarizing ? L10n.summarizing : turn.steps.isEmpty ? L10n.looking : L10n.step(turn.steps.count))
                .font(.footnote.weight(.medium))
                .monospacedDigit()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .glassEffect(.regular, in: .capsule)
        .padding(10)
    }

    /// The version this turn left: tap it to look closely, compare, or bring it back.
    @ViewBuilder
    private var card: some View {
        if let state = turn.result {
            PhotoCard(editor: editor, state: state)
                .onTapGesture { open(turn) }
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier(turn.kind == .original ? "thread.original" : "thread.version")
        }
    }
}

/// What the person wrote, on the right.
private struct Bubble: View {
    let text: String

    var body: some View {
        Text(text)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Color.accentColor.opacity(0.85), in: RoundedRectangle(cornerRadius: 19, style: .continuous))
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.leading, 56)
            .textSelection(.enabled)
    }
}

/// A short centred line saying what happened.
private struct Caption: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
    }
}

/// One version of the photo in the thread. When the version changes, the new picture fades in
/// over the old one.
private struct PhotoCard: View {
    let editor: PhotoEditor
    let state: EditingState
    @State private var image: CGImage?

    var body: some View {
        // The picture it last drew, or one the editor already has; a new version fades in over it.
        let image = image ?? editor.keptPicture(of: state)
        return ZStack {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .id(ObjectIdentifier(image))
                    .transition(.opacity)
            } else {
                Color(white: 0.1)
                    .aspectRatio(CGFloat(editor.info.width) / CGFloat(max(1, editor.info.height)), contentMode: .fit)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: image.map { ObjectIdentifier($0) })
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .frame(maxWidth: .infinity)
        .task(id: state) {
            if let picture = await editor.picture(of: state) { self.image = picture }
        }
    }
}

/// What the assistant's scripts did: one line in the thread, and the steps themselves on a sheet,
/// so the thread stays the conversation and never changes size under the finger.
private struct StepsSummary: View {
    let steps: [Step]
    let cost: Double?
    @State private var showing = false

    var body: some View {
        Button {
            showing = true
        } label: {
            HStack(spacing: 6) {
                Text(L10n.stepsCount(steps.count))
                if let cost { Text(verbatim: "· \(UsageLedger.dollars(cost))") }
                Image(systemName: "chevron.right").font(.caption2.weight(.semibold))
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("thread.steps")
        .sheet(isPresented: $showing) {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                            StepView(number: index + 1, step: step)
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .navigationTitle(L10n.stepsCount(steps.count))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L10n.done) { showing = false }
                            .accessibilityIdentifier("steps.done")
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
    }
}

private struct StepView: View {
    let number: Int
    let step: Step
    @State private var showingScript = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: symbol).foregroundStyle(tint)
                Text(L10n.stepTitle(number, step.outcome)).font(.footnote.weight(.semibold))
            }
            if let note = step.note {
                Text(note)
                    .font(.footnote)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !step.changes.isEmpty {
                Text(step.changes.map(L10n.describe).joined(separator: " · "))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if case .failed(let message) = step.outcome, !message.isEmpty {
                Text(message).font(.caption).foregroundStyle(.red)
            }
            Button {
                withAnimation(.snappy) { showingScript.toggle() }
            } label: {
                Text(L10n.script).font(.caption.weight(.medium)).foregroundStyle(.tint)
            }
            .buttonStyle(.plain)
            if showingScript {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(step.logs.enumerated()), id: \.offset) { _, line in
                        Text(verbatim: "› \(line)").font(.caption2.monospaced()).foregroundStyle(.secondary)
                    }
                    Text(step.code).font(.caption2.monospaced()).textSelection(.enabled)
                }
            }
        }
    }

    private var symbol: String {
        switch step.outcome {
        case .running: return "hourglass"
        case .applied: return "checkmark.circle.fill"
        case .unchanged: return "eye"
        case .failed, .stale: return "exclamationmark.triangle.fill"
        case .stopped: return "stop.circle"
        }
    }

    private var tint: Color {
        switch step.outcome {
        case .applied: return .green
        case .failed, .stale: return .orange
        default: return .secondary
        }
    }
}
