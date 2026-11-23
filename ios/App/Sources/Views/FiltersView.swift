import OscuruCore
import SwiftUI

/// Saved filters: apply one to this photo, or save this photo's look as a new one.
struct FiltersView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let editor: PhotoEditor
    @State private var name = ""
    @State private var renaming: SavedFilter?
    @State private var newName = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField(L10n.filterNamePlaceholder, text: $name)
                            .submitLabel(.done)
                            .onSubmit(save)
                            .accessibilityIdentifier("filters.name")
                        Button(L10n.save, action: save)
                            .disabled(FilterCollection.cleanName(name).isEmpty)
                            .accessibilityIdentifier("filters.save")
                    }
                } header: {
                    Text(L10n.filterSaveTitle)
                } footer: {
                    Text(L10n.filterSaveFooter)
                }

                if !model.filters.isEmpty {
                    Section(L10n.filterSavedTitle) {
                        ForEach(model.filters) { filter in
                            Button {
                                editor.apply(filter)
                                dismiss()
                            } label: {
                                HStack(spacing: 12) {
                                    FilterPreview(editor: editor, filter: filter)
                                    Text(filter.name).foregroundStyle(.primary)
                                    Spacer()
                                }
                            }
                            .accessibilityIdentifier("filters.item")
                            .swipeActions {
                                Button(L10n.delete, systemImage: "trash", role: .destructive) { model.filterStore.delete(id: filter.id) }
                                Button(L10n.rename, systemImage: "pencil") {
                                    newName = filter.name
                                    renaming = filter
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(L10n.filters)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.done) { dismiss() }
                        .accessibilityIdentifier("filters.done")
                }
            }
            .alert(L10n.rename, isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField(L10n.filterNamePlaceholder, text: $newName)
                Button(L10n.save) {
                    if let renaming { _ = model.filterStore.rename(id: renaming.id, to: newName) }
                }
                Button(L10n.cancel, role: .cancel) {}
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func save() {
        guard model.filterStore.save(name: name, look: editor.currentLook) else { return }
        name = ""
    }
}

/// A small picture of this photo with the filter applied.
private struct FilterPreview: View {
    let editor: PhotoEditor
    let filter: SavedFilter
    @State private var image: UIImage?

    var body: some View {
        Color(white: 0.14)
            .frame(width: 64, height: 64)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .task(id: filter) {
                let state = filter.look.applied(to: editor.state, defaults: editor.info.defaults)
                let renderer = editor.renderer
                image = await Task.detached { renderer.thumbnail(of: state, maxEdge: 192).flatMap(UIImage.init(data:)) }.value
            }
    }
}
