import SwiftUI

/// Saves photos to the person's photo library, developed as JPEGs with their edits, in one tap.
/// The button shows a tick for a moment when they are in; Photos files each under when it was taken.
struct SaveButton: View {
    @Environment(AppModel.self) private var model
    /// The photos to save, in order.
    let photos: [String]
    @State private var saving = false
    @State private var saved = false
    @State private var problem: String?

    var body: some View {
        Button {
            save()
        } label: {
            ZStack {
                if saving {
                    ProgressView()
                } else {
                    Image(systemName: saved ? "checkmark" : "square.and.arrow.down")
                        .font(.body.weight(.semibold))
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .frame(width: 30, height: 30)
        }
        .disabled(photos.isEmpty || saving)
        .sensoryFeedback(.success, trigger: saved) { _, now in now }
        .accessibilityLabel(saved ? L10n.savedToPhotos : L10n.saveToPhotos)
        .accessibilityIdentifier("save")
        .alert(L10n.saveFailed, isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button(L10n.ok, role: .cancel) {}
        } message: {
            Text(problem ?? "")
        }
    }

    private func save() {
        guard !saving else { return }
        saving = true
        Task {
            do {
                try await model.saveToPhotos(photos)
                saving = false
                saved = true
                AccessibilityNotification.Announcement(L10n.savedToPhotos).post()
                try? await Task.sleep(for: .seconds(1.5))
                saved = false
            } catch is PhotosAccessDenied {
                saving = false
                problem = L10n.photosDenied
            } catch {
                saving = false
                problem = String(describing: error)
            }
        }
    }
}
