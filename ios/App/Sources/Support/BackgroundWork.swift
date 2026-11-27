import BackgroundTasks
import UIKit
import os

/// Keeps the assistant working when the app leaves the screen, for every photo it is working on.
///
/// Work the person asked for (a message, Continue) runs under one continued processing task for
/// the whole app (iOS 26's `BGContinuedProcessingTask`): it carries on while they use other apps,
/// and the system shows its progress. It lasts until the last run ends, so one photo finishing
/// never leaves another to be suspended.
///
/// The system ends a task whose progress has not moved for some twenty seconds, and one answer
/// from the model can take longer than that: so the progress moves a little every few seconds
/// while work is under way (waiting for the model is the work), and more with each step taken.
///
/// When the system ends the task all the same (it does not say why: it was stopped from its
/// progress, or the system wanted its resources), the work is not stopped: the app is suspended
/// with it, and it carries on when the app is opened again, as it does without such a task. Stop
/// in the app is what stops the assistant. Where the system will not start a task, or for work
/// the app took up again by itself, iOS gives the usual short time to finish instead. Each
/// transcript has every step so far, whatever happens to the app.
@MainActor
final class BackgroundWork {
    static let shared = BackgroundWork()

    private struct Run {
        var photo: String
        var about: String
        var asked: Bool
    }

    /// The runs under way, by photo.
    private var runs: [String: Run] = [:]
    private var grace: UIBackgroundTaskIdentifier = .invalid
    private var continued: BGContinuedProcessingTask?
    /// A continued task asked for and not yet started or refused.
    private var asking = false
    /// The progress the current task has shown, in units: one for every few seconds of work, several for each step.
    private var units: Int64 = 0
    private var beat: Task<Void, Never>?

    /// How often the progress moves by itself, well within what the system waits for.
    private static let beatSeconds = 5
    /// What a step adds, and how far ahead the end is always shown to be.
    private static let stepUnits: Int64 = 6
    private static let aheadUnits: Int64 = 60

    private static let log = Logger(subsystem: "com.rudilosso.oscuru", category: "background")

    /// The prefix of each task's identifier, as listed (with a wildcard) under
    /// BGTaskSchedulerPermittedIdentifiers in Info.plist.
    private static var prefix: String { (Bundle.main.bundleIdentifier ?? "com.rudilosso.oscuru") + ".assistant." }

    private init() {
        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.leftScreen() }
        }
        center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.ask() }
        }
    }

    /// A run starts on a photo (`id`, named `photo`). `asked` is whether the person asked for it
    /// just now, which a continued task needs; `about` is what was asked.
    func begin(_ id: String, photo: String, asked: Bool, about: String) {
        runs[id] = Run(photo: photo, about: about, asked: asked)
        beginGrace()
        ask()
    }

    /// The run on `id` took a step: a request to the model, or a script.
    func step(_ id: String) {
        guard runs[id] != nil else { return }
        advance(BackgroundWork.stepUnits)
    }

    /// The run on `id` is over. With none left, the system's progress finishes and the app may be suspended.
    func end(_ id: String) {
        runs[id] = nil
        guard runs.isEmpty else { return }
        beat?.cancel()
        beat = nil
        if let continued {
            continued.progress.completedUnitCount = continued.progress.totalUnitCount
            continued.setTaskCompleted(success: true)
            self.continued = nil
        }
        endGrace()
    }

    /// Asks the system for a continued task, when work the person asked for is under way without one.
    private func ask() {
        guard continued == nil, !asking, !UITesting.isActive, let run = runs.values.first(where: { $0.asked }) else { return }
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
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: L10n.assistantBackgroundTitle(run.photo), subtitle: run.about)
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

    private func started(_ task: BGContinuedProcessingTask) {
        asking = false
        guard !runs.isEmpty else {
            task.setTaskCompleted(success: true)
            return
        }
        continued = task
        units = 0
        task.expirationHandler = { [weak self] in
            DispatchQueue.main.async { self?.expired() }
        }
        advance(1)
        // The progress moves while work is under way, so the system does not take it for stalled.
        beat?.cancel()
        beat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(BackgroundWork.beatSeconds))
                guard let self, !Task.isCancelled else { return }
                self.advance(1)
            }
        }
    }

    /// Moves the progress on: the end stays ahead until the work is done, and the share done only grows.
    private func advance(_ amount: Int64) {
        guard let continued else { return }
        units += amount
        continued.progress.totalUnitCount = units + BackgroundWork.aheadUnits
        continued.progress.completedUnitCount = units
    }

    /// The system ended the task: stopped from its progress, or taken back. The work itself is
    /// left as it is; the app is suspended with it, and it carries on when the app is opened again.
    private func expired() {
        guard let continued else { return }
        self.continued = nil
        beat?.cancel()
        beat = nil
        continued.updateTitle(continued.title, subtitle: L10n.assistantBackgroundPaused)
        continued.setTaskCompleted(success: false)
        BackgroundWork.log.notice("The assistant's background task was ended by the system; the work carries on when the app is open.")
    }

    /// The app left the screen with work under way: the usual short time to finish, if nothing longer is running.
    private func leftScreen() {
        guard !runs.isEmpty else { return }
        beginGrace()
    }

    private func beginGrace() {
        guard grace == .invalid else { return }
        grace = UIApplication.shared.beginBackgroundTask(withName: "Assistant") { [weak self] in
            MainActor.assumeIsolated { self?.endGrace() }
        }
    }

    private func endGrace() {
        guard grace != .invalid else { return }
        UIApplication.shared.endBackgroundTask(grace)
        grace = .invalid
    }
}
