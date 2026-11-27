import CoreGraphics
import Foundation
import Observation
import OscuruCore
import OscuruEngine
import OscuruScripting

/// One photo and its conversation: the thread, the photo's settings now, and the assistant at
/// work on it. The transcript is the photo's history. Everything on screen is read from it, and
/// every change to the photo, the person's or the assistant's, goes through `set` and is written
/// to it, so there is one editing path and nothing is kept beside it.
@MainActor
@Observable
final class PhotoEditor {
    /// The photo as it was opened: its id, name and file. Its settings now are `state`.
    nonisolated let document: PhotoDocument
    nonisolated let renderer: PhotoRenderer
    /// The photo's settings now.
    private(set) var state: EditingState
    /// Goes up each time the settings change.
    private(set) var stateVersion = 0
    /// The thread, as the transcript says it is.
    private(set) var turns: [Turn] = []
    /// Messages sent while the assistant works, read between its steps.
    private(set) var queued: [String] = []
    /// An instruction on its way into the transcript, shown at once.
    private(set) var sending: String?
    /// While a failed request waits to be sent again: what went wrong.
    private(set) var retrying: String?
    /// While older messages are being summarized to make room.
    private(set) var summarizing = false
    /// For diagnostics: what the assistant is doing now and since when, when its run started, and how many steps it has taken.
    @ObservationIgnored private var doing: (what: String, since: Date)?
    @ObservationIgnored private var runStarted: Date?
    @ObservationIgnored private var runSteps = 0
    /// Whether a run ended without its answer and Continue can pick it up.
    private(set) var canContinue = false
    /// Why the thread could not be written, if it could not.
    private(set) var storageProblem: String?
    /// Goes up each time the assistant answers an instruction.
    private(set) var completedRuns = 0
    /// Goes up whenever the thread changes, so the screen can follow it.
    private(set) var threadVersion = 0
    /// Called when the assistant stops working, so a photo closed meanwhile can be let go.
    var onIdle: (() -> Void)?

    private let runtime: ScriptRuntime
    private let library: Library
    private let account: Account
    private let modelClient: @MainActor () -> ModelClient
    private let transcript: Transcript
    private var conversation: Conversation
    private var task: Task<Void, Never>?
    private var following: Task<Void, Never>?
    /// Pictures of versions shown in the thread, kept for a while.
    private var pictures: [(state: EditingState, image: CGImage)] = []
    /// The settings the library's thumbnail shows.
    private var thumbnailState: EditingState

    /// `entries` and `updates` come from one `transcript.observe()`, so nothing falls between them.
    init(
        document: PhotoDocument, renderer: PhotoRenderer, transcript: Transcript, entries: [TranscriptEntry], updates: AsyncStream<TranscriptEntry>,
        library: Library, account: Account, modelClient: @escaping @MainActor () -> ModelClient
    ) {
        self.document = document
        self.renderer = renderer
        self.transcript = transcript
        self.library = library
        self.account = account
        self.modelClient = modelClient
        runtime = ScriptRuntime(host: renderer)
        let conversation = Conversation(entries)
        self.conversation = conversation
        // The transcript says what the photo's settings are; the library keeps a copy.
        let state = conversation.state ?? document.state
        self.state = state
        thumbnailState = document.state
        library.save(id: document.id, state: state)
        reproject()
        following = Task { [weak self] in
            for await entry in updates {
                guard let self else { return }
                self.received(entry)
            }
        }
    }

    /// Stops following the transcript, once the editor is no longer needed.
    func detach() {
        following?.cancel()
        following = nil
    }

    nonisolated var info: PhotoInfo { renderer.info }
    var original: EditingState { renderer.original }
    var isWorking: Bool { task != nil }

    /// The photo before this turn: the result of the latest earlier turn that had one.
    func resultBefore(_ turn: Turn) -> EditingState? {
        guard let index = turns.firstIndex(where: { $0.id == turn.id }) else { return nil }
        return turns[..<index].last { $0.result != nil }?.result
    }

    var hasInstructions: Bool {
        turns.contains { if case .instruction = $0.kind { return true } else { return false } }
    }

    // MARK: The thread

    private func received(_ entry: TranscriptEntry) {
        conversation = Conversation(conversation.entries + [entry])
        let run = conversation.runStart ?? entry.id
        switch entry.body {
        case .user(let user) where !user.queued:
            sending = nil
        case .user:
            // Sent just as the assistant finished: it starts the next run.
            if !isWorking { followUp() }
        case .assistant(let assistant):
            if let usage = assistant.usage { account.record(usage, model: assistant.model, run: run, photo: document.id) }
        case .compaction(let compaction):
            if let usage = compaction.usage { account.record(usage, model: compaction.model, run: run, photo: document.id) }
        default:
            break
        }
        reproject()
    }

    private func reproject() {
        let account = account
        // While new words are being written down, the previous turn is not the one at work.
        turns = conversation.turns(working: isWorking && sending == nil, price: { usage, model in account.price(usage, model: model) }, failure: { L10n.message(for: $0.error) })
        queued = conversation.queued.compactMap { entry in
            if case .user(let user) = entry.body { return user.text }
            return nil
        }
        canContinue = !isWorking && account.isConnected && (conversation.canContinue || conversation.wasInterrupted)
        threadVersion += 1
    }

    /// Writes a record; it shows once it is on disk.
    private func write(_ body: TranscriptEntry.Body) {
        let transcript = transcript
        Task {
            do {
                try await transcript.append(body)
            } catch {
                self.storageProblem = error.localizedDescription
            }
        }
    }

    // MARK: Changing the photo

    /// The one place the photo's settings change.
    fileprivate func set(_ next: EditingState) {
        guard next != state else { return }
        state = next
        stateVersion += 1
        library.save(id: document.id, state: next)
    }

    /// A change the person makes, as a step of its own in the thread.
    private func change(to next: EditingState, as kind: Turn.Kind) {
        guard !isWorking, next != state else { return }
        set(next)
        write(.edit(.init(kind: kind, state: next)))
    }

    func apply(_ style: Style) async {
        guard !isWorking else { return }
        let current = state
        let renderer = renderer
        let styled = await Rendering.value(for: renderer.id) { try renderer.apply(style, to: current) }
        guard let styled, state == current else { return }
        change(to: styled, as: .style(style.name))
    }

    /// Makes an earlier version the current one again.
    func restore(_ version: EditingState) {
        change(to: version, as: .restore)
    }

    /// Saves the photo's look as a style. False when the name is unusable.
    func saveStyle(named name: String) async -> Bool {
        let current = state
        let renderer = renderer
        return await Rendering.value(for: renderer.id) { renderer.saveStyle(name: name, state: current) } ?? false
    }

    // MARK: Pictures

    /// A picture of a version that is already at hand, so a card showing it need not start empty.
    func keptPicture(of version: EditingState) -> CGImage? {
        pictures.first { $0.state == version }?.image
    }

    /// A version of the photo for the screen: sized for the thread, or `filling` the screen to zoom into.
    func picture(of version: EditingState, filling: Bool = false) async -> CGImage? {
        if !filling, let kept = keptPicture(of: version) { return kept }
        let renderer = renderer
        let edge = filling ? PhotoRenderer.screenEdge : PhotoRenderer.cardEdge
        guard let image = await Rendering.value(for: renderer.id, { try renderer.picture(of: version, edge: edge) }) else { return nil }
        if !filling, keptPicture(of: version) == nil {
            pictures.append((version, image))
            if pictures.count > 16 { pictures.removeFirst() }
        }
        return image
    }

    /// The photo as it is now with a style tried on, small: what a style's tile shows.
    func preview(of style: Style) async -> CGImage? {
        let current = state
        let renderer = renderer
        return await Rendering.value(for: renderer.id) { try renderer.picture(of: renderer.apply(style, to: current), edge: PhotoRenderer.styleEdge) }
    }

    /// Redraws the library thumbnail when the photo has changed since it was drawn.
    func saveThumbnail() async {
        let current = state
        guard current != thumbnailState else { return }
        let renderer = renderer
        guard let jpeg = await Rendering.value(for: renderer.id, { renderer.jpeg(of: current, edge: PhotoRenderer.thumbnailEdge) }) else { return }
        library.saveThumbnail(id: document.id, jpeg: jpeg)
        thumbnailState = current
    }

    // MARK: The assistant

    /// Gives the assistant an instruction. While it works, the words join its work between two
    /// of its steps instead: nothing has to wait for it to finish.
    func send(_ instruction: String) {
        let text = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, account.isConnected else { return }
        guard !isWorking else {
            write(.user(Agent.steer(text)))
            return
        }
        sending = text
        let port = EditorPort(editor: self)
        let transcript = transcript
        start {
            // The photo as the person sees it goes with the words, and is kept with them.
            let context = await port.context()
            var pictures: [PictureRef] = []
            for image in await port.openingImages() { pictures.append(try await transcript.store(image)) }
            try await transcript.append(.user(Agent.instruction(text, context: context, pictures: pictures)))
        }
    }

    func stop() {
        task?.cancel()
    }

    /// Picks up a run that ended without its answer: after Stop, or a request that kept failing.
    func continueRun() {
        guard !isWorking, account.isConnected, conversation.canContinue || conversation.wasInterrupted else { return }
        let transcript = transcript
        start { _ = try await transcript.append(.resume(automatic: false)) }
    }

    /// Carries on with work the app was closed during, as soon as the photo is open again. Work
    /// that keeps getting cut off is left for Continue instead of starting again forever.
    func resumeIfInterrupted() {
        guard !isWorking, account.isConnected, conversation.wasInterrupted else { return }
        guard conversation.automaticResumes < 3 else {
            write(.stop)
            return
        }
        let transcript = transcript
        start { _ = try await transcript.append(.resume(automatic: true)) }
    }

    /// Runs the assistant's loop on the transcript, once `prepare` has written what starts it.
    /// It works while the app is open; when the app leaves the screen iOS suspends it, and it
    /// carries on from where it was when the app is back.
    private func start(_ prepare: @escaping @Sendable () async throws -> Void) {
        let client = modelClient()
        let model = account.activeModel
        let window = account.contextLength(of: model)
        let port = EditorPort(editor: self)
        let transcript = transcript
        let photo = document.id
        runStarted = Date()
        runSteps = 0
        doing = ("starting", Date())
        Diagnostics.shared.log("\(document.fileName): assistant started (model \(model))")
        task = Task {
            do {
                try await prepare()
                try await Agent.run(
                    transcript: transcript, client: client, model: model, contextWindow: window, port: port, sessionID: photo, sleep: Network.pause
                ) { event in
                    await self.handle(event)
                }
            } catch {
                self.storageProblem = error.localizedDescription
            }
            self.finish()
        }
        reproject()
    }

    /// Answers messages that were sent while the assistant worked but arrived after its last step:
    /// called when a run ends and when such a message is written with nobody working.
    private func followUp() {
        guard !isWorking, account.isConnected, conversation.halt == nil, !conversation.queued.isEmpty else { return }
        start {}
    }

    private func finish() {
        if let runStarted {
            let outcome = conversation.halt.map(PhotoEditor.describe) ?? "done"
            Diagnostics.shared.log("\(document.fileName): assistant ended after \(Diagnostics.elapsed(since: runStarted)) and \(runSteps) steps (\(outcome))")
        }
        doing = nil
        runStarted = nil
        task = nil
        retrying = nil
        summarizing = false
        sending = nil
        reproject()
        followUp()
        guard !isWorking else { return }
        if turns.last?.status == .done { completedRuns += 1 }
        let transcript = transcript
        Task {
            await transcript.prune()
            await account.refresh()
            await saveThumbnail()
        }
        onIdle?()
    }

    private static func describe(_ halt: Conversation.Halt) -> String {
        switch halt {
        case .stopped: return "stopped"
        case .failed(let failure): return "failed: \(failure.message)"
        }
    }

    /// One line for diagnostics: what the assistant is doing and for how long.
    var diagnosis: String {
        guard isWorking else {
            if let halt = conversation.halt { return "idle (last run \(PhotoEditor.describe(halt)))" }
            return "idle"
        }
        let what = doing.map { "\($0.what) for \(Diagnostics.elapsed(since: $0.since))" } ?? "working"
        let run = runStarted.map { ", run \(Diagnostics.elapsed(since: $0)) and \(runSteps) steps so far" } ?? ""
        return what + run + (retrying.map { " — last error: \($0)" } ?? "")
    }

    private func handle(_ event: AgentEvent) {
        // For diagnostics: how long the step before this one took, and what starts now.
        let now = Date()
        let name = document.fileName
        if let doing, doing.what != "starting" {
            Diagnostics.shared.log("\(name): \(doing.what) took \(Diagnostics.elapsed(since: doing.since, now: now))")
        }
        switch event {
        case .requesting: doing = ("waiting for the model", now)
        case .running: doing = ("running a script", now)
        case .retrying(let attempt, let delay, let message):
            doing = ("waiting to retry", now)
            Diagnostics.shared.log("\(name): request failed (\(message)), retry \(attempt) in \(Int(delay))s")
        case .summarizing: doing = ("summarizing the conversation", now)
        }
        runSteps += 1
        switch event {
        case .requesting, .running:
            retrying = nil
            summarizing = false
        case .retrying(_, _, let message):
            retrying = message
        case .summarizing:
            summarizing = true
        }
    }

    // MARK: The assistant's side of the tool

    /// The photo's settings now, and when the person gave the instruction being carried out.
    fileprivate func snapshot() -> (state: EditingState, before: EditingState) {
        (state, conversation.stateBeforeRun ?? state)
    }

    /// New photos split off this one (`photo.split`), named after it and numbered. Returns the names
    /// of those made.
    fileprivate func makeParts(_ states: [EditingState]) async -> [String] {
        var names: [String] = []
        for (index, state) in states.enumerated() {
            let name = "\(document.fileName) \(index + 1)"
            if (try? await library.duplicate(document, state: state, name: name)) != nil { names.append(name) }
        }
        return names
    }

    fileprivate func run(_ request: ScriptRequest, isCancelled: @escaping @Sendable () -> Bool) async -> ScriptOutcome {
        await runtime.run(request, isCancelled: isCancelled)
    }
}

/// What the agent can learn about the photo and do to it: the phone's side of `execute_edit_script`.
private struct EditorPort: AgentPort {
    let editor: PhotoEditor

    private func picture(_ state: EditingState, _ label: String) async -> [LabeledImage] {
        let renderer = editor.renderer
        return await Rendering.value(for: renderer.id) { renderer.image(of: state, region: nil, maxEdge: Prompt.defaultImageEdge).map { [LabeledImage(label: label, jpeg: $0)] } } ?? []
    }

    func context() async -> AgentContext {
        let state = await editor.state
        let renderer = editor.renderer
        let statistics = await Rendering.value(for: renderer.id) { renderer.analysis(of: state)?.statistics }
        return AgentContext(state: state, metadata: renderer.info.json, statistics: statistics, styles: renderer.styleNames())
    }

    /// The pictures that open an instruction: the original when the photo has been edited, and the photo as it is.
    func openingImages() async -> [LabeledImage] {
        let state = await editor.state
        let original = editor.renderer.original(framedLike: state)
        guard state != original else { return await picture(state, "The photo (not edited yet):") }
        return await picture(original, "The original photo, with no edits:") + picture(state, "The photo as it is now:")
    }

    func execute(arguments: JSONValue) async -> ToolExecution {
        guard let code = arguments["code"]?.stringValue, !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ToolExecution(
                payload: ["status": "invalid_request", "applied": false, "error": ["message": "code must be a non-empty string of JavaScript"]], images: [])
        }
        let renderer = editor.renderer
        let (state, before) = await editor.snapshot()
        let cancel = CancelFlag()
        let request = ScriptRequest(code: code, state: state, info: renderer.info, before: before)
        let outcome = await withTaskCancellationHandler {
            await editor.run(request, isCancelled: { cancel.isSet })
        } onCancel: {
            cancel.set()
        }

        var payload: [String: JSONValue] = [
            "logs": .array(outcome.logs.map { .string($0) }),
            "durationMs": .number(Double(outcome.durationMs)),
        ]
        if let value = outcome.returnValue { payload["returnValue"] = .string(value) }
        if let error = outcome.error {
            payload["status"] = "error"
            payload["applied"] = false
            payload["error"] = error.json
            payload["changes"] = []
            return ToolExecution(payload: .object(payload), images: outcome.shown)
        }
        let after = outcome.state
        let changed = after != state
        if changed { await editor.set(after) }
        if !outcome.parts.isEmpty {
            let made = await editor.makeParts(outcome.parts)
            payload["newPhotos"] = .array(made.map { .string($0) })
            payload["newPhotosNote"] = .string(
                made.count == outcome.parts.count
                    ? "These are new photos in the person's library. This photo did not change."
                    : "Only \(made.count) of the \(outcome.parts.count) parts could be made into photos.")
        }
        payload["status"] = "ok"
        payload["applied"] = .bool(changed)
        payload["changes"] = .array(outcome.changes.map(\.json))
        payload["statistics"] = await Rendering.value(for: renderer.id) { renderer.analysis(of: after)?.statistics } ?? .null
        var images = outcome.shown
        if changed {
            // Always both: the photo before this request's edits, and as it is now.
            images += await picture(before, "Before your edits for this request:")
            images += await picture(after, "After, as the photo is now:")
        }
        return ToolExecution(payload: .object(payload), images: images, state: changed ? after : nil)
    }
}

private final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }
}
