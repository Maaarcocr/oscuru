import SwiftUI
import UIKit

/// The one way photos leave the app: developed, as JPEGs, or the original files untouched (a RAW
/// stays RAW). A menu with the two, then the system share sheet.
struct ShareButton: View {
    @Environment(AppModel.self) private var model
    /// The photos to share, in order.
    let photos: [String]
    @State private var exporting = false
    @State private var shared: SharedFiles?
    @State private var problem: String?

    var body: some View {
        Menu {
            Button {
                share(original: false)
            } label: {
                Text(L10n.shareDeveloped)
                Text(L10n.shareDevelopedFooter)
            }
            .accessibilityIdentifier("share.developed")
            Button {
                share(original: true)
            } label: {
                Text(L10n.shareOriginal)
                Text(L10n.shareOriginalFooter)
            }
            .accessibilityIdentifier("share.original")
        } label: {
            ZStack {
                if exporting {
                    ProgressView()
                } else {
                    Image(systemName: "square.and.arrow.up").font(.body.weight(.semibold))
                }
            }
            .frame(width: 30, height: 30)
        }
        .disabled(photos.isEmpty || exporting)
        .accessibilityLabel(L10n.share)
        .accessibilityIdentifier("share")
        .sheet(item: $shared) { files in
            ShareSheet(urls: files.urls).presentationDetents([.medium, .large])
        }
        .alert(L10n.exportFailed, isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button(L10n.ok, role: .cancel) {}
        } message: {
            Text(problem ?? "")
        }
    }

    private func share(original: Bool) {
        guard !exporting else { return }
        exporting = true
        Task {
            defer { exporting = false }
            do {
                shared = SharedFiles(try await model.export(photos, original: original))
            } catch {
                problem = String(describing: error)
            }
        }
    }
}

/// Files ready for the share sheet.
struct SharedFiles: Identifiable {
    let id = UUID()
    let urls: [URL]

    init(_ urls: [URL]) {
        self.urls = urls
    }
}

/// The system share sheet: save to Photos or Files, AirDrop, and so on.
struct ShareSheet: UIViewControllerRepresentable {
    let urls: [URL]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: urls, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
