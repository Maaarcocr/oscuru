import CoreGraphics
import Foundation
import Observation
import OscuruCore
import OscuruEngine
import OscuruScripting

/// One line of what the person and the assistant did to a photo.
struct TranscriptItem: Identifiable, Equatable {
    enum ScriptState: Equatable {
        case running
        case applied(changes: Int)
        case unchanged
        case failed(String)
        case stale
    }

    enum Kind: Equatable {
        case user(String)
        case assistant(String)
        case script(code: String, state: ScriptState, changes: [String], logs: [String])
        case notice(String, isError: Bool)
    }

    let id: String
    /// The instruction this belongs to.
    let run: String
    var kind: Kind
}

/// One photo open on screen: its settings over time, its picture, and the conversation with the
/// assistant. Everything that changes the photo goes through `history`, so there is one editing path.
@MainActor
@Observable
final class PhotoEditor {
    nonisolated let document: PhotoDocument
    nonisolated let info: PhotoInfo
    private(set) var history: EditHistory
    /// The photo as it is now, for the screen.
    private(set) var image: CGImage?
    /// The photo as opened, framed like the current one. Rendered when first asked for.
    private(set) var originalImage: CGImage?
    private(set) var renderError: String?

    private(set) var transcript: [TranscriptItem] = []
    /// The instruction being carried out, if any.
    private(set) var activeRun: String?
    private(set) var scriptsThisRun = 0
    private(set) var costs: [String: Double] = [:]

    nonisolated let renderer: PhotoRenderer
    private let runtime: ScriptRuntime
    private let library: Library
    private let account: Account
    private let modelClient: @MainActor () -> ModelClient
    private var conversation: [JSONValue] = []
    private var task: Task<Void, Never>?
    private var renderGeneration = 0
    private var originalCrop: Crop?

    init(document: PhotoDocument, info: PhotoInfo, renderer: PhotoRenderer, library: Library, account: Account, modelClient: @escaping @MainActor () -> ModelClient) {
        self.document = document
        self.info = info
        self.renderer = renderer
        self.library = library
        self.account = account
        self.modelClient = modelClient
        runtime = ScriptRuntime(host: renderer)
        history = EditHistory(state: document.state, revision: document.revision)
        refreshImage()
    }

    var state: EditingState { history.state }
    var isWorking: Bool { activeRun != nil }
    var isEdited: Bool { history.state != EditingState(defaults: info.defaults) }

    // MARK: Changing the photo

    /// Called after every change to `history`: saves and redraws.
    private func changed() {
        library.save(id: document.id, state: history.state, revision: history.revision)
        refreshImage()
    }

    func undo() {
        if history.undo() { changed() }
    }

    func redo() {
        if history.redo() { changed() }
    }

    func reset() {
        if history.push(EditingState(defaults: info.defaults), source: .reset) { changed() }
    }

    func apply(_ filter: SavedFilter) {
        if history.push(filter.look.applied(to: history.state, defaults: info.defaults), source: .filter(name: filter.name)) { changed() }
    }

    /// Undoes everything the assistant did for one instruction.
    func revert(run: String) {
        if history.revert(run: run) { changed() }
    }

    func canRevert(run: String) -> Bool { history.canRevert(run: run) }

    var currentLook: Look { Look(state: history.state, defaults: info.defaults) }

    // MARK: Pictures

    private func refreshImage() {
        renderGeneration += 1
        let generation = renderGeneration
        let state = history.state
        let renderer = renderer
        if originalCrop != state.crop {
            originalImage = nil
            originalCrop = nil
        }
        Task.detached(priority: .userInitiated) {
            let result = Result { try renderer.screenImage(of: state) }
            await MainActor.run {
                // A newer change is already on its way: its picture wins.
                guard generation == self.renderGeneration else { return }
                switch result {
                case .success(let image):
                    self.image = image
                    self.renderError = nil
                case .failure(let error):
                    self.renderError = String(describing: error)
                }
            }
        }
    }

    /// Renders the original for the before/after comparison, once per framing.
    func prepareOriginal() {
        guard originalImage == nil, originalCrop == nil else { return }
        let crop = history.state.crop
        originalCrop = crop
        let state = renderer.original(framedLike: history.state)
        let renderer = renderer
        Task.detached(priority: .userInitiated) {
            let image = try? renderer.screenImage(of: state)
            await MainActor.run {
                if self.originalCrop == crop { self.originalImage = image }
            }
        }
    }

    /// Develops the photo at full resolution into a temporary file for the share sheet.
    func export(_ format: ExportFormat) async throws -> URL {
        let name = (document.name as NSString).deletingPathExtension
        let url = FileManager.default.temporaryDirectory.appending(path: "\(name.isEmpty ? "Oscuru" : name).\(format == .heic ? "heic" : "jpg")")
        try? FileManager.default.removeItem(at: url)
        let state = history.state
        let renderer = renderer
        try await Task.detached(priority: .userInitiated) { try renderer.export(state, format: format, to: url) }.value
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

    private func add(_ run: String, _ kind: TranscriptItem.Kind, id: String = UUID().uuidString) {
        transcript.append(TranscriptItem(id: id, run: run, kind: kind))
    }

    /// Gives the assistant an instruction. It works until it is done or the person stops it.
    func send(_ instruction: String) {
        let text = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, activeRun == nil, account.isConnected else { return }
        let run = UUID().uuidString
        activeRun = run
        scriptsThisRun = 0
        add(run, .user(text))
        let client = modelClient()
        let model = account.activeModel
        let port = EditorPort(editor: self, run: run)
        let conversation = conversation
        task = Task {
            do {
                let turn = try await Agent.run(client: client, model: model, port: port, conversation: conversation, instruction: text) { event in
                    Task { @MainActor in self.handle(event, run: run) }
                }
                // Let the last events land before the run is closed.
                await Task.yield()
                self.conversation = turn.conversation
                if turn.stop == .cancelled { self.add(run, .notice(L10n.assistantStopped, isError: false)) }
            } catch let error as ModelError {
                self.add(run, .notice(L10n.message(for: error), isError: true))
            } catch {
                self.add(run, .notice(String(describing: error), isError: true))
            }
            self.finish(run)
        }
    }

    func stop() {
        task?.cancel()
    }

    private func finish(_ run: String) {
        // A script still marked as running when the run ended never finished.
        for index in transcript.indices {
            if case .script(let code, .running, let changes, let logs) = transcript[index].kind {
                transcript[index].kind = .script(code: code, state: .failed(L10n.scriptStopped), changes: changes, logs: logs)
            }
        }
        activeRun = nil
        task = nil
        Task {
            await account.refresh()
            await saveThumbnail()
        }
    }

    private func handle(_ event: AgentEvent, run: String) {
        switch event {
        case .thinking:
            break
        case .text(let text):
            add(run, .assistant(text))
        case .scriptStarted(let id, let code):
            scriptsThisRun += 1
            add(run, .script(code: code, state: .running, changes: [], logs: []), id: id)
        case .scriptFinished(let id, let payload):
            guard let index = transcript.firstIndex(where: { $0.id == id }), case .script(let code, _, _, _) = transcript[index].kind else { return }
            let changes = (payload["changes"]?.arrayValue ?? []).map { change in
                let path = change["path"]?.stringValue ?? ""
                if path.hasPrefix("curves.") { return path }
                return "\(path)  \((change["from"] ?? .null).described) → \((change["to"] ?? .null).described)"
            }
            let logs = (payload["logs"]?.arrayValue ?? []).compactMap(\.stringValue)
            let state: TranscriptItem.ScriptState
            switch payload["status"]?.stringValue {
            case "ok": state = payload["applied"] == true ? .applied(changes: changes.count) : .unchanged
            case "stale_revision": state = .stale
            default: state = .failed(payload["error"]?["message"]?.stringValue ?? "")
            }
            transcript[index].kind = .script(code: code, state: state, changes: changes, logs: logs)
        case .usage(let usage, let model):
            account.record(usage, model: model, run: run, photo: document.id)
            costs[run] = account.spent(onRun: run)
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
