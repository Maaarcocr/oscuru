import SwiftUI
import UIKit

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
