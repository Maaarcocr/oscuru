import BackgroundTasks
import UIKit
import os

/// Keeps the assistant working when the app leaves the screen.
///
/// Work the person asked for (a message, Continue) runs as a continued processing task (iOS 26's
/// `BGContinuedProcessingTask`): it carries on while they use other apps, the system shows its
/// progress (each step the assistant takes) and lets them cancel it, which stops the assistant as
/// Stop does. Where the system will not start one, or for work the app took up again by itself,
/// iOS gives the usual short time to finish instead. Either way, if the app is suspended or
/// closed, the transcript has every step so far, and the work carries on when the photo is opened
/// again.
@MainActor
final class BackgroundWork {
    /// What stops the work when the person cancels it from the system's progress.
    var onCancel: (() -> Void)?

    private var grace: UIBackgroundTaskIdentifier = .invalid
    private var continued: BGContinuedProcessingTask?
    /// Whether a continued task was asked for in this run, and whether the run has ended (a task
    /// the system starts after that is done at once).
    private var asked = false
    private var ended = false
    private var steps: Int64 = 0

    private static let log = Logger(subsystem: "com.rudilosso.oscuru", category: "background")

    /// The prefix of each task's identifier, as listed (with a wildcard) under
    /// BGTaskSchedulerPermittedIdentifiers in Info.plist.
    private static var prefix: String { (Bundle.main.bundleIdentifier ?? "com.rudilosso.oscuru") + ".assistant." }

    /// The run starts. `asked` is whether the person asked for it just now, which a continued task
    /// needs; `title` and `subtitle` are what the system shows of it.
    func begin(asked byPerson: Bool, title: String, subtitle: String) {
        ended = false
        steps = 0
        if grace == .invalid {
            grace = UIApplication.shared.beginBackgroundTask(withName: "Assistant") { [weak self] in
                MainActor.assumeIsolated { self?.endGrace() }
            }
        }
        guard byPerson, !asked, continued == nil, !UITesting.isActive else { return }
        asked = true
        let identifier = BackgroundWork.prefix + UUID().uuidString
        // On the main queue, so the handler is on the main actor.
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { [weak self] task in
            MainActor.assumeIsolated {
                guard let self, let continued = task as? BGContinuedProcessingTask else {
                    task.setTaskCompleted(success: false)
                    return
                }
                self.started(continued)
            }
        }
        guard registered else {
            BackgroundWork.log.error("The assistant's background task could not be registered.")
            return
        }
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: subtitle)
        // Now or not at all: queued, it could start after the work is done.
        request.strategy = .fail
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            BackgroundWork.log.error("The assistant's background task was refused: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The assistant took a step: a request to the model, or a script.
    func step() {
        steps += 1
        show()
    }

    /// The run is over: the system's progress finishes, and the app may be suspended.
    func end() {
        ended = true
        asked = false
        if let continued {
            continued.progress.completedUnitCount = continued.progress.totalUnitCount
            continued.setTaskCompleted(success: true)
            self.continued = nil
        }
        endGrace()
    }

    private func started(_ task: BGContinuedProcessingTask) {
        guard !ended else {
            task.setTaskCompleted(success: true)
            return
        }
        continued = task
        task.expirationHandler = { [weak self] in
            DispatchQueue.main.async { self?.expired() }
        }
        show()
    }

    /// The progress so far: each step done, and always one more to come until the work ends.
    private func show() {
        guard let continued else { return }
        continued.progress.totalUnitCount = steps + 1
        continued.progress.completedUnitCount = steps
    }

    /// The person cancelled the work from the system's progress, or the system stopped it.
    private func expired() {
        guard let continued else { return }
        self.continued = nil
        continued.setTaskCompleted(success: false)
        onCancel?()
    }

    private func endGrace() {
        guard grace != .invalid else { return }
        UIApplication.shared.endBackgroundTask(grace)
        grace = .invalid
    }
}
