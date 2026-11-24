import OscuruCore
import OscuruEngine
import PhotosUI
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

/// A version of the photo opened full screen.
struct Viewed: Identifiable {
    let id = UUID()
    let state: EditingState
    /// The version before it, for comparing; nil for the original.
    let before: EditingState?
    let isCurrent: Bool
}

private struct ThreadView: View {
    @Environment(AppModel.self) private var model
    let editor: PhotoEditor

    enum Sheet: String, Identifiable {
        case filters, settings
        var id: String { rawValue }
    }

    @State private var draft = ""
    @State private var sheet: Sheet?
    @State private var viewing: Viewed?
    @State private var shared: SharedFiles?
    @State private var exporting = false
    @State private var problem: String?
    @State private var confirmingStartOver = false
    /// Pictures to send with the next instruction: a look to match, or the original and edit of one.
    @State private var attachments: [Attachment] = []
    @State private var pickedReferences: [PhotosPickerItem] = []
    @FocusState private var composing: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    ForEach(editor.turns) { turn in
                        TurnView(turn: turn, editor: editor, open: open, share: share) { id in
                            withAnimation(.snappy) { proxy.scrollTo(id) }
                        }
                        .id(turn.id)
                    }
                    Color.clear.frame(height: 1).id(ThreadView.end)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 16)
            }
            .scrollDismissesKeyboard(.interactively)
            // A short thread starts at the top; a long one stays at its latest turn.
            .defaultScrollAnchor(.top, for: .alignment)
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .defaultScrollAnchor(.bottom, for: .sizeChanges)
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
            .safeAreaInset(edge: .bottom, spacing: 0) { composer }
            // Kept clear of the top edge so the thread stops at the title bar instead of sliding under it.
            .padding(.top, 1)
        }
        .background(Color.black)
        .toolbar { menu }
        .sensoryFeedback(.success, trigger: editor.completedRuns)
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .filters: FiltersView(editor: editor)
            case .settings: SettingsView()
            }
        }
        .fullScreenCover(item: $viewing) { item in
            PhotoViewer(editor: editor, item: item)
        }
        .sheet(item: $shared) { files in
            ShareSheet(urls: files.urls).presentationDetents([.medium, .large])
        }
        .alert(L10n.exportFailed, isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button(L10n.ok, role: .cancel) {}
        } message: {
            Text(problem ?? "")
        }
    }

    private static let end = "end"

    private func open(_ turn: Turn) {
        guard let state = turn.result else { return }
        composing = false
        viewing = Viewed(state: state, before: editor.resultBefore(turn), isCurrent: state == editor.state)
    }

    private func share(_ state: EditingState, _ format: ExportFormat) {
        guard !exporting else { return }
        exporting = true
        Task {
            defer { exporting = false }
            do {
                shared = SharedFiles([try await editor.export(state, as: format)])
            } catch {
                problem = String(describing: error)
            }
        }
    }

    /// The untouched RAW file, as it was taken or added.
    private func shareOriginal() {
        guard !exporting else { return }
        exporting = true
        Task {
            defer { exporting = false }
            do {
                shared = SharedFiles([try await editor.exportOriginal()])
            } catch {
                problem = String(describing: error)
            }
        }
    }

    // MARK: Menu

    @ToolbarContentBuilder
    private var menu: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            if exporting {
                ProgressView()
            } else {
                Menu(L10n.more, systemImage: "ellipsis") {
                    Button(L10n.filters, systemImage: "camera.filters") { sheet = .filters }
                        .disabled(editor.isWorking)
                        .accessibilityIdentifier("menu.filters")
                    Menu(L10n.sharePhoto, systemImage: "square.and.arrow.up") {
                        Button(L10n.shareJPEG) { share(editor.state, .jpeg) }
                        Button(L10n.shareHEIC) { share(editor.state, .heic) }
                        if editor.info.isRaw {
                            Divider()
                            Button {
                                shareOriginal()
                            } label: {
                                Text(L10n.shareRAW)
                                Text(L10n.shareRAWFooter)
                            }
                        }
                    }
                    Button(L10n.startOver, systemImage: "arrow.counterclockwise") { confirmingStartOver = true }
                        .disabled(editor.isWorking || editor.state == editor.original)
                    Divider()
                    Button(L10n.settings, systemImage: "gearshape") { sheet = .settings }
                }
                .accessibilityIdentifier("photo.menu")
                .alert(L10n.startOverTitle, isPresented: $confirmingStartOver) {
                    Button(L10n.startOver) { editor.startOver() }
                    Button(L10n.cancel, role: .cancel) {}
                } message: {
                    Text(L10n.startOverMessage)
                }
            }
        }
    }

    // MARK: Composer

    private var composer: some View {
        VStack(spacing: 10) {
            if model.account.isConnected, !editor.hasInstructions, !editor.isWorking {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(L10n.suggestions, id: \.self) { suggestion in
                            Button(suggestion.label) { send(suggestion.instruction) }
                                .font(.subheadline)
                                .buttonStyle(.bordered)
                                .buttonBorderShape(.capsule)
                                .tint(.white)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
            if model.account.isConnected {
                if !attachments.isEmpty { attachmentStrip }
                HStack(alignment: .bottom, spacing: 8) {
                    attachButton
                    TextField(L10n.composerPlaceholder, text: $draft, axis: .vertical)
                        .lineLimit(1...6)
                        .focused($composing)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Color(white: 0.15), in: RoundedRectangle(cornerRadius: 21, style: .continuous))
                        .disabled(editor.isWorking)
                        .accessibilityIdentifier("composer.field")
                    action
                }
                .padding(.horizontal, 12)
            } else {
                Button {
                    sheet = .settings
                } label: {
                    Text(L10n.composerConnect).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.horizontal, 16)
                .accessibilityIdentifier("composer.connect")
            }
        }
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(Color.black)
        .onChange(of: pickedReferences) { _, items in
            guard !items.isEmpty else { return }
            pickedReferences = []
            Task {
                for item in items.prefix(max(0, 2 - attachments.count)) {
                    guard let picked = try? await item.loadTransferable(type: PickedPhoto.self) else { continue }
                    // Temporary copies are named "<uuid>-<original name>".
                    let name = String(picked.url.lastPathComponent.dropFirst(37))
                    let thumbnail = await Task.detached { Thumbnails.image(at: picked.url, maxPixel: 240) }.value
                    withAnimation(.snappy) { attachments.append(Attachment(url: picked.url, name: name, thumbnail: thumbnail)) }
                }
            }
        }
    }

    /// Attach up to two pictures from Photos: a look to match, or an original and its edit.
    private var attachButton: some View {
        PhotosPicker(selection: $pickedReferences, maxSelectionCount: max(1, 2 - attachments.count), matching: .images, preferredItemEncoding: .current) {
            Image(systemName: "plus.circle.fill")
                .font(.system(size: 34))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.white)
        }
        .disabled(editor.isWorking || attachments.count >= 2)
        .accessibilityLabel(L10n.attach)
        .accessibilityIdentifier("composer.attach")
    }

    private var attachmentStrip: some View {
        HStack(spacing: 10) {
            ForEach(attachments) { attachment in
                Group {
                    if let image = attachment.thumbnail {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else {
                        Color(white: 0.15)
                    }
                }
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    Button {
                        withAnimation(.snappy) {
                            attachments.removeAll { $0.id == attachment.id }
                        }
                        try? FileManager.default.removeItem(at: attachment.url)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 20))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(Color.white, Color(white: 0.3))
                    }
                    .offset(x: 7, y: -7)
                    .accessibilityLabel(L10n.removeAttachment)
                }
                .transition(.scale.combined(with: .opacity))
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
    }

    /// Send, or stop while the assistant is working.
    @ViewBuilder
    private var action: some View {
        if editor.isWorking {
            Button {
                editor.stop()
            } label: {
                Image(systemName: "stop.circle.fill")
                    .font(.system(size: 34))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.white)
            }
            .accessibilityLabel(L10n.stop)
            .accessibilityIdentifier("composer.stop")
        } else {
            let empty = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty
            Button {
                send(draft)
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(empty ? Color(white: 0.3) : Color.accentColor)
            }
            .disabled(empty)
            .accessibilityLabel(L10n.send)
            .accessibilityIdentifier("composer.send")
        }
    }

    private func send(_ text: String) {
        let files = attachments.map { (url: $0.url, name: $0.name) }
        draft = ""
        attachments = []
        composing = false
        editor.send(text, attachments: files)
    }
}

// MARK: - A turn

private struct TurnView: View {
    let turn: Turn
    let editor: PhotoEditor
    let open: (Turn) -> Void
    let share: (EditingState, ExportFormat) -> Void
    /// Scrolls just enough to bring the view with this id fully onto the screen.
    let reveal: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch turn.kind {
            case .original:
                Caption(text: L10n.originalCaption(editor.info))
                card
            case .instruction(let text):
                if let names = turn.attachments, !names.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(names, id: \.self) { name in
                            AttachedPicture(url: editor.referenceURL(name))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
                Text(text)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Color.accentColor.opacity(0.85), in: RoundedRectangle(cornerRadius: 19, style: .continuous))
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.leading, 56)
                    .textSelection(.enabled)
                reply
            case .filter(let name):
                Caption(text: L10n.appliedFilter(name))
                card
            case .restore:
                Caption(text: L10n.restored)
                card
            case .startOver:
                Caption(text: L10n.backToOriginal)
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
            WorkingCard(editor: editor, steps: turn.steps.count)
        } else {
            ForEach(Array(turn.messages.enumerated()), id: \.offset) { _, message in
                Text(message)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("thread.reply")
            }
            if turn.result != nil { card }
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
            if !turn.steps.isEmpty {
                StepsSummary(id: "\(turn.id).steps", steps: turn.steps, cost: turn.cost, reveal: reveal)
            }
        }
    }

    @ViewBuilder
    private var card: some View {
        if let state = turn.result {
            let isCurrent = state == editor.state
            PhotoCard(editor: editor, state: state)
                .onTapGesture { open(turn) }
                .contextMenu {
                    Button(L10n.open, systemImage: "arrow.up.left.and.arrow.down.right") { open(turn) }
                    if !isCurrent {
                        Button(L10n.restoreVersion, systemImage: "clock.arrow.circlepath") { editor.restore(state) }
                            .disabled(editor.isWorking)
                    }
                    Button(L10n.sharePhoto, systemImage: "square.and.arrow.up") { share(state, .jpeg) }
                }
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier(turn.kind == .original ? "thread.original" : "thread.version")
        }
    }
}

/// A picture waiting to be sent with the next instruction.
private struct Attachment: Identifiable {
    let id = UUID()
    /// A temporary copy, moved into the photo's folder when sent.
    let url: URL
    let name: String
    let thumbnail: UIImage?
}

/// A picture sent with an instruction, above its words.
private struct AttachedPicture: View {
    let url: URL
    @State private var image: UIImage?

    var body: some View {
        Color(white: 0.12)
            .frame(width: 96, height: 96)
            .overlay {
                if let image { Image(uiImage: image).resizable().scaledToFill().transition(.opacity) }
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .task(id: url) {
                let url = url
                image = await Task.detached { Thumbnails.image(at: url, maxPixel: 300) }.value
            }
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

/// One version of the photo in the thread.
private struct PhotoCard: View {
    let editor: PhotoEditor
    let state: EditingState
    @State private var image: CGImage?

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .transition(.opacity)
            } else {
                Color(white: 0.1)
                    .aspectRatio(CGFloat(editor.info.width) / CGFloat(max(1, editor.info.height)), contentMode: .fit)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .frame(maxWidth: .infinity)
        .animation(.easeOut(duration: 0.25), value: image != nil)
        .task(id: state) {
            image = await editor.picture(of: state)
        }
    }
}

/// The photo while the assistant works on it: it changes as each step lands.
private struct WorkingCard: View {
    let editor: PhotoEditor
    let steps: Int

    var body: some View {
        ZStack {
            if let image = editor.image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .id(editor.imageVersion)
                    .transition(.opacity)
            } else {
                Color(white: 0.1).aspectRatio(4 / 3, contentMode: .fit)
            }
        }
        .animation(.easeInOut(duration: 0.45), value: editor.imageVersion)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(alignment: .bottomLeading) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).tint(.white)
                Text(steps == 0 ? L10n.looking : L10n.step(steps))
                    .font(.footnote.weight(.medium))
                    .monospacedDigit()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .glassEffect(.regular, in: .capsule)
            .padding(10)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("thread.working")
    }
}

/// What the assistant's scripts did, in words. Folded away until asked for.
private struct StepsSummary: View {
    let id: String
    let steps: [Step]
    let cost: Double?
    let reveal: (String) -> Void
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.snappy) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Text(L10n.stepsCount(steps.count))
                    if let cost { Text(verbatim: "· \(UsageLedger.dollars(cost))") }
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("thread.steps")
            if expanded {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                        StepView(number: index + 1, step: step)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(white: 0.1), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .id(id)
            }
        }
        .onChange(of: expanded) { _, isExpanded in
            guard isExpanded else { return }
            Task {
                // Bring the steps onto the screen once they are laid out, and again once they have
                // settled; the second time does nothing if they are already there.
                for delay in [60, 400] {
                    try? await Task.sleep(for: .milliseconds(delay))
                    reveal(id)
                }
            }
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
        case .failed: return "exclamationmark.triangle.fill"
        case .stale: return "arrow.triangle.2.circlepath"
        }
    }

    private var tint: Color {
        switch step.outcome {
        case .applied: return .green
        case .failed: return .orange
        default: return .secondary
        }
    }
}

// MARK: - Full screen

/// One version, filling the screen: zoom in, hold Before to compare, share it, or bring it back.
private struct PhotoViewer: View {
    @Environment(\.dismiss) private var dismiss
    let editor: PhotoEditor
    let item: Viewed
    @State private var image: CGImage?
    @State private var beforeImage: CGImage?
    @State private var comparing = false
    @State private var shared: SharedFiles?
    @State private var exporting = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let shown = comparing ? (beforeImage ?? image) : image {
                ZoomablePhoto(image: shown)
            } else {
                ProgressView().tint(.white)
            }
        }
        .overlay(alignment: .top) {
            HStack {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark").font(.body.weight(.semibold)).frame(width: 30, height: 30)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .accessibilityLabel(L10n.close)
                .accessibilityIdentifier("viewer.close")
                Spacer()
                if comparing {
                    Text(L10n.before)
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .glassEffect(.regular, in: .capsule)
                }
                Spacer()
                if exporting {
                    ProgressView().frame(width: 44, height: 44)
                } else {
                    Menu {
                        Button(L10n.shareJPEG) { share(.jpeg) }
                        Button(L10n.shareHEIC) { share(.heic) }
                    } label: {
                        Image(systemName: "square.and.arrow.up").font(.body.weight(.semibold)).frame(width: 30, height: 30)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .accessibilityLabel(L10n.sharePhoto)
                    .accessibilityIdentifier("viewer.share")
                }
            }
            .padding(.horizontal, 16)
        }
        .overlay(alignment: .bottom) {
            HStack {
                if item.before != nil {
                    Text(L10n.before)
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                        .glassEffect(.regular.interactive(), in: .capsule)
                        .onLongPressGesture(minimumDuration: 0, maximumDistance: 60, perform: {}, onPressingChanged: { comparing = $0 })
                        .accessibilityAddTraits(.isButton)
                        .accessibilityHint(L10n.beforeHint)
                        .accessibilityIdentifier("viewer.compare")
                }
                Spacer()
                if !item.isCurrent {
                    Button(L10n.restore) {
                        editor.restore(item.state)
                        dismiss()
                    }
                    .font(.subheadline.weight(.semibold))
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .disabled(editor.isWorking)
                    .accessibilityIdentifier("viewer.restore")
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
        .statusBarHidden()
        .task {
            image = await editor.fullPicture(of: item.state)
            if let before = item.before { beforeImage = await editor.fullPicture(of: before) }
        }
        .sheet(item: $shared) { files in
            ShareSheet(urls: files.urls).presentationDetents([.medium, .large])
        }
    }

    private func share(_ format: ExportFormat) {
        guard !exporting else { return }
        exporting = true
        Task {
            defer { exporting = false }
            shared = (try? await editor.export(item.state, as: format)).map { SharedFiles([$0]) }
        }
    }
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
            .accessibilityIdentifier("viewer.photo")
    }

    private func reset() {
        zoom = 1
        settledZoom = 1
        offset = .zero
        settledOffset = .zero
    }
}
