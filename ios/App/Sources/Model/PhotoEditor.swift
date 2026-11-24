import CoreGraphics
import Foundation
import Observation
import OscuruCore
import OscuruEngine
import OscuruScripting

/// A thread saved by versions before the transcript: what the person saw, and what the model had
/// been told. Read once, into the photo's transcript.
struct SavedThread: Codable {
    var turns: [Turn]
    var conversation: [JSONValue]
}

/// One photo open on screen, as a conversation: its turns, its settings over time, and the photo
/// as it is now. Everything that changes the photo goes through `history`, so there is one
/// editing path, and is written to the photo's transcript, so the thread is the whole story and
/// survives anything. The turns on screen are read from the transcript, never kept beside it.
@MainActor
@Observable
final class PhotoEditor {
    nonisolated let document: PhotoDocument
    nonisolated let info: PhotoInfo
    nonisolated let renderer: PhotoRenderer
    private(set) var history: EditHistory
    /// The thread, as the transcript says it is.
    private(set) var turns: [Turn] = []
    /// Messages sent while the assistant works, read between its steps.
    private(set) var queued: [String] = []
    /// An instruction on its way into the transcript, shown at once.
    private(set) var sending: String?
    /// While a failed request waits to be sent again.
    private(set) var retry: Retry?
    /// While older messages are being summarized to make room.
    private(set) var summarizing = false
    /// Whether a run ended without its answer and Continue can pick it up.
    private(set) var canContinue = false
    /// Why the thread could not be written, if it could not.
    private(set) var storageProblem: String?
    /// The photo as it is now.
    private(set) var image: CGImage?
    /// Goes up with every new picture, so the screen can cross-fade between them.
    private(set) var imageVersion = 0
    private(set) var renderError: String?
    /// Goes up each time the assistant answers an instruction.
    private(set) var completedRuns = 0
    /// Goes up whenever the thread changes, so the screen can follow it.
    private(set) var threadVersion = 0
    /// Called when the assistant stops working, so a photo closed meanwhile can be let go.
    var onIdle: (() -> Void)?

    struct Retry: Equatable {
        var attempt: Int
        var until: Date
        var message: String
    }

    private let runtime: ScriptRuntime
    private let library: Library
    private let account: Account
    private let modelClient: @MainActor () -> ModelClient
    let transcript: Transcript
    private(set) var conversation: Conversation
    private var task: Task<Void, Never>?
    private var following: Task<Void, Never>?
    private let background = BackgroundWork()
    private var renderGeneration = 0
    private var pictures: [String: CGImage] = [:]
    private var pictureOrder: [String] = []

    /// `entries` and `updates` come from one `transcript.observe()`, so nothing falls between them.
    init(
        document: PhotoDocument, info: PhotoInfo, renderer: PhotoRenderer, transcript: Transcript, entries: [TranscriptEntry],
        updates: AsyncStream<TranscriptEntry>, library: Library, account: Account, modelClient: @escaping @MainActor () -> ModelClient
    ) {
        self.document = document
        self.info = info
        self.renderer = renderer
        self.transcript = transcript
        self.library = library
        self.account = account
        self.modelClient = modelClient
        runtime = ScriptRuntime(host: renderer)
        history = EditHistory(state: document.state, revision: document.revision)
        conversation = Conversation(entries)
        reproject()
        following = Task { [weak self] in
            for await entry in updates {
                guard let self else { return }
                self.received(entry)
            }
        }
        refreshImage()
    }

    /// Stops following the transcript, once the editor is no longer needed.
    func detach() {
        following?.cancel()
        following = nil
    }

    var state: EditingState { history.state }
    var isWorking: Bool { task != nil }
    var original: EditingState { EditingState(defaults: info.defaults) }

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

    // MARK: Changing the photo yourself

    /// Called after every change to `history`: saves and redraws.
    private func changed() {
        library.save(id: document.id, state: history.state, revision: history.revision)
        refreshImage()
    }

    func apply(_ filter: SavedFilter) {
        guard !isWorking else { return }
        let current = history.state
        let renderer = renderer
        guard let state = try? filter.applied(to: current, defaults: info.defaults, source: { renderer.pixels(of: LookFit.base(current, wholeFrame: false)) }) else { return }
        guard history.push(state, source: .filter(name: filter.name)) else { return }
        changed()
        write(.edit(.init(kind: .filter(filter.name), state: state)))
    }

    /// Makes an earlier version the current one again, as a new turn.
    func restore(_ state: EditingState) {
        guard !isWorking, history.push(state, source: .reverted) else { return }
        changed()
        write(.edit(.init(kind: .restore, state: state)))
    }

    func startOver() {
        guard !isWorking, history.push(original, source: .reset) else { return }
        changed()
        write(.edit(.init(kind: .startOver, state: original)))
    }

    var currentLook: Look { Look(state: history.state, defaults: info.defaults) }

    // MARK: Pictures

    private func key(_ state: EditingState) -> String { state.json.text() }

    private func remember(_ image: CGImage, for state: EditingState) {
        let key = key(state)
        if pictures[key] == nil { pictureOrder.append(key) }
        pictures[key] = image
        if pictureOrder.count > 16 { pictures[pictureOrder.removeFirst()] = nil }
    }

    private func refreshImage() {
        renderGeneration += 1
        let generation = renderGeneration
        let state = history.state
        let renderer = renderer
        Task.detached(priority: .userInitiated) {
            let result = Result { try renderer.cardImage(of: state) }
            await MainActor.run {
                // A newer change is already on its way: its picture wins.
                guard generation == self.renderGeneration else { return }
                switch result {
                case .success(let image):
                    self.image = image
                    self.imageVersion += 1
                    self.renderError = nil
                    self.remember(image, for: state)
                case .failure(let error):
                    self.renderError = String(describing: error)
                }
            }
        }
    }

    /// The photo with these settings, sized for the thread. Kept for a while once rendered.
    func picture(of state: EditingState) async -> CGImage? {
        if let image = pictures[key(state)] { return image }
        let renderer = renderer
        guard let image = await Task.detached(priority: .userInitiated, operation: { try? renderer.cardImage(of: state) }).value else { return nil }
        remember(image, for: state)
        return image
    }

    /// The photo with these settings, large enough to fill the screen and zoom into.
    func fullPicture(of state: EditingState) async -> CGImage? {
        let renderer = renderer
        return await Task.detached(priority: .userInitiated) { try? renderer.screenImage(of: state) }.value
    }

    /// Develops a version at full resolution into a temporary file for the share sheet.
    func export(_ state: EditingState, as format: ExportFormat) async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(document.fileName).\(format == .heic ? "heic" : "jpg")")
        try? FileManager.default.removeItem(at: url)
        let renderer = renderer
        try await Task.detached(priority: .userInitiated) { try renderer.export(state, format: format, to: url) }.value
        return url
    }

    /// A copy of the original file, untouched (the RAW file for a RAW photo), for the share sheet.
    func exportOriginal() async throws -> URL {
        let source = library.originalURL(document)
        let url = FileManager.default.temporaryDirectory.appending(path: "\(document.fileName).\(source.pathExtension)")
        try? FileManager.default.removeItem(at: url)
        try await Task.detached(priority: .userInitiated) { try FileManager.default.copyItem(at: source, to: url) }.value
        return url
    }

    /// Redraws the library thumbnail from the current edits.
    func saveThumbnail() async {
        let state = history.state
        let renderer = renderer
        if let jpeg = await Task.detached(operation: { renderer.thumbnail(of: state) }).value {
            library.saveThumbnail(id: document.id, jpeg: jpeg)
        }
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
    private func start(_ prepare: @escaping @Sendable () async throws -> Void) {
        let client = modelClient()
        let model = account.activeModel
        let window = account.contextLength(of: model)
        let port = EditorPort(editor: self)
        let transcript = transcript
        let photo = document.id
        background.begin()
        task = Task {
            do {
                try await prepare()
                try await Agent.run(transcript: transcript, client: client, model: model, contextWindow: window, port: port, sessionID: photo) { event in
                    await self.handle(event)
                }
            } catch {
                self.storageProblem = error.localizedDescription
            }
            self.finish()
        }
        reproject()
    }

    private func finish() {
        task = nil
        retry = nil
        summarizing = false
        sending = nil
        reproject()
        if turns.last?.status == .done { completedRuns += 1 }
        background.end()
        let transcript = transcript
        Task {
            await transcript.prune()
            await account.refresh()
            await saveThumbnail()
        }
        onIdle?()
    }

    private func handle(_ event: AgentEvent) {
        switch event {
        case .requesting, .running:
            retry = nil
            summarizing = false
        case .retrying(let attempt, let delay, let message):
            retry = Retry(attempt: attempt, until: Date().addingTimeInterval(delay), message: message)
        case .summarizing:
            summarizing = true
        }
    }

    // MARK: The assistant's side of the tool

    fileprivate struct Snapshot: Sendable {
        var state: EditingState
        var revision: Int
        var before: EditingState
        /// The run the scripts belong to: the record of the words that started it.
        var run: String
    }

    fileprivate func snapshot() -> Snapshot {
        let run = conversation.runStart ?? "run"
        return Snapshot(state: history.state, revision: history.revision, before: history.stateBefore(run: run), run: run)
    }

    /// Makes a script's result the photo's settings, unless the photo changed while the script ran.
    fileprivate func commit(_ state: EditingState, expecting revision: Int, run: String, script: String) -> Bool {
        guard history.revision == revision else { return false }
        if history.push(state, source: .assistant(run: run, script: script)) { changed() }
        return true
    }

    fileprivate func run(_ request: ScriptRequest, isCancelled: @escaping @Sendable () -> Bool) async -> ScriptOutcome {
        await runtime.run(request, isCancelled: isCancelled)
    }
}

/// What the agent can learn about the open photo and do to it: the phone's side of `execute_edit_script`.
private struct EditorPort: AgentPort {
    let editor: PhotoEditor

    func context() async -> AgentContext {
        let snapshot = await editor.snapshot()
        let renderer = editor.renderer
        let statistics = await Task.detached { renderer.analysis(of: snapshot.state)?.statistics }.value
        return AgentContext(
            sessionID: editor.document.id, revision: snapshot.revision, state: snapshot.state, metadata: renderer.info.json, statistics: statistics,
            filters: renderer.filterNames())
    }

    func openingImages() async -> [LabeledImage] {
        let snapshot = await editor.snapshot()
        let renderer = editor.renderer
        return await Task.detached {
            var images: [LabeledImage] = []
            let original = renderer.original(framedLike: snapshot.state)
            if snapshot.state != original, let jpeg = renderer.image(of: original, region: nil, maxEdge: Prompt.defaultImageEdge) {
                images.append(LabeledImage(label: "The original photo, with no edits:", jpeg: jpeg))
            }
            if let jpeg = renderer.image(of: snapshot.state, region: nil, maxEdge: Prompt.defaultImageEdge) {
                images.append(LabeledImage(label: snapshot.state == original ? "The photo (not edited yet):" : "The photo as it is now:", jpeg: jpeg))
            }
            return images
        }.value
    }

    func execute(arguments: JSONValue) async -> ToolExecution {
        let snapshot = await editor.snapshot()
        let renderer = editor.renderer
        func picture(_ state: EditingState, _ label: String) async -> [LabeledImage] {
            await Task.detached { renderer.image(of: state, region: nil, maxEdge: Prompt.defaultImageEdge).map { [LabeledImage(label: label, jpeg: $0)] } ?? [] }.value
        }
        func refused(_ status: String, _ message: String) -> JSONValue {
            ["status": .string(status), "applied": false, "revision": .number(Double(snapshot.revision)), "error": ["message": .string(message)]]
        }
        func stale(_ current: PhotoEditor.Snapshot, said: JSONValue) async -> ToolExecution {
            var payload = refused(
                "stale_revision",
                "The photo is at revision \(current.revision), not \(said.described): it changed since you last saw it (the person may have undone something or applied a filter). Nothing was applied. Look at the current state and picture, then send a script based on revision \(current.revision)."
            ).objectValue ?? [:]
            payload["revision"] = .number(Double(current.revision))
            payload["state"] = current.state.json
            return ToolExecution(payload: .object(payload), images: await picture(current.state, "The photo as it is now (revision \(current.revision)):"))
        }

        guard let code = arguments["code"]?.stringValue, !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ToolExecution(payload: refused("invalid_request", "code must be a non-empty string of JavaScript"), images: [])
        }
        guard arguments["sessionId"]?.stringValue == editor.document.id else {
            return ToolExecution(
                payload: refused("wrong_session", "sessionId \((arguments["sessionId"] ?? .null).described) is not the photo open in the editor (\(editor.document.id))"), images: [])
        }
        let said = arguments["baseRevision"] ?? .null
        guard said.doubleValue == Double(snapshot.revision) else { return await stale(snapshot, said: said) }

        let cancel = CancelFlag()
        let request = ScriptRequest(code: code, state: snapshot.state, revision: snapshot.revision, info: renderer.info, before: snapshot.before)
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
        var images = outcome.shown

        if let error = outcome.error {
            payload["status"] = "error"
            payload["applied"] = false
            payload["revision"] = .number(Double(snapshot.revision))
            payload["error"] = error.json
            payload["changes"] = []
            return ToolExecution(payload: .object(payload), images: images)
        }
        let changed = outcome.state != snapshot.state
        if changed {
            guard await editor.commit(outcome.state, expecting: snapshot.revision, run: snapshot.run, script: code) else {
                return await stale(await editor.snapshot(), said: said)
            }
        }
        let after = await editor.snapshot()
        payload["status"] = "ok"
        payload["applied"] = .bool(changed)
        payload["revision"] = .number(Double(after.revision))
        payload["changes"] = .array(outcome.changes.map(\.json))
        payload["statistics"] = await Task.detached { renderer.analysis(of: after.state)?.statistics }.value ?? .null
        if changed {
            // Always both: the photo before this request's edits, and as it is now.
            images += await picture(after.before, "Before your edits for this request:")
            images += await picture(after.state, "After, as the photo is now (revision \(after.revision)):")
        }
        return ToolExecution(payload: .object(payload), images: images, state: changed ? after.state : nil)
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
