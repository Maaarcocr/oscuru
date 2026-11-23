import OscuruCore
import SwiftUI

/// Saved looks, shown on this photo: tap one to apply it. Below, save the photo's own look.
struct FiltersView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let editor: PhotoEditor
    @State private var name = ""
    @State private var renaming: SavedFilter?
    @State private var newName = ""
    @FocusState private var naming: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(L10n.filters).font(.headline)
                Spacer()
                Button(L10n.done) { dismiss() }
                    .buttonStyle(.glass)
                    .accessibilityIdentifier("filters.done")
            }
            .padding(.horizontal, 20)

            if model.filters.isEmpty {
                Text(L10n.filtersEmpty)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 110, alignment: .center)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(model.filters) { filter in
                            Button {
                                editor.apply(filter)
                                dismiss()
                            } label: {
                                VStack(spacing: 7) {
                                    FilterPreview(editor: editor, filter: filter)
                                    Text(filter.name)
                                        .font(.caption.weight(.medium))
                                        .lineLimit(1)
                                        .frame(width: 92)
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(filter.name)
                            .accessibilityIdentifier("filters.item")
                            .contextMenu {
                                Button(L10n.rename, systemImage: "pencil") {
                                    newName = filter.name
                                    renaming = filter
                                }
                                Button(L10n.delete, systemImage: "trash", role: .destructive) { model.filterStore.delete(id: filter.id) }
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                }
                .frame(height: 118)
            }

            HStack(spacing: 8) {
                TextField(L10n.filterNamePlaceholder, text: $name)
                    .focused($naming)
                    .submitLabel(.done)
                    .onSubmit(save)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .glassEffect(.regular, in: .capsule)
                    .accessibilityIdentifier("filters.name")
                Button(L10n.save, action: save)
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .disabled(FilterCollection.cleanName(name).isEmpty)
                    .accessibilityIdentifier("filters.save")
            }
            .padding(.horizontal, 20)
        }
        .padding(.top, 22)
        .padding(.bottom, 12)
        .presentationDetents([.height(300)])
        .presentationDragIndicator(.visible)
        .alert(L10n.rename, isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField(L10n.filterNamePlaceholder, text: $newName)
            Button(L10n.save) {
                if let renaming { _ = model.filterStore.rename(id: renaming.id, to: newName) }
            }
            Button(L10n.cancel, role: .cancel) {}
        }
    }

    private func save() {
        guard model.filterStore.save(name: name, look: editor.currentLook) else { return }
        name = ""
        naming = false
    }
}

/// This photo with the filter applied.
private struct FilterPreview: View {
    let editor: PhotoEditor
    let filter: SavedFilter
    @State private var image: UIImage?

    var body: some View {
        Color(white: 0.14)
            .frame(width: 92, height: 92)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill().transition(.opacity)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .animation(.easeOut(duration: 0.25), value: image != nil)
            .task(id: filter) {
                let state = filter.look.applied(to: editor.state, defaults: editor.info.defaults)
                let renderer = editor.renderer
                image = await Task.detached { renderer.thumbnail(of: state, maxEdge: 240).flatMap(UIImage.init(data:)) }.value
            }
    }
}
