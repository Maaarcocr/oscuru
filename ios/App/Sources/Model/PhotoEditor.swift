import CoreGraphics
import Foundation
import Observation
import OscuruCore
import OscuruEngine
import OscuruScripting

/// One setting a script changed.
struct StepChange: Codable, Equatable {
    let path: String
    let from: JSONValue
    let to: JSONValue
}

/// One script the assistant ran.
struct Step: Codable, Equatable {
    enum Outcome: Codable, Equatable {
        case running
        case applied
        case unchanged
        case failed(String)
        case stale
    }

    var code: String
    var outcome: Outcome
    var changes: [StepChange] = []
    var logs: [String] = []
    /// What the assistant said as it started this script.
    var note: String?
}

/// One thing that happened to the photo: the thread is a list of these. A turn that changed the
/// photo keeps the settings it left, so every version can be shown again and restored.
struct Turn: Codable, Identifiable, Equatable {
    enum Kind: Codable, Equatable {
        case original
        case instruction(String)
        case filter(String)
        case restore
        case startOver
        /// Edits made before the photo had a thread.
        case earlier
    }

    enum Status: Codable, Equatable {
        case working
        case done
        case stopped
        case failed(String)
    }

    var id: String
    var kind: Kind
    /// What the assistant said that is not a step's note: once it has finished, its reply.
    var messages: [String] = []
    var steps: [Step] = []
    /// The photo after this turn, when the turn changed it (and the original, for the first turn).
    var result: EditingState?
    var status: Status = .done
    var cost: Double?
}

/// What is saved of a photo's thread: what the person sees, and what the model has been told.
struct SavedThread: Codable {
    var turns: [Turn]
    var conversation: [JSONValue]
}

/// One photo open on screen, as a conversation: its turns, its settings over time, and the photo
/// as it is now. Everything that changes the photo goes through `history`, so there is one
/// editing path, and adds a turn, so the thread is the whole story.
@MainActor
@Observable
final class PhotoEditor {
    nonisolated let document: PhotoDocument
    nonisolated let info: PhotoInfo
    nonisolated let renderer: PhotoRenderer
    private(set) var history: EditHistory
    private(set) var turns: [Turn]
    /// The photo as it is now.
    private(set) var image: CGImage?
    /// Goes up with every new picture, so the screen can cross-fade between them.
    private(set) var imageVersion = 0
    private(set) var renderError: String?
    /// Goes up each time the assistant finishes an instruction.
    private(set) var completedRuns = 0
    /// Goes up whenever the thread changes, so the screen can follow it.
    private(set) var threadVersion = 0

    private let runtime: ScriptRuntime
    private let library: Library
    private let account: Account
    private let modelClient: @MainActor () -> ModelClient
    private var conversation: [JSONValue]
    private var task: Task<Void, Never>?
    private var renderGeneration = 0
    /// Whether the assistant's latest words came with the response now being handled.
    private var saidSomething = false
    private var pictures: [String: CGImage] = [:]
    private var pictureOrder: [String] = []

    init(document: PhotoDocument, info: PhotoInfo, renderer: PhotoRenderer, library: Library, account: Account, modelClient: @escaping @MainActor () -> ModelClient) {
        self.document = document
        self.info = info
        self.renderer = renderer
        self.library = library
        self.account = account
        self.modelClient = modelClient
        runtime = ScriptRuntime(host: renderer)
        history = EditHistory(state: document.state, revision: document.revision)

        let original = EditingState(defaults: info.defaults)
        let saved = library.loadThread(document.id)
        var turns = saved?.turns ?? [Turn(id: "original", kind: .original, result: original)]
        if saved == nil, document.state != original {
            turns.append(Turn(id: UUID().uuidString, kind: .earlier, result: document.state))
        }
        // A turn still working when the app closed was cut off.
        for index in turns.indices where turns[index].status == .working {
            turns[index].status = .stopped
            for step in turns[index].steps.indices where turns[index].steps[step].outcome == .running {
                turns[index].steps[step].outcome = .failed(L10n.scriptStopped)
            }
        }
        self.turns = turns
        conversation = saved?.conversation ?? []
        refreshImage()
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

    private func save() {
        library.saveThread(document.id, SavedThread(turns: turns, conversation: conversation))
        threadVersion += 1
    }

    private func update(_ id: String, _ change: (inout Turn) -> Void) {
        guard let index = turns.lastIndex(where: { $0.id == id }) else { return }
        change(&turns[index])
        threadVersion += 1
    }

    // MARK: Changing the photo yourself

    /// Called after every change to `history`: saves and redraws.
    private func changed() {
        library.save(id: document.id, state: history.state, revision: history.revision)
        refreshImage()
    }

    func apply(_ filter: SavedFilter) {
        guard !isWorking else { return }
        let state = filter.look.applied(to: history.state, defaults: info.defaults)
        guard history.push(state, source: .filter(name: filter.name)) else { return }
        changed()
        turns.append(Turn(id: UUID().uuidString, kind: .filter(filter.name), result: state))
        save()
    }

    /// Makes an earlier version the current one again, as a new turn.
    func restore(_ state: EditingState) {
        guard !isWorking, history.push(state, source: .reverted) else { return }
        changed()
        turns.append(Turn(id: UUID().uuidString, kind: .restore, result: state))
        save()
    }

    func startOver() {
        guard !isWorking, history.push(original, source: .reset) else { return }
        changed()
        turns.append(Turn(id: UUID().uuidString, kind: .startOver, result: original))
        save()
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
        let url = FileManager.default.temporaryDirectory.appending(path: "\(exportName).\(format == .heic ? "heic" : "jpg")")
        try? FileManager.default.removeItem(at: url)
        let renderer = renderer
        try await Task.detached(priority: .userInitiated) { try renderer.export(state, format: format, to: url) }.value
        return url
    }

    /// A copy of the original file, untouched (the RAW file for a RAW photo), for the share sheet.
    func exportOriginal() async throws -> URL {
        let source = library.originalURL(document)
        let url = FileManager.default.temporaryDirectory.appending(path: "\(exportName).\(source.pathExtension)")
        try? FileManager.default.removeItem(at: url)
        try await Task.detached(priority: .userInitiated) { try FileManager.default.copyItem(at: source, to: url) }.value
        return url
    }

    /// The photo's name, usable as a file name.
    private var exportName: String {
        let name = (document.name as NSString).deletingPathExtension
            .replacingOccurrences(of: ":", with: ".")
            .replacingOccurrences(of: "/", with: "-")
        return name.isEmpty ? "Oscuru" : name
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

    /// Gives the assistant an instruction. It works until it is done or the person stops it.
    func send(_ instruction: String) {
        let text = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isWorking, account.isConnected else { return }
        let run = UUID().uuidString
        let start = history.state
        turns.append(Turn(id: run, kind: .instruction(text), status: .working))
        save()
        let client = modelClient()
        let model = account.activeModel
        let port = EditorPort(editor: self, run: run)
        let conversation = conversation
        task = Task {
            var status = Turn.Status.done
            do {
                // Events are delivered in order, each handled before the agent goes on.
                let turn = try await Agent.run(client: client, model: model, port: port, conversation: conversation, instruction: text) { event in
                    await self.handle(event, run: run)
                }
                // Only the latest pictures are kept: the next instruction would drop the rest anyway,
                // and the saved thread stays small.
                self.conversation = Agent.compactEarlierImages(turn.conversation)
                if turn.stop == .cancelled { status = .stopped }
            } catch let error as ModelError {
                status = .failed(L10n.message(for: error))
            } catch {
                status = .failed(String(describing: error))
            }
            self.finish(run, status: status, from: start)
        }
    }

    func stop() {
        task?.cancel()
    }

    private func finish(_ run: String, status: Turn.Status, from start: EditingState) {
        let current = history.state
        update(run) { turn in
            turn.status = status
            for index in turn.steps.indices where turn.steps[index].outcome == .running {
                turn.steps[index].outcome = .failed(L10n.scriptStopped)
            }
            if current != start { turn.result = current }
        }
        task = nil
        completedRuns += 1
        save()
        Task {
            await account.refresh()
            await saveThumbnail()
        }
    }

    private func handle(_ event: AgentEvent, run: String) {
        switch event {
        case .thinking:
            saidSomething = false
        case .text(let text):
            saidSomething = true
            update(run) { $0.messages.append(text) }
        case .scriptStarted(_, let code):
            // Words that come with a script are that step's note; words on their own are the reply.
            let hasNote = saidSomething
            saidSomething = false
            update(run) { turn in
                let note = hasNote ? turn.messages.popLast() : nil
                turn.steps.append(Step(code: code, outcome: .running, note: note))
            }
        case .scriptFinished(_, let payload):
            let changes = (payload["changes"]?.arrayValue ?? []).map { change in
                StepChange(path: change["path"]?.stringValue ?? "", from: change["from"] ?? .null, to: change["to"] ?? .null)
            }
            let logs = (payload["logs"]?.arrayValue ?? []).compactMap(\.stringValue)
            let outcome: Step.Outcome
            switch payload["status"]?.stringValue {
            case "ok": outcome = payload["applied"] == true ? .applied : .unchanged
            case "stale_revision": outcome = .stale
            default: outcome = .failed(payload["error"]?["message"]?.stringValue ?? "")
            }
            update(run) { turn in
                guard let last = turn.steps.indices.last else { return }
                turn.steps[last].outcome = outcome
                turn.steps[last].changes = changes
                turn.steps[last].logs = logs
            }
        case .usage(let usage, let model):
            _ = account.record(usage, model: model, run: run, photo: document.id)
            let spent = account.spent(onRun: run)
            update(run) { $0.cost = spent }
        }
    }

    // MARK: The assistant's side of the tool

    fileprivate struct Snapshot: Sendable {
        var state: EditingState
        var revision: Int
        var before: EditingState
    }

    fileprivate func snapshot(run: String) -> Snapshot {
        Snapshot(state: history.state, revision: history.revision, before: history.stateBefore(run: run))
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
    let run: String

    func context() async -> AgentContext {
        let snapshot = await editor.snapshot(run: run)
        let renderer = editor.renderer
        let statistics = await Task.detached { renderer.analysis(of: snapshot.state)?.statistics }.value
        return AgentContext(
            sessionID: editor.document.id, revision: snapshot.revision, state: snapshot.state, metadata: renderer.info.json, statistics: statistics,
            filters: renderer.filterNames())
    }

    func openingImages() async -> [LabeledImage] {
        let snapshot = await editor.snapshot(run: run)
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
        let snapshot = await editor.snapshot(run: run)
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
            guard await editor.commit(outcome.state, expecting: snapshot.revision, run: run, script: code) else {
                return await stale(await editor.snapshot(run: run), said: said)
            }
        }
        let after = await editor.snapshot(run: run)
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
        return ToolExecution(payload: .object(payload), images: images)
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
