import OscuruCore
import OscuruEngine
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// A photo picked from the system library, as the file it is stored as (the RAW file when there is one).
struct PickedPhoto: Transferable {
    let url: URL

    static func keep(_ received: ReceivedTransferredFile) throws -> PickedPhoto {
        // The received file only lives for the length of this call: copy it.
        let copy = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString)-\(received.file.lastPathComponent)")
        try FileManager.default.copyItem(at: received.file, to: copy)
        return PickedPhoto(url: copy)
    }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .rawImage, importing: keep)
        FileRepresentation(importedContentType: .image, importing: keep)
    }
}

struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @State private var picked: [PhotosPickerItem] = []
    @State private var choosingFile = false
    @State private var importing = false
    @State private var problem: String?
    @State private var showingSettings = false
    @State private var showingCamera = false
    /// A photo to open once the camera has finished closing, so the two transitions don't overlap.
    @State private var openAfterCamera: String?
    @State private var path: [String] = []
    @Namespace private var transition

    /// Styles: making one, and putting one on photos chosen in the grid.
    @State private var creatingStyle = false
    @State private var applyingStyle: SavedFilter?
    @State private var styling = false
    @State private var renamingStyle: SavedFilter?
    @State private var styleName = ""

    /// Choosing photos to share or delete, as in Photos.
    @State private var selecting = false
    @State private var selection: Set<String> = []
    @State private var confirmingDelete = false
    @State private var exporting = false
    @State private var shared: SharedFiles?
    /// A finger run across the grid, selecting (or deselecting) everything it passes, as in Photos.
    @State private var run: SelectionRun?
    @State private var gridWidth: CGFloat = 0
    @State private var scrollMetrics = ScrollMetrics()
    @State private var autoScroll: Task<Void, Never>?

    private struct SelectionRun {
        var start: Int
        /// Whether the run selects (it started on an unselected photo) or deselects.
        var adding: Bool
        /// The selection before the run, so moving back undoes what the run passed.
        var base: Set<String>
        /// Where the finger last was in the grid, the scroll offset then, and its height on screen.
        var finger: CGPoint
        var offsetAtFinger: CGFloat
        var screenY: CGFloat
    }

    private struct ScrollMetrics: Equatable {
        var offset: CGFloat = 0
        var insetTop: CGFloat = 0
        var insetBottom: CGFloat = 0
        var height: CGFloat = 0
    }

    private static let gridSpace = "library.grid"
    private static let viewportSpace = "library.viewport"
    static var gridSpaceName: String { gridSpace }
    static var viewportSpaceName: String { viewportSpace }

    /// Three squares a row with hairline gaps, like Photos.
    private static let gap: CGFloat = 2
    private let columns = Array(repeating: GridItem(.flexible(), spacing: LibraryView.gap), count: 3)

    private var photos: [PhotoDocument] { model.library.photos }

    var body: some View {
        NavigationStack(path: $path) {
            withDialogs(withPickers(screen))
        }
    }

    /// The library itself: styles, the grid, the bar at the bottom, and where photos open.
    private var screen: some View {
        Group {
            if photos.isEmpty {
                VStack(spacing: 0) {
                    stylesRow.padding(.top, 8)
                ContentUnavailableView {
                    Label(L10n.libraryEmptyTitle, systemImage: "photo.on.rectangle.angled")
                } description: {
                    Text(L10n.libraryEmptyMessage)
                } actions: {
                    // The camera button below is the main way in; these bring in photos you have.
                    PhotosPicker(selection: $picked, matching: .images, preferredItemEncoding: .current) {
                        Text(L10n.fromPhotos)
                    }
                    .buttonStyle(.glass)
                    Button(L10n.fromFiles) { choosingFile = true }
                        .buttonStyle(.glass)
                }
                .frame(maxHeight: .infinity)
                }
            } else {
                grid
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if selecting { selectionBar } else { cameraButton }
        }
        .background(Color.black.ignoresSafeArea())
        .navigationTitle(Text(verbatim: "Oscuru"))
        .toolbar { toolbar }
        .navigationDestination(for: String.self) { id in
            if let document = model.library.document(id) {
                PhotoView(document: document)
            }
        }
        .sheet(isPresented: $showingSettings) { SettingsView() }
        .sheet(isPresented: $creatingStyle) { NewStyleView() }
        .alert(L10n.rename, isPresented: Binding(get: { renamingStyle != nil }, set: { if !$0 { renamingStyle = nil } })) {
            TextField(L10n.filterNamePlaceholder, text: $styleName)
            Button(L10n.save) {
                if let renamingStyle { _ = model.filterStore.rename(id: renamingStyle.id, to: styleName) }
            }
            Button(L10n.cancel, role: .cancel) {}
        }
    }

    /// The share sheet, the camera and the ways to add photos.
    private func withPickers(_ content: some View) -> some View {
        content
            .sheet(item: $shared) { files in
                ShareSheet(urls: files.urls).presentationDetents([.medium, .large])
            }
            .fullScreenCover(isPresented: $showingCamera, onDismiss: {
                if let id = openAfterCamera {
                    openAfterCamera = nil
                    path = [id]
                }
            }) {
                CameraView(library: model.library, simulated: UITesting.isActive) { id in
                    openAfterCamera = id
                    showingCamera = false
                }
                .navigationTransition(.zoom(sourceID: LibraryView.camera, in: transition))
            }
            .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.rawImage, .image], allowsMultipleSelection: true) { result in
                guard case .success(let urls) = result else { return }
                add(urls.map { url in
                    (name: url.lastPathComponent, fetch: {
                        // Files outside the app need permission for the length of the copy.
                        let scoped = url.startAccessingSecurityScopedResource()
                        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                        let copy = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString)-\(url.lastPathComponent)")
                        try FileManager.default.copyItem(at: url, to: copy)
                        return copy
                    })
                })
            }
            .onChange(of: picked) { _, items in
                guard !items.isEmpty else { return }
                picked = []
                add(items.map { item in
                    (name: nil, fetch: {
                        guard let photo = try await item.loadTransferable(type: PickedPhoto.self) else { throw CocoaError(.fileReadUnknown) }
                        return photo.url
                    })
                })
            }
            .onChange(of: photos.isEmpty) { _, empty in
                if empty { endSelecting() }
            }
    }

    /// Questions and problems.
    private func withDialogs(_ content: some View) -> some View {
        content
            .alert(L10n.importFailed, isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
                Button(L10n.ok, role: .cancel) {}
            } message: {
                Text(problem ?? "")
            }
            .confirmationDialog(L10n.deleteTitle(selection.count), isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button(L10n.delete, role: .destructive) {
                    for id in selection { model.library.delete(id: id) }
                    endSelecting()
                }
                Button(L10n.cancel, role: .cancel) {}
            } message: {
                Text(L10n.deleteMessage)
            }
    }

    // MARK: Grid

    private var grid: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if !selecting {
                    stylesRow.padding(.top, 4).padding(.bottom, 14)
                }
                gridContent
                    .coordinateSpace(.named(LibraryView.gridSpace))
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { gridWidth = $0 }
                    .gesture(
                        SelectionPan(
                            isEnabled: selecting,
                            began: { start, finger, screenY in beginRun(at: start, finger: finger, screenY: screenY) },
                            moved: { finger, screenY in moveRun(to: finger, screenY: screenY, proxy: proxy) },
                            ended: endRun))
            }
            .coordinateSpace(.named(LibraryView.viewportSpace))
            .onScrollGeometryChange(for: ScrollMetrics.self) { geometry in
                ScrollMetrics(
                    offset: geometry.contentOffset.y, insetTop: geometry.contentInsets.top, insetBottom: geometry.contentInsets.bottom,
                    height: geometry.containerSize.height)
            } action: { _, metrics in
                scrollMetrics = metrics
                // Content moving under a still finger extends the run too.
                if run != nil { extendRun() }
            }
        }
    }

    private var gridContent: some View {
        LazyVGrid(columns: columns, spacing: LibraryView.gap) {
                ForEach(photos) { photo in
                    let thumbnail = Thumbnail(
                        url: model.library.thumbnailURL(photo.id), stamp: photo.thumbnailStamp, isRaw: photo.info.isRaw,
                        selected: selecting ? selection.contains(photo.id) : nil)
                    if selecting {
                        Button {
                            toggle(photo.id)
                        } label: {
                            thumbnail
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("library.photo")
                        .accessibilityLabel(photo.name)
                        .accessibilityAddTraits(selection.contains(photo.id) ? .isSelected : [])
                    } else {
                        NavigationLink(value: photo.id) {
                            thumbnail
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("library.photo")
                        .accessibilityLabel(photo.name)
                        .contextMenu {
                            Button(L10n.select, systemImage: "checkmark.circle") {
                                selecting = true
                                selection = [photo.id]
                            }
                            Button(L10n.delete, systemImage: "trash", role: .destructive) { model.library.delete(id: photo.id) }
                        }
                    }
                }
            }
            // New shots slide in when the camera closes.
            .animation(.snappy, value: photos.map(\.id))
    }

    // MARK: Finger runs

    /// The photo under a point of the grid. Below the last photo counts as the last photo.
    private func index(at point: CGPoint) -> Int? {
        guard gridWidth > 0, !photos.isEmpty else { return nil }
        let pitch = (gridWidth - 2 * LibraryView.gap) / 3 + LibraryView.gap
        let column = min(2, max(0, Int(point.x / pitch)))
        let row = max(0, Int((point.y / pitch).rounded(.down)))
        return min(photos.count - 1, row * 3 + column)
    }

    private func beginRun(at start: CGPoint, finger: CGPoint, screenY: CGFloat) {
        guard let index = index(at: start) else { return }
        run = SelectionRun(
            start: index, adding: !selection.contains(photos[index].id), base: selection, finger: finger, offsetAtFinger: scrollMetrics.offset,
            screenY: screenY)
        extendRun()
    }

    private func moveRun(to finger: CGPoint, screenY: CGFloat, proxy: ScrollViewProxy) {
        guard run != nil else { return }
        run?.finger = finger
        run?.offsetAtFinger = scrollMetrics.offset
        run?.screenY = screenY
        extendRun()
        if autoScroll == nil, edgeDirection() != 0 {
            autoScroll = Task { await keepScrolling(proxy) }
        }
    }

    private func endRun() {
        run = nil
        autoScroll?.cancel()
        autoScroll = nil
    }

    /// Everything from where the run started to the photo under the finger takes the start's new state.
    private func extendRun() {
        guard let run else { return }
        let finger = CGPoint(x: run.finger.x, y: run.finger.y + scrollMetrics.offset - run.offsetAtFinger)
        guard let current = index(at: finger) else { return }
        let passed = photos[min(run.start, current)...max(run.start, current)].map(\.id)
        let next = run.adding ? run.base.union(passed) : run.base.subtracting(passed)
        if next != selection { selection = next }
    }

    /// −1 when the finger is near the top of the grid, 1 near the bottom, 0 elsewhere.
    private func edgeDirection() -> Int {
        guard let run else { return 0 }
        let zone: CGFloat = 70
        if run.screenY < scrollMetrics.insetTop + zone { return -1 }
        if run.screenY > scrollMetrics.height - scrollMetrics.insetBottom - zone { return 1 }
        return 0
    }

    /// While the finger rests near an edge, scrolls a row at a time so the run can go on.
    private func keepScrolling(_ proxy: ScrollViewProxy) async {
        defer { autoScroll = nil }
        while !Task.isCancelled, let run {
            let direction = edgeDirection()
            guard direction != 0 else { return }
            let finger = CGPoint(x: run.finger.x, y: run.finger.y + scrollMetrics.offset - run.offsetAtFinger)
            guard let current = index(at: finger) else { return }
            let target = min(photos.count - 1, max(0, current + 3 * direction))
            if target == current { return }
            withAnimation(.linear(duration: 0.2)) {
                proxy.scrollTo(photos[target].id, anchor: direction > 0 ? .bottom : .top)
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    private func toggle(_ id: String) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }

    private func endSelecting() {
        endRun()
        selecting = false
        selection = []
        applyingStyle = nil
    }

    // MARK: Styles

    /// Your styles, and the way to make a new one: from an edited photo, or an original and its edit.
    private var stylesRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.filters)
                .font(.title3.weight(.semibold))
                .padding(.horizontal, 16)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    Button {
                        creatingStyle = true
                    } label: {
                        StyleCard(title: L10n.newStyle, picture: nil, isNew: true)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("library.newStyle")
                    ForEach(model.filters) { style in
                        Button {
                            beginApplying(style)
                        } label: {
                            StyleCard(title: style.name, picture: model.filterStore.pictureURL(style.id), isNew: false)
                        }
                        .buttonStyle(.plain)
                        .disabled(photos.isEmpty)
                        .accessibilityIdentifier("library.style")
                        .contextMenu {
                            Button(L10n.applyToPhotos, systemImage: "checkmark.circle") { beginApplying(style) }
                                .disabled(photos.isEmpty)
                            Button(L10n.rename, systemImage: "pencil") {
                                styleName = style.name
                                renamingStyle = style
                            }
                            Button(L10n.delete, systemImage: "trash", role: .destructive) { model.filterStore.delete(id: style.id) }
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    /// Tapping a style: choose the photos it goes on.
    private func beginApplying(_ style: SavedFilter) {
        guard !photos.isEmpty else { return }
        selection = []
        applyingStyle = style
        selecting = true
    }

    private func apply(_ style: SavedFilter) {
        let chosen = photos.filter { selection.contains($0.id) }
        guard !chosen.isEmpty, !styling else { return }
        styling = true
        Task {
            await model.applyStyle(style, to: chosen)
            styling = false
            endSelecting()
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            if selecting {
                let all = selection.count == photos.count
                Button(all ? L10n.deselectAll : L10n.selectAll) {
                    selection = all ? [] : Set(photos.map(\.id))
                }
                .accessibilityIdentifier("library.selectAll")
            } else {
                Button(L10n.settings, systemImage: "gearshape") { showingSettings = true }
                    .accessibilityIdentifier("library.settings")
            }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            if selecting {
                Button(L10n.cancel) { endSelecting() }
                    .accessibilityIdentifier("library.endSelect")
            } else {
                if !photos.isEmpty {
                    Button(L10n.select) { selecting = true }
                        .accessibilityIdentifier("library.select")
                }
                if importing {
                    ProgressView()
                } else {
                    Menu(L10n.addPhoto, systemImage: "plus") {
                        PhotosPicker(selection: $picked, matching: .images, preferredItemEncoding: .current) {
                            Label(L10n.fromPhotos, systemImage: "photo.on.rectangle")
                        }
                        Button(L10n.fromFiles, systemImage: "folder") { choosingFile = true }
                    }
                    .accessibilityIdentifier("library.add")
                }
            }
        }
    }

    // MARK: Bottom

    private static let camera = "camera"

    /// The way to take a photo: at the bottom, where the composer is in a conversation and the
    /// shutter is in the camera, which grows out of it.
    private var cameraButton: some View {
        Button {
            showingCamera = true
        } label: {
            Image(systemName: "camera.fill")
                .font(.system(size: 22, weight: .semibold))
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.glassProminent)
        .buttonBorderShape(.circle)
        .controlSize(.extraLarge)
        .matchedTransitionSource(id: LibraryView.camera, in: transition)
        .accessibilityLabel(L10n.camera)
        .accessibilityIdentifier("library.camera")
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    /// While selecting: share and styles on the left, how many are chosen in the middle, delete on
    /// the right. When a style was tapped, just that: what to put it on, and Apply.
    @ViewBuilder
    private var selectionBar: some View {
        if let style = applyingStyle {
            styleBar(style)
        } else {
            actionsBar
        }
    }

    private func styleBar(_ style: SavedFilter) -> some View {
        let none = selection.isEmpty
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.chooseFor(style.name))
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(none ? L10n.selectPhotos : L10n.selectedCount(selection.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if styling {
                ProgressView().frame(width: 44, height: 44)
            } else {
                Button(L10n.apply) { apply(style) }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .disabled(none)
                    .accessibilityIdentifier("library.applyStyle")
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private var actionsBar: some View {
        let none = selection.isEmpty
        return HStack {
            if exporting {
                ProgressView().frame(width: 44, height: 44)
            } else {
                Menu {
                    Button(L10n.shareJPEG) { share(.jpeg) }
                    Button(L10n.shareHEIC) { share(.heic) }
                    Divider()
                    Button {
                        share(nil)
                    } label: {
                        Text(L10n.shareOriginals)
                        Text(L10n.shareOriginalsFooter)
                    }
                } label: {
                    Image(systemName: "square.and.arrow.up").font(.body.weight(.semibold)).frame(width: 30, height: 30)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .disabled(none)
                .accessibilityLabel(L10n.share)
                .accessibilityIdentifier("library.share")
            }
            if !model.filters.isEmpty {
                if styling {
                    ProgressView().frame(width: 44, height: 44)
                } else {
                    Menu {
                        ForEach(model.filters) { style in
                            Button(style.name) { apply(style) }
                        }
                    } label: {
                        Image(systemName: "camera.filters").font(.body.weight(.semibold)).frame(width: 30, height: 30)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .disabled(none)
                    .accessibilityLabel(L10n.applyStyle)
                    .accessibilityIdentifier("library.styleMenu")
                }
            }
            Spacer()
            Text(none ? L10n.selectPhotos : L10n.selectedCount(selection.count))
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
            Spacer()
            Button(role: .destructive) {
                confirmingDelete = true
            } label: {
                Image(systemName: "trash").font(.body.weight(.semibold)).frame(width: 30, height: 30)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .tint(.red)
            .disabled(none || exporting)
            .accessibilityLabel(L10n.delete)
            .accessibilityIdentifier("library.delete")
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    /// Exports the selected photos in the library's order: developed, or the original files.
    private func share(_ format: ExportFormat?) {
        guard !exporting else { return }
        let chosen = photos.filter { selection.contains($0.id) }
        guard !chosen.isEmpty else { return }
        exporting = true
        Task {
            defer { exporting = false }
            do {
                shared = SharedFiles(try await model.exportFiles(chosen, format: format))
            } catch {
                problem = String(describing: error)
            }
        }
    }

    // MARK: Adding photos

    /// Brings files into the library, one after another. `fetch` produces a temporary copy to
    /// import. A single photo opens straight away; several stay in the library to look at.
    private func add(_ sources: [(name: String?, fetch: () async throws -> URL)]) {
        guard !importing, !sources.isEmpty else { return }
        importing = true
        Task {
            defer { importing = false }
            var added: [PhotoDocument] = []
            var failures: [String] = []
            for source in sources {
                do {
                    let url = try await source.fetch()
                    defer { try? FileManager.default.removeItem(at: url) }
                    // Temporary copies are named "<uuid>-<original name>".
                    let fileName = source.name ?? String(url.lastPathComponent.dropFirst(37))
                    added.append(try await model.library.add(from: url, name: fileName.isEmpty ? url.lastPathComponent : fileName))
                } catch {
                    failures.append(String(describing: error))
                }
            }
            if sources.count == 1, let document = added.first { path = [document.id] }
            if !failures.isEmpty { problem = failures.joined(separator: "\n") }
        }
    }
}

/// A style in the library: the picture it was learned from, or a plain tile; its name below.
private struct StyleCard: View {
    let title: String
    let picture: URL?
    let isNew: Bool
    @State private var image: UIImage?

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Color(white: isNew ? 0.09 : 0.13)
                if let image {
                    Image(uiImage: image).resizable().scaledToFill().transition(.opacity)
                } else {
                    Image(systemName: isNew ? "plus" : "camera.filters")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(isNew ? Color.accentColor : Color.secondary)
                }
            }
            .frame(width: 84, height: 84)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                if isNew {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color(white: 0.3), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                }
            }
            Text(title)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .frame(width: 84)
        }
        .contentShape(Rectangle())
        .task(id: picture) {
            guard let picture, FileManager.default.fileExists(atPath: picture.path) else { return }
            image = await Task.detached { UIImage(contentsOfFile: picture.path) }.value
        }
    }
}

private struct Thumbnail: View {
    let url: URL
    let stamp: Int
    let isRaw: Bool
    /// Nil when not selecting; otherwise whether this photo is chosen.
    let selected: Bool?
    @State private var image: UIImage?

    var body: some View {
        Color(white: 0.12)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill().transition(.opacity)
                }
            }
            .clipped()
            .overlay(alignment: .bottomLeading) {
                if isRaw {
                    Text(verbatim: "RAW")
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .glassEffect(.regular, in: .capsule)
                        .padding(5)
                }
            }
            .overlay {
                if selected == true { Color.black.opacity(0.25) }
            }
            .overlay(alignment: .bottomTrailing) {
                if selected == true {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 22))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(Color.white, Color.accentColor)
                        .padding(5)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(.snappy(duration: 0.2), value: selected)
            .contentShape(Rectangle())
            .task(id: stamp) {
                let url = url
                image = await Task.detached { UIImage(contentsOfFile: url.path) }.value
            }
    }
}

/// A pan that starts sideways: in selection mode it runs a finger across photos to select them.
/// A pan that starts up or down is left to the scroll view, so the grid still scrolls.
private struct SelectionPan: UIGestureRecognizerRepresentable {
    var isEnabled: Bool
    /// Where the touch started and where the finger is, in the grid; the finger's height in the viewport.
    var began: (CGPoint, CGPoint, CGFloat) -> Void
    var moved: (CGPoint, CGFloat) -> Void
    var ended: () -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.maximumNumberOfTouches = 1
        pan.delegate = context.coordinator
        return pan
    }

    func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) {
        recognizer.isEnabled = isEnabled
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let finger = context.converter.location(in: .named(LibraryView.gridSpaceName))
        let screen = context.converter.location(in: .named(LibraryView.viewportSpaceName))
        switch recognizer.state {
        case .began:
            let moved = recognizer.translation(in: recognizer.view)
            began(CGPoint(x: finger.x - moved.x, y: finger.y - moved.y), finger, screen.y)
        case .changed:
            moved(finger, screen.y)
        default:
            ended()
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer else { return true }
            let velocity = pan.velocity(in: pan.view)
            return abs(velocity.x) > abs(velocity.y)
        }

        /// The scroll view waits to see whether a pan is a run before it scrolls.
        func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            other.view is UIScrollView
        }
    }
}
