import OscuruEngine
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// A photo picked from the system library, as the file it is stored as (the RAW file when there is one).
private struct PickedPhoto: Transferable {
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

    /// Choosing photos to share or delete, as in Photos.
    @State private var selecting = false
    @State private var selection: Set<String> = []
    @State private var confirmingDelete = false
    @State private var exporting = false
    @State private var shared: SharedFiles?

    /// Three squares a row with hairline gaps, like Photos.
    private static let gap: CGFloat = 2
    private let columns = Array(repeating: GridItem(.flexible(), spacing: LibraryView.gap), count: 3)

    private var photos: [PhotoDocument] { model.library.photos }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if photos.isEmpty {
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
    }

    // MARK: Grid

    private var grid: some View {
        ScrollView {
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
    }

    private func toggle(_ id: String) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }

    private func endSelecting() {
        selecting = false
        selection = []
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

    /// While selecting: share on the left, how many are chosen in the middle, delete on the right.
    private var selectionBar: some View {
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
            Spacer()
            Text(none ? L10n.selectPhotos : L10n.selectedCount(selection.count))
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(.snappy, value: selection.count)
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
