import UIKit

/// Asks iOS for time to finish when the app leaves the screen while the assistant works, so a
/// request on its way can come back. If the time runs out, the app may be suspended or closed:
/// the transcript has every step so far, and the work carries on when the photo is opened again.
@MainActor
final class BackgroundWork {
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    func begin() {
        guard identifier == .invalid else { return }
        identifier = UIApplication.shared.beginBackgroundTask(withName: "Assistant") { [weak self] in
            MainActor.assumeIsolated { self?.end() }
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
