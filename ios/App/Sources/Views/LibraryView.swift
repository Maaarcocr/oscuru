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
    @State private var picked: PhotosPickerItem?
    @State private var choosingFile = false
    @State private var importing = false
    @State private var problem: String?
    @State private var showingSettings = false
    @State private var showingCamera = false
    /// A photo to open once the camera has finished closing, so the two transitions don't overlap.
    @State private var openAfterCamera: String?
    @State private var path: [String] = []
    @Namespace private var transition

    private let columns = [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)]

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if model.library.photos.isEmpty {
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
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 6) {
                            ForEach(model.library.photos) { photo in
                                NavigationLink(value: photo.id) {
                                    Thumbnail(url: model.library.thumbnailURL(photo.id), stamp: photo.thumbnailStamp, isRaw: photo.info.isRaw)
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("library.photo")
                                .accessibilityLabel(photo.name)
                                .contextMenu {
                                    Button(L10n.delete, systemImage: "trash", role: .destructive) { model.library.delete(id: photo.id) }
                                }
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                        // New shots slide in when the camera closes.
                        .animation(.snappy, value: model.library.photos.map(\.id))
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { cameraButton }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle(Text(verbatim: "Oscuru"))
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L10n.settings, systemImage: "gearshape") { showingSettings = true }
                        .accessibilityIdentifier("library.settings")
                }
                ToolbarItem(placement: .topBarTrailing) {
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
            .navigationDestination(for: String.self) { id in
                if let document = model.library.document(id) {
                    PhotoView(document: document)
                }
            }
            .sheet(isPresented: $showingSettings) { SettingsView() }
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
            .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.rawImage, .image]) { result in
                guard case .success(let url) = result else { return }
                add(name: url.lastPathComponent) {
                    // Files outside the app need permission for the length of the copy.
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    let copy = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString)-\(url.lastPathComponent)")
                    try FileManager.default.copyItem(at: url, to: copy)
                    return copy
                }
            }
            .onChange(of: picked) { _, item in
                guard let item else { return }
                picked = nil
                add(name: nil) {
                    guard let photo = try await item.loadTransferable(type: PickedPhoto.self) else { throw CocoaError(.fileReadUnknown) }
                    return photo.url
                }
            }
            .alert(L10n.importFailed, isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
                Button(L10n.ok, role: .cancel) {}
            } message: {
                Text(problem ?? "")
            }
        }
    }

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

    /// Brings a file into the library and opens it. `fetch` produces a temporary copy to import.
    private func add(name: String?, fetch: @escaping () async throws -> URL) {
        guard !importing else { return }
        importing = true
        Task {
            defer { importing = false }
            do {
                let url = try await fetch()
                defer { try? FileManager.default.removeItem(at: url) }
                // Temporary copies are named "<uuid>-<original name>".
                let fileName = name ?? String(url.lastPathComponent.dropFirst(37))
                let document = try await model.library.add(from: url, name: fileName.isEmpty ? url.lastPathComponent : fileName)
                path = [document.id]
            } catch {
                problem = String(describing: error)
            }
        }
    }
}

private struct Thumbnail: View {
    let url: URL
    let stamp: Int
    let isRaw: Bool
    @State private var image: UIImage?

    var body: some View {
        Color(white: 0.12)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill().transition(.opacity)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(alignment: .bottomLeading) {
                if isRaw {
                    Text(verbatim: "RAW")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .glassEffect(.regular, in: .capsule)
                        .padding(8)
                }
            }
            .contentShape(Rectangle())
            .task(id: stamp) {
                let url = url
                image = await Task.detached { UIImage(contentsOfFile: url.path) }.value
            }
    }
}
