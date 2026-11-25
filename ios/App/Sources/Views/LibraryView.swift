import OscuruCore
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

/// Home: your styles, your photos, and the camera. A photo opens as a conversation; a style is
/// tapped and then the photos it goes on; Select chooses photos to share or delete.
struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @State private var path: [String] = []
    @State private var problem: String?
    @State private var showingSettings = false
    @Namespace private var transition

    /// Adding photos: from the camera, the photo library, or files.
    @State private var showingCamera = false
    /// A photo to open once the camera has finished closing, so the two transitions don't overlap.
    @State private var openAfterCamera: String?
    @State private var choosingPhotos = false
    @State private var picked: [PhotosPickerItem] = []
    @State private var choosingFile = false
    @State private var importing = false

    /// Styles: making one, renaming one, and putting one on photos chosen in the grid.
    @State private var creatingStyle = false
    @State private var applying: Style?
    @State private var styling = false
    @State private var renaming: Style?
    @State private var styleName = ""

    /// The photos chosen while selecting; nil when not selecting.
    @State private var selection: Set<String>?
    @State private var confirmingDelete = false

    private var photos: [PhotoDocument] { model.library.photos }
    /// The chosen photos, in the library's order.
    private var chosen: [String] { photos.map(\.id).filter { selection?.contains($0) ?? false } }

    var body: some View {
        NavigationStack(path: $path) {
            withDialogs(withPickers(screen))
        }
    }

    private var screen: some View {
        Group {
            if photos.isEmpty {
                VStack(spacing: 0) {
                    styleStrip
                    ContentUnavailableView(L10n.libraryEmptyTitle, systemImage: "photo.on.rectangle.angled", description: Text(L10n.libraryEmptyMessage))
                        .frame(maxHeight: .infinity)
                }
            } else {
                // The styles stay while selecting, so the photos never move under the finger.
                PhotoGrid(photos: photos, selection: $selection) { styleStrip }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
        .background(Color.black.ignoresSafeArea())
        .navigationTitle(Text(verbatim: "Oscuru"))
        .toolbar { toolbar }
        .navigationDestination(for: String.self) { id in
            if let document = model.library.document(id) {
                PhotoView(document: document)
            }
        }
    }

    /// The camera and the ways to add photos.
    private func withPickers(_ content: some View) -> some View {
        content
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
            .photosPicker(isPresented: $choosingPhotos, selection: $picked, matching: .images, preferredItemEncoding: .current)
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
    }

    /// Sheets, questions and problems.
    private func withDialogs(_ content: some View) -> some View {
        content
            .sheet(isPresented: $showingSettings) { SettingsView() }
            .sheet(isPresented: $creatingStyle) { NewStyleView() }
            .styleNameAlert(L10n.rename, isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }), name: $styleName) {
                if let renaming { _ = model.styleStore.rename(id: renaming.id, to: styleName) }
            }
            .alert(L10n.importFailed, isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
                Button(L10n.ok, role: .cancel) {}
            } message: {
                Text(problem ?? "")
            }
            .confirmationDialog(L10n.deleteTitle(chosen.count), isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button(L10n.delete, role: .destructive) {
                    model.delete(chosen)
                    endSelecting()
                }
                Button(L10n.cancel, role: .cancel) {}
            } message: {
                Text(L10n.deleteMessage)
            }
            .onChange(of: photos.isEmpty) { _, empty in
                if empty { endSelecting() }
            }
    }

    // MARK: Styles

    /// Your styles, and the way to make one from pictures. Tap a style, then the photos it goes on.
    /// While selecting they rest, dimmed, except the style being put on.
    private var styleStrip: some View {
        let selecting = selection != nil
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 12) {
                Button {
                    creatingStyle = true
                } label: {
                    StyleTile(title: L10n.newStyle, isNew: true)
                }
                .buttonStyle(.plain)
                .disabled(selecting)
                .opacity(selecting ? 0.35 : 1)
                .accessibilityIdentifier("library.newStyle")
                ForEach(model.styles) { style in
                    Button {
                        applying = style
                        selection = []
                    } label: {
                        StyleTile(title: style.name, version: style.id) { [store = model.styleStore] in
                            guard let url = store.pictureURL(style.id) else { return nil }
                            return await Task.detached { UIImage(contentsOfFile: url.path)?.cgImage }.value
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(photos.isEmpty || selecting)
                    .opacity(!selecting || applying?.id == style.id ? 1 : 0.35)
                    .accessibilityLabel(style.name)
                    .accessibilityIdentifier("library.style")
                    .contextMenu {
                        Button(L10n.rename, systemImage: "pencil") {
                            styleName = style.name
                            renaming = style
                        }
                        Button(L10n.delete, systemImage: "trash", role: .destructive) { model.styleStore.delete(id: style.id) }
                    }
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.top, 4)
        .padding(.bottom, 16)
        .animation(.snappy(duration: 0.2), value: selecting)
    }

    private func apply(_ style: Style) {
        guard !chosen.isEmpty, !styling else { return }
        styling = true
        Task {
            await model.apply(style, to: chosen)
            styling = false
            endSelecting()
        }
    }

    private func endSelecting() {
        selection = nil
        applying = nil
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            if let selection {
                let all = selection.count == photos.count
                Button(all ? L10n.deselectAll : L10n.selectAll) {
                    self.selection = all ? [] : Set(photos.map(\.id))
                }
                .accessibilityIdentifier("library.selectAll")
            } else {
                Button(L10n.settings, systemImage: "gearshape") { showingSettings = true }
                    .accessibilityIdentifier("library.settings")
            }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            if selection != nil {
                Button(L10n.cancel) { endSelecting() }
                    .accessibilityIdentifier("library.endSelect")
            } else {
                if !photos.isEmpty {
                    Button(L10n.select) { selection = [] }
                        .accessibilityIdentifier("library.select")
                }
                if importing {
                    ProgressView()
                } else {
                    Menu(L10n.addPhoto, systemImage: "plus") {
                        Button(L10n.fromPhotos, systemImage: "photo.on.rectangle") { choosingPhotos = true }
                        Button(L10n.fromFiles, systemImage: "folder") { choosingFile = true }
                    }
                    .accessibilityIdentifier("library.add")
                }
            }
        }
    }

    // MARK: Bottom

    private static let camera = "camera"

    /// The camera, or while selecting: what to do with the chosen photos.
    @ViewBuilder
    private var bottomBar: some View {
        if selection == nil {
            cameraButton
        } else if let applying {
            styleBar(applying)
        } else {
            selectionBar
        }
    }

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

    private var chosenCount: String { chosen.isEmpty ? L10n.selectPhotos : L10n.selectedCount(chosen.count) }

    /// A style was tapped: what it goes on, and Apply.
    private func styleBar(_ style: Style) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(style.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(chosenCount)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer()
            if styling {
                ProgressView().frame(width: 44, height: 44)
            } else {
                Button(L10n.apply) { apply(style) }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .disabled(chosen.isEmpty)
                    .accessibilityIdentifier("library.applyStyle")
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    /// While selecting: share and save on the left, how many are chosen in the middle, delete on the right.
    private var selectionBar: some View {
        HStack {
            ShareButton(photos: chosen)
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
            SaveButton(photos: chosen)
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
            Spacer()
            Text(chosenCount)
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
            .disabled(chosen.isEmpty)
            .accessibilityLabel(L10n.delete)
            .accessibilityIdentifier("library.delete")
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
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
