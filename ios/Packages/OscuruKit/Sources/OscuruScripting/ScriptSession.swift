import Foundation
import OscuruCore

/// One script's transaction: a draft of the settings and everything the script produced.
/// `call` is the single door between JavaScript and the app.
final class ScriptSession {
    let request: ScriptRequest
    let host: ScriptHost
    let isCancelled: () -> Bool

    var draft: EditingState
    var logs: [String] = []
    var shown: [LabeledImage] = []
    private var measured: (state: EditingState, analysis: ImageAnalysis)?

    static let maxLogLines = 200
    static let maxLogLineLength = 2000

    init(request: ScriptRequest, host: ScriptHost, isCancelled: @escaping () -> Bool) {
        self.request = request
        self.host = host
        self.isCancelled = isCancelled
        draft = request.state
    }

    struct Cancelled: Error {}
    struct Failure: Error {
        let message: String
    }

    private var defaults: PhotoDefaults { request.info.defaults }

    private func analysis() throws -> ImageAnalysis {
        if let measured, measured.state == draft { return measured.analysis }
        guard let analysis = host.analysis(of: draft) else { throw Failure(message: "The photo could not be rendered, so there is nothing to measure.") }
        measured = (draft, analysis)
        return analysis
    }

    /// Carries out one API call from a script. Arguments arrive as JSON; `null` stands for "not given".
    func call(_ name: String, _ arguments: [JSONValue]) throws -> JSONValue {
        if isCancelled() { throw Cancelled() }
        func argument(_ index: Int) -> JSONValue { index < arguments.count ? arguments[index] : .null }
        switch name {
        case "getState":
            var state = draft.json.objectValue ?? [:]
            state["revision"] = .number(Double(request.revision))
            return .object(state)
        case "getMetadata": return request.info.json
        case "getHistogram": return try analysis().histogram.json
        case "getStatistics": return try analysis().statistics
        case "adjust": try draft.adjust(argument(0))
        case "curves.set": try draft.setCurve(channel: argument(0), points: argument(1))
        case "curves.get": return .array((draft.curves[try choice(argument(0), in: Specs.curveChannels, "curve channel")] ?? []).map { .array($0.map { .number($0) }) })
        case "curves.reset":
            if argument(0) == .null { try draft.reset(section: "curves", defaults: defaults) } else { try draft.setCurve(channel: argument(0), points: [[0, 0], [1, 1]]) }
        case "hsl.adjust": try draft.adjustHSL(color: argument(0), adjustments: argument(1))
        case "hsl.get": return .object((draft.hsl[try choice(argument(0), in: Specs.colorRanges, "hsl colour")] ?? [:]).mapValues { .number($0) })
        case "hsl.reset":
            if argument(0) == .null {
                try draft.reset(section: "hsl", defaults: defaults)
            } else {
                try draft.adjustHSL(color: argument(0), adjustments: ["hue": 0, "saturation": 0, "luminance": 0])
            }
        case "grading.set": try draft.setGrading(range: argument(0), settings: argument(1))
        case "grading.get": return .object(draft.grading[try choice(argument(0), in: Specs.gradingRanges, "grading range")].mapValues { .number($0) })
        case "grading.configure": try draft.configureGrading(argument(0))
        case "grading.reset": try draft.reset(section: "grading", defaults: defaults)
        case "detail.set": try draft.setDetail(argument(0))
        case "detail.get": return .object(draft.detail.mapValues { .number($0) })
        case "grain.set": try draft.setGrain(argument(0))
        case "grain.get": return .object(draft.grain.mapValues { .number($0) })
        case "halation.set": try draft.setHalation(argument(0))
        case "halation.get": return .object(draft.halation.mapValues { .number($0) })
        case "local.set": try draft.setLocal(name: argument(0), settings: argument(1))
        case "local.get": return try draft.localAdjustment(named: argument(0)).json
        case "local.list": return .array(draft.local.map(\.json))
        case "local.remove": try draft.removeLocal(name: argument(0))
        case "local.reset": try draft.reset(section: "local", defaults: defaults)
        case "crop": try draft.setCrop(argument(0))
        case "reset": try draft.reset(section: argument(0) == .null ? "all" : argument(0), defaults: defaults)
        case "revert": draft = request.state
        case "commit": break
        case "show": try show(which: argument(0), options: argument(1))
        case "filters.list": return .array(host.filterNames().map { .string($0) })
        case "filters.apply":
            let wanted = try filterName(argument(0))
            guard let filter = host.filter(named: wanted) else {
                let names = host.filterNames()
                throw Failure(message: "There is no saved filter named \"\(wanted)\". " + (names.isEmpty ? "No filters are saved yet." : "Saved filters: \(names.joined(separator: ", "))."))
            }
            let current = draft
            draft = try filter.applied(to: current, defaults: defaults) { host.pixels(of: LookFit.base(current, wholeFrame: false)) }
        case "filters.save":
            let wanted = try filterName(argument(0))
            guard host.saveFilter(name: wanted, look: Look(state: draft, defaults: defaults), state: draft) else { throw Failure(message: "The filter could not be saved under the name \"\(wanted)\".") }
        case "filters.delete":
            let wanted = try filterName(argument(0))
            guard host.deleteFilter(name: wanted) else { throw Failure(message: "There is no saved filter named \"\(wanted)\".") }
        case "log":
            if logs.count < ScriptSession.maxLogLines {
                logs.append(String((argument(0).stringValue ?? argument(0).text()).prefix(ScriptSession.maxLogLineLength)))
            } else if logs.count == ScriptSession.maxLogLines {
                logs.append("… further log lines were dropped")
            }
        default:
            throw Failure(message: "photo has no function \(name)")
        }
        return .null
    }

    private func choice(_ value: JSONValue, in allowed: [String], _ what: String) throws -> String {
        guard let text = value.stringValue, allowed.contains(text) else {
            throw StateError("\(what) must be one of \(allowed.map { "\"\($0)\"" }.joined(separator: ", ")), got \(value.described)")
        }
        return text
    }

    private func filterName(_ value: JSONValue) throws -> String {
        guard let text = value.stringValue, !FilterCollection.cleanName(text).isEmpty else {
            throw StateError("a filter name must be a non-empty string, got \(value.described)")
        }
        return FilterCollection.cleanName(text)
    }

    private func show(which: JSONValue, options: JSONValue) throws {
        let kind = which == .null ? "current" : try choice(which, in: ["current", "before", "original", "mask"], "what to show")
        var region: ScriptRegion?
        var maxEdge = Prompt.defaultImageEdge
        var maskName: JSONValue = .null
        if options != .null {
            guard let members = options.objectValue else { throw StateError("show options must be an object, got \(options.described)") }
            for key in members.keys where !["region", "maxEdge", "mask"].contains(key) {
                throw StateError("show has no option \"\(key)\". Valid options: region, maxEdge, mask")
            }
            maskName = members["mask"] ?? .null
            if let value = members["maxEdge"], value != .null {
                guard let number = value.doubleValue, number.isFinite else { throw StateError("show maxEdge must be a number, got \(value.described)") }
                maxEdge = Int(min(Double(Prompt.maxImageEdge), max(Double(Prompt.minImageEdge), number)).rounded())
            }
            if let value = members["region"], value != .null {
                func part(_ key: String) throws -> Double {
                    guard let number = value[key]?.doubleValue, number.isFinite, number >= 0, number <= 1 else {
                        throw StateError("show region.\(key) must be a number between 0 and 1, got \((value[key] ?? .null).described)")
                    }
                    return number
                }
                let candidate = ScriptRegion(x: try part("x"), y: try part("y"), width: try part("width"), height: try part("height"))
                guard candidate.width >= 0.02, candidate.height >= 0.02, candidate.x + candidate.width <= 1.000001, candidate.y + candidate.height <= 1.000001 else {
                    throw StateError("show region must lie inside the frame and be at least 0.02 wide and high")
                }
                region = candidate
            }
        }
        if kind == "mask" {
            guard maskName != .null else { throw StateError("show(\"mask\") needs options.mask: the name of a local adjustment") }
            let adjustment = try draft.localAdjustment(named: maskName)
            guard let preview = host.maskImage(of: draft, mask: adjustment.mask, region: region, maxEdge: maxEdge) else {
                throw Failure(message: "The photo could not be rendered.")
            }
            let zoom = region.map { " (region x \(formatNumber($0.x)), y \(formatNumber($0.y)), width \(formatNumber($0.width)), height \(formatNumber($0.height)))" } ?? ""
            let percent = formatNumber((preview.coverage * 1000).rounded() / 10)
            var label = "Shown by your script, picture \(shown.count + 1): the mask of the local adjustment \"\(adjustment.name)\", painted red over the photo with the settings at that point in your script\(zoom). It covers \(percent)% of the frame."
            if preview.coverage < 0.002 { label += " It is empty: nothing in the photo matched it." }
            shown.append(LabeledImage(label: label, jpeg: preview.jpeg))
            return
        } else if maskName != .null {
            throw StateError("options.mask is only for show(\"mask\", { mask: name })")
        }
        let state: EditingState
        let what: String
        switch kind {
        case "before":
            state = request.before
            what = "the photo as it was when the person gave this instruction"
        case "original":
            var original = EditingState(defaults: defaults)
            original.crop = draft.crop
            state = original
            what = "the original photo, with no edits"
        default:
            state = draft
            what = "the photo with the settings at that point in your script"
        }
        guard let jpeg = host.image(of: state, region: region, maxEdge: maxEdge) else { throw Failure(message: "The photo could not be rendered.") }
        let zoom = region.map { " (region x \(formatNumber($0.x)), y \(formatNumber($0.y)), width \(formatNumber($0.width)), height \(formatNumber($0.height)))" } ?? ""
        shown.append(LabeledImage(label: "Shown by your script, picture \(shown.count + 1): \(what)\(zoom).", jpeg: jpeg))
    }
}
