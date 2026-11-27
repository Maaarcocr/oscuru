import BackgroundTasks
import UIKit
import os

/// Keeps the assistant working when the app leaves the screen, for every photo it is working on.
///
/// Work the person asked for (a message, Continue) runs under one continued processing task for
/// the whole app (iOS 26's `BGContinuedProcessingTask`): it carries on while they use other apps,
/// the system shows its progress (each step any assistant takes) and lets them cancel it, which
/// stops every assistant as Stop does. It lasts until the last run ends, so one photo finishing
/// never leaves another to be suspended. Where the system will not start one, or for work the app
/// took up again by itself, iOS gives the usual short time to finish instead. Either way, if the
/// app is suspended or closed, each transcript has every step so far, and the work carries on when
/// its photo is opened again.
@MainActor
final class BackgroundWork {
    static let shared = BackgroundWork()

    private struct Run {
        var photo: String
        var steps: Int64 = 0
        var onCancel: () -> Void
    }

    /// The runs under way, by photo.
    private var runs: [String: Run] = [:]
    private var grace: UIBackgroundTaskIdentifier = .invalid
    private var continued: BGContinuedProcessingTask?
    /// A continued task asked for and not yet started or refused.
    private var asking = false

    private static let log = Logger(subsystem: "com.rudilosso.oscuru", category: "background")

    /// The prefix of each task's identifier, as listed (with a wildcard) under
    /// BGTaskSchedulerPermittedIdentifiers in Info.plist.
    private static var prefix: String { (Bundle.main.bundleIdentifier ?? "com.rudilosso.oscuru") + ".assistant." }

    /// A run starts on a photo (`id`, named `photo`). `asked` is whether the person asked for it
    /// just now, which a continued task needs; `about` is what was asked. `onCancel` stops it.
    func begin(_ id: String, photo: String, asked: Bool, about: String, onCancel: @escaping () -> Void) {
        runs[id] = Run(photo: photo, onCancel: onCancel)
        if grace == .invalid {
            grace = UIApplication.shared.beginBackgroundTask(withName: "Assistant") { [weak self] in
                MainActor.assumeIsolated { self?.endGrace() }
            }
        }
        show()
        guard asked, continued == nil, !asking, !UITesting.isActive else { return }
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
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: L10n.assistantBackgroundTitle(photo), subtitle: about)
        // Now or not at all: queued, it could start after the work is done.
        request.strategy = .fail
        asking = true
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            asking = false
            BackgroundWork.log.error("The assistant's background task was refused: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The run on `id` took a step: a request to the model, or a script.
    func step(_ id: String) {
        runs[id]?.steps += 1
        show()
    }

    /// The run on `id` is over. With none left, the system's progress finishes and the app may be suspended.
    func end(_ id: String) {
        runs[id] = nil
        show()
        guard runs.isEmpty else { return }
        if let continued {
            continued.progress.completedUnitCount = continued.progress.totalUnitCount
            continued.setTaskCompleted(success: true)
            self.continued = nil
        }
        endGrace()
    }

    private func started(_ task: BGContinuedProcessingTask) {
        asking = false
        guard !runs.isEmpty else {
            task.setTaskCompleted(success: true)
            return
        }
        continued = task
        task.expirationHandler = { [weak self] in
            DispatchQueue.main.async { self?.expired() }
        }
        show()
    }

    /// The progress so far: every step of every run, and one more to come for each run under way.
    private func show() {
        guard let continued else { return }
        let done = runs.values.reduce(0) { $0 + $1.steps }
        continued.progress.totalUnitCount = done + Int64(max(1, runs.count))
        continued.progress.completedUnitCount = done
    }

    /// The person cancelled the work from the system's progress, or the system stopped it: every run stops.
    private func expired() {
        guard let continued else { return }
        self.continued = nil
        continued.setTaskCompleted(success: false)
        for run in runs.values { run.onCancel() }
    }

    private func endGrace() {
        guard grace != .invalid else { return }
        UIApplication.shared.endBackgroundTask(grace)
        grace = .invalid
    }
}
