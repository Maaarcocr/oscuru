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
                ProgressView()
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
    @State private var showingOriginal = false
    @State private var exported: ExportedFile?
    @State private var exporting = false
    @State private var problem: String?
    @State private var confirmingReset = false
    @FocusState private var promptFocused: Bool

    var body: some View {
        photo
            .safeAreaInset(edge: .bottom, spacing: 0) { bottom }
            .toolbar { toolbar }
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

    private var photo: some View {
        ZStack {
            if let image = showingOriginal ? (editor.originalImage ?? editor.image) : editor.image {
                ZoomablePhoto(image: image)
                    .accessibilityIdentifier("photo.image")
                    .accessibilityLabel(editor.document.name)
            } else if let error = editor.renderError {
                ContentUnavailableView(L10n.photoUnreadable, systemImage: "exclamationmark.triangle", description: Text(error))
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .top) {
            if showingOriginal {
                Text(L10n.original)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, 8)
                    .accessibilityIdentifier("photo.original")
            }
        }
        // Touch and hold to see the photo as it was opened.
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.25)
                .sequenced(before: DragGesture(minimumDistance: 0))
                .onChanged { value in
                    if case .second(true, _) = value, !showingOriginal {
                        editor.prepareOriginal()
                        showingOriginal = true
                    }
                }
                .onEnded { _ in showingOriginal = false }
        )
        .onTapGesture { promptFocused = false }
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
            if exporting {
                ProgressView()
            } else {
                Menu(L10n.more, systemImage: "ellipsis.circle") {
                    Button(L10n.filters, systemImage: "camera.filters") { sheet = .filters }
                        .accessibilityIdentifier("photo.filters")
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

    private var bottom: some View {
        VStack(spacing: 10) {
            activity
            if model.account.isConnected {
                prompt
            } else {
                Button {
                    sheet = .settings
                } label: {
                    Text(L10n.connectToEdit).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier("photo.connect")
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(.ultraThinMaterial)
    }

    /// What the assistant is doing, or the last thing it said.
    @ViewBuilder
    private var activity: some View {
        if editor.isWorking {
            HStack(spacing: 10) {
                ProgressView()
                Text(editor.scriptsThisRun == 0 ? L10n.assistantLooking : L10n.assistantEditing(step: editor.scriptsThisRun))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("photo.working")
                Spacer()
                Button(L10n.stop) { editor.stop() }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("photo.stop")
            }
        } else if let last = editor.transcript.last, let text = last.words {
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    sheet = .conversation
                } label: {
                    Text(text)
                        .font(.subheadline)
                        .foregroundStyle(last.isError ? Color.red : Color.primary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("photo.note")
                HStack {
                    if let cost = editor.costs[last.run] {
                        Text(L10n.cost(UsageLedger.dollars(cost)))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    if editor.canRevert(run: last.run) {
                        Button(L10n.revert) { editor.revert(run: last.run) }
                            .font(.subheadline)
                            .accessibilityIdentifier("photo.revert")
                    }
                }
            }
        } else if editor.transcript.isEmpty, model.account.isConnected {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(L10n.suggestions, id: \.self) { suggestion in
                        Button(suggestion) { send(suggestion) }
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.capsule)
                            .font(.subheadline)
                    }
                }
            }
            .scrollClipDisabled()
        }
    }

    private var prompt: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(L10n.promptPlaceholder, text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .focused($promptFocused)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color(white: 0.16), in: RoundedRectangle(cornerRadius: 20))
                .disabled(editor.isWorking)
                .accessibilityIdentifier("photo.prompt")
            Button {
                send(draft)
            } label: {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 34))
            }
            .disabled(editor.isWorking || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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

/// The photo, fitted to the screen. Pinch to zoom, drag to move while zoomed, double-tap to fit again.
private struct ZoomablePhoto: View {
    let image: CGImage
    @State private var zoom: CGFloat = 1
    @State private var settledZoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var settledOffset: CGSize = .zero

    var body: some View {
        Image(decorative: image, scale: 1)
            .resizable()
            .scaledToFit()
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
