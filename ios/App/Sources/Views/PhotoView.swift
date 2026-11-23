import OscuruCore
import OscuruEngine
import SwiftUI

/// The whole editor: the photo, and a place to say what you want.
struct PhotoView: View {
    @Environment(AppModel.self) private var model
    let document: PhotoDocument
    @State private var editor: PhotoEditor?
    @State private var problem: String?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let editor {
                EditorView(editor: editor)
            } else if let problem {
                ContentUnavailableView(L10n.photoUnreadable, systemImage: "exclamationmark.triangle", description: Text(problem))
            } else {
                ProgressView().tint(.white)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .task {
            guard editor == nil else { return }
            do {
                editor = try await model.open(document)
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

private struct EditorView: View {
    @Environment(AppModel.self) private var model
    let editor: PhotoEditor

    enum Sheet: String, Identifiable {
        case conversation, filters, settings
        var id: String { rawValue }
    }

    @State private var draft = ""
    @State private var sheet: Sheet?
    @State private var comparing = false
    @State private var exported: ExportedFile?
    @State private var exporting = false
    @State private var problem: String?
    @State private var confirmingReset = false
    @FocusState private var promptFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            canvas
            controls
        }
        .background(Color.black.ignoresSafeArea())
        .toolbar { toolbar }
        .sensoryFeedback(.success, trigger: editor.completedRuns)
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .conversation: ConversationView(editor: editor)
            case .filters: FiltersView(editor: editor)
            case .settings: SettingsView()
            }
        }
        .sheet(item: $exported) { file in
            ShareSheet(url: file.url).presentationDetents([.medium, .large])
        }
        .alert(L10n.exportFailed, isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button(L10n.ok, role: .cancel) {}
        } message: {
            Text(problem ?? "")
        }
    }

    // MARK: The photo

    private var canvas: some View {
        ZStack {
            if let image = comparing ? (editor.originalImage ?? editor.image) : editor.image {
                ZoomablePhoto(image: image, version: comparing ? -1 : editor.imageVersion)
                    .accessibilityIdentifier("photo.image")
                    .accessibilityLabel(editor.document.name)
            } else if let error = editor.renderError {
                ContentUnavailableView(L10n.photoUnreadable, systemImage: "exclamationmark.triangle", description: Text(error))
            } else {
                ProgressView().tint(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { promptFocused = false }
        // Touch and hold the photo to see it as it was opened.
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.3)
                .sequenced(before: DragGesture(minimumDistance: 0))
                .onChanged { value in
                    if case .second(true, _) = value { setComparing(true) }
                }
                .onEnded { _ in setComparing(false) }
        )
        .overlay(alignment: .top) {
            if comparing {
                Text(L10n.original)
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .glassEffect(.regular, in: .capsule)
                    .padding(.top, 8)
                    .transition(.opacity)
                    .accessibilityIdentifier("photo.original")
            }
        }
        .overlay(alignment: .bottomLeading) {
            if editor.isEdited, editor.image != nil {
                compareButton.padding(14)
            }
        }
        .animation(.easeOut(duration: 0.15), value: comparing)
    }

    /// Hold to see the original; the photo comes back when you let go.
    private var compareButton: some View {
        Label(L10n.before, systemImage: "square.split.2x1")
            .font(.footnote.weight(.semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .glassEffect(.regular.interactive(), in: .capsule)
            .onLongPressGesture(minimumDuration: 0, maximumDistance: 60, perform: {}, onPressingChanged: setComparing)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(L10n.beforeHint)
            .accessibilityIdentifier("photo.compare")
    }

    private func setComparing(_ on: Bool) {
        if on { editor.prepareOriginal() }
        comparing = on
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button(L10n.undo, systemImage: "arrow.uturn.backward") { editor.undo() }
                .disabled(!editor.history.canUndo)
                .accessibilityIdentifier("photo.undo")
            Button(L10n.redo, systemImage: "arrow.uturn.forward") { editor.redo() }
                .disabled(!editor.history.canRedo)
                .accessibilityIdentifier("photo.redo")
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button(L10n.filters, systemImage: "camera.filters") { sheet = .filters }
                .accessibilityIdentifier("photo.filters")
            if exporting {
                ProgressView()
            } else {
                Menu(L10n.more, systemImage: "ellipsis") {
                    Button(L10n.conversation, systemImage: "text.bubble") { sheet = .conversation }
                    Section(L10n.export) {
                        Button(L10n.exportJPEG, systemImage: "square.and.arrow.up") { export(.jpeg) }
                        Button(L10n.exportHEIC, systemImage: "square.and.arrow.up") { export(.heic) }
                    }
                    Section {
                        Button(L10n.resetEdits, systemImage: "arrow.counterclockwise", role: .destructive) { confirmingReset = true }
                            .disabled(!editor.isEdited)
                    }
                }
                .accessibilityIdentifier("photo.more")
                .alert(L10n.resetTitle, isPresented: $confirmingReset) {
                    Button(L10n.resetEdits, role: .destructive) { editor.reset() }
                    Button(L10n.cancel, role: .cancel) {}
                } message: {
                    Text(L10n.resetMessage)
                }
            }
        }
    }

    private func export(_ format: ExportFormat) {
        guard !exporting else { return }
        exporting = true
        Task {
            defer { exporting = false }
            do {
                exported = ExportedFile(url: try await editor.export(format))
            } catch {
                problem = String(describing: error)
            }
        }
    }

    // MARK: The assistant

    /// Always the same height, so the photo never moves while the assistant works.
    private var controls: some View {
        VStack(spacing: 12) {
            status
                .frame(height: 46)
                .frame(maxWidth: .infinity, alignment: .leading)
            composer
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 6)
        .animation(.snappy, value: editor.isWorking)
    }

    /// What the assistant is doing, what it last said, or ideas to start with.
    @ViewBuilder
    private var status: some View {
        if editor.isWorking {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small).tint(.white)
                Text(editor.workingCaption ?? L10n.assistantLooking)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .modifier(Breathing())
                    .frame(maxWidth: .infinity, alignment: .leading)
                if editor.scriptsThisRun > 0 {
                    Text(L10n.step(editor.scriptsThisRun))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("photo.working")
        } else if let last = editor.transcript.last, let text = last.words {
            HStack(spacing: 12) {
                Button {
                    sheet = .conversation
                } label: {
                    Text(text)
                        .font(.subheadline)
                        .foregroundStyle(last.isError ? Color.red : Color.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint(L10n.conversationHint)
                .accessibilityIdentifier("photo.note")
                if editor.canRevert(run: last.run) {
                    Button(L10n.revert) { withAnimation { editor.revert(run: last.run) } }
                        .font(.subheadline.weight(.medium))
                        .buttonStyle(.glass)
                        .accessibilityIdentifier("photo.revert")
                }
            }
        } else if editor.transcript.isEmpty, model.account.isConnected {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(L10n.suggestions, id: \.label) { suggestion in
                        Button(suggestion.label) { send(suggestion.instruction) }
                            .font(.subheadline)
                            .buttonStyle(.glass)
                    }
                }
            }
            .scrollClipDisabled()
        }
    }

    @ViewBuilder
    private var composer: some View {
        if model.account.isConnected {
            HStack(alignment: .bottom, spacing: 6) {
                TextField(L10n.promptPlaceholder, text: $draft, axis: .vertical)
                    .lineLimit(1...4)
                    .focused($promptFocused)
                    .padding(.leading, 18)
                    .padding(.vertical, 13)
                    .disabled(editor.isWorking)
                    .accessibilityIdentifier("photo.prompt")
                action.padding(6)
            }
            .glassEffect(.regular, in: .rect(cornerRadius: 26))
        } else {
            Button {
                sheet = .settings
            } label: {
                Text(L10n.connectToEdit).frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .accessibilityIdentifier("photo.connect")
        }
    }

    /// Send, or stop while the assistant is working.
    @ViewBuilder
    private var action: some View {
        if editor.isWorking {
            Button {
                editor.stop()
            } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 13, weight: .bold))
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .accessibilityLabel(L10n.stop)
            .accessibilityIdentifier("photo.stop")
        } else {
            Button {
                send(draft)
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 16, weight: .bold))
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.circle)
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel(L10n.send)
            .accessibilityIdentifier("photo.send")
        }
    }

    private func send(_ text: String) {
        draft = ""
        promptFocused = false
        editor.send(text)
    }
}

/// A slow fade in and out, for text that says work is in progress. Still in UI tests, which wait
/// for the screen to settle.
private struct Breathing: ViewModifier {
    func body(content: Content) -> some View {
        if UITesting.isActive {
            content
        } else {
            content.phaseAnimator([1.0, 0.5]) { view, opacity in
                view.opacity(opacity)
            } animation: { _ in
                .easeInOut(duration: 1.1)
            }
        }
    }
}

extension TranscriptItem {
    /// The text to show for the assistant's closing note or a notice; nil for other items.
    var words: String? {
        switch kind {
        case .assistant(let text), .notice(let text, _): return text
        default: return nil
        }
    }

    var isError: Bool {
        if case .notice(_, true) = kind { return true }
        return false
    }
}

private struct ExportedFile: Identifiable {
    let url: URL
    var id: String { url.path }
}

/// The system share sheet: save to Photos or Files, AirDrop, and so on.
private struct ShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// The photo, fitted to its space. New pictures cross-fade in. Pinch to zoom, drag to move while
/// zoomed, double-tap to fit again; the zoom stays while the assistant changes the photo.
private struct ZoomablePhoto: View {
    let image: CGImage
    let version: Int
    @State private var zoom: CGFloat = 1
    @State private var settledZoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var settledOffset: CGSize = .zero

    var body: some View {
        ZStack {
            Image(decorative: image, scale: 1)
                .resizable()
                .scaledToFit()
                .id(version)
                .transition(.opacity)
        }
        .animation(.easeInOut(duration: 0.45), value: version)
        .scaleEffect(zoom)
        .offset(offset)
        .gesture(
            MagnifyGesture()
                .onChanged { value in zoom = min(8, max(1, settledZoom * value.magnification)) }
                .onEnded { _ in
                    settledZoom = zoom
                    if zoom == 1 { reset() }
                }
        )
        .simultaneousGesture(
            DragGesture()
                .onChanged { value in
                    guard zoom > 1 else { return }
                    offset = CGSize(width: settledOffset.width + value.translation.width, height: settledOffset.height + value.translation.height)
                }
                .onEnded { _ in settledOffset = offset }
        )
        .onTapGesture(count: 2) { withAnimation(.snappy) { reset() } }
    }

    private func reset() {
        zoom = 1
        settledZoom = 1
        offset = .zero
        settledOffset = .zero
    }
}
