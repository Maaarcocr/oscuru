import OscuruCore
import PhotosUI
import SwiftUI

/// Making a style from pictures: the edited photo whose look you want, and, for an exact copy,
/// the same photo before it was edited. Ends by showing the style at work.
struct NewStyleView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var edited: Picked?
    @State private var original: Picked?
    @State private var editedItem: PhotosPickerItem?
    @State private var originalItem: PhotosPickerItem?
    @State private var name = ""
    @State private var creating = false
    @State private var result: AppModel.StyleResult?
    @State private var problem: String?
    @FocusState private var naming: Bool

    private struct Picked {
        /// A temporary copy, removed when the sheet closes.
        let url: URL
        let thumbnail: UIImage?
    }

    var body: some View {
        NavigationStack {
            Group {
                if let result {
                    finished(result)
                } else {
                    form
                }
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle(result?.style.name ?? L10n.newStyle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if result == nil {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(L10n.cancel) { dismiss() }
                            .accessibilityIdentifier("style.cancel")
                    }
                } else {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L10n.done) { dismiss() }
                            .accessibilityIdentifier("style.done")
                    }
                }
            }
            .alert(L10n.styleFailed, isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
                Button(L10n.ok, role: .cancel) {}
            } message: {
                Text(problem ?? "")
            }
        }
        .onChange(of: editedItem) { _, item in load(item) { edited = $0 } }
        .onChange(of: originalItem) { _, item in load(item) { original = $0 } }
        .onDisappear {
            for picked in [edited, original].compactMap({ $0 }) { try? FileManager.default.removeItem(at: picked.url) }
        }
    }

    // MARK: Choosing

    private var form: some View {
        ScrollView {
            VStack(spacing: 22) {
                Text(explanation)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 8)
                    .contentTransition(.opacity)
                    .animation(.easeInOut(duration: 0.25), value: explanation)
                HStack(alignment: .top, spacing: 14) {
                    slot(edited, item: $editedItem, title: L10n.styleEdited, hint: L10n.styleEditedHint, identifier: "style.edited") { edited = nil }
                    slot(original, item: $originalItem, title: L10n.styleOriginal, hint: L10n.styleOriginalHint, identifier: "style.original") { original = nil }
                }
                TextField(L10n.styleNamePlaceholder, text: $name)
                    .focused($naming)
                    .submitLabel(.done)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(Color(white: 0.15), in: Capsule())
                    .accessibilityIdentifier("style.name")
            }
            .padding(20)
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) {
            Button {
                create()
            } label: {
                HStack(spacing: 10) {
                    if creating { ProgressView() }
                    Text(L10n.createStyle)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .disabled(edited == nil || StyleCollection.cleanName(name).isEmpty || creating)
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
            .accessibilityIdentifier("style.create")
        }
    }

    private var explanation: String {
        if edited == nil { return L10n.styleIntro }
        return original == nil ? L10n.styleSingle : L10n.stylePair
    }

    /// One picture: a dashed tile to choose it, then the picture with a way to take it out.
    private func slot(_ picked: Picked?, item: Binding<PhotosPickerItem?>, title: String, hint: String, identifier: String, clear: @escaping () -> Void) -> some View {
        VStack(spacing: 8) {
            PhotosPicker(selection: item, matching: .images, preferredItemEncoding: .current) {
                ZStack {
                    Color(white: 0.09)
                    if let image = picked?.thumbnail {
                        Image(uiImage: image).resizable().scaledToFill().transition(.opacity)
                    } else {
                        VStack(spacing: 8) {
                            Image(systemName: "plus")
                                .font(.title2.weight(.semibold))
                                .foregroundStyle(Color.accentColor)
                            Text(title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white)
                        }
                    }
                }
                .aspectRatio(3 / 4, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay {
                    if picked == nil {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(Color(white: 0.3), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                    }
                }
            }
            .buttonStyle(.plain)
            .overlay(alignment: .topTrailing) {
                if picked != nil {
                    Button {
                        if let picked { try? FileManager.default.removeItem(at: picked.url) }
                        withAnimation(.snappy) { clear() }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 24))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(Color.white, Color.black.opacity(0.55))
                    }
                    .padding(8)
                    .accessibilityLabel(L10n.removePicture)
                }
            }
            .accessibilityIdentifier(identifier)
            // The tile names the picture until one is chosen; then its name moves below it.
            Text(picked == nil ? hint : title)
                .font(picked == nil ? .caption : .footnote.weight(.semibold))
                .foregroundStyle(picked == nil ? Color.secondary : Color.primary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }

    private func load(_ item: PhotosPickerItem?, into assign: @escaping (Picked) -> Void) {
        guard let item else { return }
        Task {
            guard let photo = try? await item.loadTransferable(type: PickedPhoto.self) else { return }
            let thumbnail = await Task.detached { Thumbnails.image(at: photo.url, maxPixel: 700) }.value
            withAnimation(.snappy) { assign(Picked(url: photo.url, thumbnail: thumbnail)) }
        }
    }

    private func create() {
        guard let edited, !creating else { return }
        creating = true
        naming = false
        Task {
            defer { creating = false }
            do {
                let made = try await model.createStyle(name: name, edited: edited.url, original: original?.url)
                withAnimation(.snappy) { result = made }
            } catch let failure as LookFitting.Failure {
                if case .framing = failure { problem = L10n.styleFraming } else { problem = String(describing: failure) }
            } catch {
                problem = String(describing: error)
            }
        }
    }

    // MARK: Done

    /// The style at work: the original with it beside the edit, or one of your photos beside the look.
    private func finished(_ result: AppModel.StyleResult) -> some View {
        let pair = result.error != nil
        return ScrollView {
            VStack(spacing: 18) {
                HStack(alignment: .top, spacing: 12) {
                    if let styled = result.styled {
                        picture(styled, caption: pair ? L10n.styleResultStyled : L10n.styleResultOnYours)
                    }
                    if let reference = result.reference {
                        picture(reference, caption: pair ? L10n.styleResultEdit : L10n.styleResultReference)
                    }
                }
                if let error = result.error {
                    Text(error < 6 ? L10n.styleVeryClose : L10n.styleClose)
                        .font(.subheadline.weight(.semibold))
                        .multilineTextAlignment(.center)
                }
                Text(L10n.styleSaved)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(20)
        }
        .accessibilityIdentifier("style.result")
    }

    private func picture(_ image: CGImage, caption: String) -> some View {
        VStack(spacing: 8) {
            Image(decorative: image, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }
}
