import Foundation
import OscuruCore

/// Every user-facing string in the app. Keys live in Localizable.xcstrings (English and Italian);
/// `scripts/check-strings.py` fails CI when a key here is missing a translation or is unused.
enum L10n {
    // MARK: Common
    static var ok: String { String(localized: "common.ok") }
    static var cancel: String { String(localized: "common.cancel") }
    static var done: String { String(localized: "common.done") }
    static var save: String { String(localized: "common.save") }
    static var delete: String { String(localized: "common.delete") }
    static var rename: String { String(localized: "common.rename") }
    static var close: String { String(localized: "common.close") }
    static var settings: String { String(localized: "common.settings") }

    // MARK: Library
    static var libraryEmptyTitle: String { String(localized: "library.empty.title") }
    static var libraryEmptyMessage: String { String(localized: "library.empty.message") }
    static var addPhoto: String { String(localized: "library.add") }
    static var fromPhotos: String { String(localized: "library.fromPhotos") }
    static var fromFiles: String { String(localized: "library.fromFiles") }
    static var importFailed: String { String(localized: "library.importFailed") }
    static var select: String { String(localized: "library.select") }
    static var selectAll: String { String(localized: "library.selectAll") }
    static var deselectAll: String { String(localized: "library.deselectAll") }
    static var selectPhotos: String { String(localized: "library.selectPhotos") }
    static func selectedCount(_ count: Int) -> String {
        if count == 1 { return String(localized: "library.selectedOne") }
        let text = String(count)
        return String(localized: "library.selected \(text)")
    }
    static var share: String { String(localized: "share.title") }
    static var shareDeveloped: String { String(localized: "share.developed") }
    static var shareDevelopedFooter: String { String(localized: "share.developed.footer") }
    static var shareOriginal: String { String(localized: "share.original") }
    static var shareOriginalFooter: String { String(localized: "share.original.footer") }
    static var exportFailed: String { String(localized: "share.failed") }
    static func deleteTitle(_ count: Int) -> String {
        if count == 1 { return String(localized: "library.deleteOne") }
        let text = String(count)
        return String(localized: "library.delete \(text)")
    }
    static var deleteMessage: String { String(localized: "library.delete.message") }
    static var apply: String { String(localized: "library.apply") }

    // MARK: Styles
    static var styles: String { String(localized: "styles.title") }
    static var styleNamePlaceholder: String { String(localized: "styles.name") }
    static var saveLook: String { String(localized: "styles.saveLook") }
    static var stylesEmpty: String { String(localized: "styles.empty") }

    // MARK: New style
    static var newStyle: String { String(localized: "style.new") }
    static var styleIntro: String { String(localized: "style.intro") }
    static var styleSingle: String { String(localized: "style.single") }
    static var stylePair: String { String(localized: "style.pair") }
    static var styleEdited: String { String(localized: "style.edited") }
    static var styleEditedHint: String { String(localized: "style.edited.hint") }
    static var styleOriginal: String { String(localized: "style.original") }
    static var styleOriginalHint: String { String(localized: "style.original.hint") }
    static var removePicture: String { String(localized: "style.remove") }
    static var createStyle: String { String(localized: "style.create") }
    static var styleFailed: String { String(localized: "style.failed") }
    static var styleFraming: String { String(localized: "style.framing") }
    static var styleResultStyled: String { String(localized: "style.result.styled") }
    static var styleResultEdit: String { String(localized: "style.result.edit") }
    static var styleResultOnYours: String { String(localized: "style.result.onYours") }
    static var styleResultReference: String { String(localized: "style.result.reference") }
    static var styleVeryClose: String { String(localized: "style.veryClose") }
    static var styleClose: String { String(localized: "style.close") }
    static var styleSaved: String { String(localized: "style.saved") }

    // MARK: Camera
    static var camera: String { String(localized: "camera.title") }
    static var cameraShutter: String { String(localized: "camera.shutter") }
    static var cameraLastShot: String { String(localized: "camera.lastShot") }
    static var cameraViewfinder: String { String(localized: "camera.viewfinder") }
    static var cameraExposure: String { String(localized: "camera.exposure") }
    static var cameraDeniedTitle: String { String(localized: "camera.denied.title") }
    static var cameraDeniedMessage: String { String(localized: "camera.denied.message") }
    static var cameraOpenSettings: String { String(localized: "camera.openSettings") }
    static var cameraUnavailableTitle: String { String(localized: "camera.unavailable.title") }
    static var cameraUnavailableMessage: String { String(localized: "camera.unavailable.message") }
    static var cameraNoRAW: String { String(localized: "camera.noRAW") }
    static var cameraFailed: String { String(localized: "camera.failed") }

    // MARK: Photo
    static var photoUnreadable: String { String(localized: "photo.unreadable") }

    // MARK: Composer
    static var composerPlaceholder: String { String(localized: "composer.placeholder") }
    static var composerWhileWorking: String { String(localized: "composer.working") }
    static var composerConnect: String { String(localized: "composer.connect") }
    static var send: String { String(localized: "composer.send") }
    static var stop: String { String(localized: "composer.stop") }
    /// Ideas for a first instruction: a short label, and what is sent.
    struct Suggestion: Hashable {
        let label: String
        let instruction: String
    }
    static var suggestions: [Suggestion] {
        [
            Suggestion(label: String(localized: "suggest.cinematic.label"), instruction: String(localized: "suggest.cinematic")),
            Suggestion(label: String(localized: "suggest.sky.label"), instruction: String(localized: "suggest.sky")),
            Suggestion(label: String(localized: "suggest.natural.label"), instruction: String(localized: "suggest.natural")),
            Suggestion(label: String(localized: "suggest.mono.label"), instruction: String(localized: "suggest.mono")),
        ]
    }

    // MARK: Thread
    /// "Original · Apple iPhone 17 Pro · RAW"
    static func originalCaption(_ info: PhotoInfo) -> String {
        var parts = [String(localized: "thread.original")]
        if let model = info.model, !model.isEmpty { parts.append(model) }
        if info.isRaw { parts.append("RAW") }
        return parts.joined(separator: " · ")
    }
    static func appliedStyle(_ name: String) -> String { String(localized: "thread.style \(name)") }
    static var restored: String { String(localized: "thread.restore") }
    static var backToOriginal: String { String(localized: "thread.startOver") }
    static var earlierEdits: String { String(localized: "thread.earlier") }
    static var looking: String { String(localized: "thread.looking") }
    static var stopped: String { String(localized: "thread.stopped") }
    static var continueRun: String { String(localized: "thread.continue") }
    static var working: String { String(localized: "library.working") }
    static var queuedNote: String { String(localized: "thread.queued") }
    static var reconnecting: String { String(localized: "thread.reconnecting") }
    static var summarizing: String { String(localized: "thread.summarizing") }
    static func storageProblem(_ detail: String) -> String { String(localized: "thread.storageProblem \(detail)") }
    static var script: String { String(localized: "thread.script") }
    static func step(_ number: Int) -> String {
        let text = String(number)
        return String(localized: "step.title \(text)")
    }
    static func stepsCount(_ count: Int) -> String {
        if count == 1 { return String(localized: "thread.oneStep") }
        let text = String(count)
        return String(localized: "thread.steps \(text)")
    }
    static func stepTitle(_ number: Int, _ outcome: Step.Outcome) -> String {
        let title = step(number)
        switch outcome {
        case .applied: return title
        case .running: return "\(title) · \(String(localized: "script.running"))"
        case .unchanged: return "\(title) · \(String(localized: "script.unchanged"))"
        case .failed, .stale: return "\(title) · \(String(localized: "script.failed"))"
        case .stopped: return "\(title) · \(String(localized: "script.cutOff"))"
        }
    }

    static func message(for error: ModelError) -> String {
        let summary: String
        switch error.kind {
        case .unauthorized: summary = String(localized: "error.key")
        case .payment: summary = String(localized: "error.credits")
        case .rateLimit: summary = String(localized: "error.rate")
        case .network: summary = String(localized: "error.network")
        case .server, .invalidResponse: summary = String(localized: "error.server")
        case .badRequest: summary = String(localized: "error.request")
        }
        return error.message.isEmpty ? summary : "\(summary)\n\(error.message)"
    }

    // MARK: Viewer
    static var before: String { String(localized: "photo.before") }
    static var beforeHint: String { String(localized: "photo.before.hint") }
    static var restore: String { String(localized: "viewer.restore") }

    /// A change a script made, in words: "Highlights −45", "Blues saturation −10", "Tone curve".
    static func describe(_ change: StepChange) -> String {
        let parts = change.path.split(separator: ".").map(String.init)
        func signed(_ value: JSONValue) -> String {
            guard let number = value.doubleValue else { return value.described }
            let text = formatNumber(number).replacingOccurrences(of: "-", with: "−")
            return number > 0 ? "+\(text)" : text
        }
        func plain(_ value: JSONValue) -> String {
            value.doubleValue.map { formatNumber($0) } ?? value.described
        }
        func percent(_ value: JSONValue) -> String {
            value.doubleValue.map { "\(Int(($0 * 100).rounded()))%" } ?? value.described
        }
        switch (parts.first ?? "", parts.count) {
        case ("global", 2):
            let name = parameter(parts[1])
            switch parts[1] {
            case "temperature": return "\(name) \(plain(change.to)) K"
            case "exposureEV": return "\(name) \(signed(change.to)) EV"
            default: return "\(name) \(signed(change.to))"
            }
        case ("detail", 2):
            return "\(parameter(parts[1])) \(plain(change.to))"
        case ("curves", 2):
            return curve(parts[1])
        case ("hsl", 3):
            return "\(color(parts[1])) \(property(parts[2])) \(signed(change.to))"
        case ("grading", 3):
            let value = parts[2] == "hue" ? "\(plain(change.to))°" : percent(change.to)
            return "\(String(localized: "change.grading")) \(range(parts[1])) \(property(parts[2])) \(value)"
        case ("grading", 2):
            return "\(String(localized: "change.grading")) \(property(parts[1])) \(percent(change.to))"
        case ("grain", 2):
            return "\(String(localized: "change.grain")) \(effectProperty(parts[1])) \(plain(change.to))"
        case ("halation", 2):
            return "\(String(localized: "change.halation")) \(effectProperty(parts[1])) \(plain(change.to))"
        case ("local", _):
            let names = (change.to.arrayValue ?? []).compactMap { $0["name"]?.stringValue }
            return names.isEmpty ? String(localized: "change.localNone") : "\(String(localized: "change.local")) \(names.joined(separator: ", "))"
        case ("crop", _):
            return String(localized: "change.crop")
        default:
            return change.path
        }
    }

    static func parameter(_ name: String) -> String {
        switch name {
        case "exposureEV": return String(localized: "param.exposure")
        case "contrast": return String(localized: "param.contrast")
        case "highlights": return String(localized: "param.highlights")
        case "shadows": return String(localized: "param.shadows")
        case "whites": return String(localized: "param.whites")
        case "blacks": return String(localized: "param.blacks")
        case "temperature": return String(localized: "param.temperature")
        case "tint": return String(localized: "param.tint")
        case "texture": return String(localized: "param.texture")
        case "clarity": return String(localized: "param.clarity")
        case "dehaze": return String(localized: "param.dehaze")
        case "vibrance": return String(localized: "param.vibrance")
        case "saturation": return String(localized: "param.saturation")
        case "vignette": return String(localized: "param.vignette")
        case "sharpening": return String(localized: "param.sharpening")
        case "noiseReduction": return String(localized: "param.noiseReduction")
        case "colorNoiseReduction": return String(localized: "param.colorNoiseReduction")
        default: return name
        }
    }

    static func color(_ name: String) -> String {
        switch name {
        case "red": return String(localized: "color.red")
        case "orange": return String(localized: "color.orange")
        case "yellow": return String(localized: "color.yellow")
        case "green": return String(localized: "color.green")
        case "aqua": return String(localized: "color.aqua")
        case "blue": return String(localized: "color.blue")
        case "purple": return String(localized: "color.purple")
        case "magenta": return String(localized: "color.magenta")
        default: return name
        }
    }

    static func curve(_ channel: String) -> String {
        switch channel {
        case "red": return String(localized: "curve.red")
        case "green": return String(localized: "curve.green")
        case "blue": return String(localized: "curve.blue")
        default: return String(localized: "curve.rgb")
        }
    }

    static func range(_ name: String) -> String {
        switch name {
        case "shadows": return String(localized: "range.shadows")
        case "midtones": return String(localized: "range.midtones")
        default: return String(localized: "range.highlights")
        }
    }

    static func property(_ name: String) -> String {
        switch name {
        case "hue": return String(localized: "property.hue")
        case "saturation": return String(localized: "property.saturation")
        case "luminance": return String(localized: "property.luminance")
        case "blending": return String(localized: "property.blending")
        default: return String(localized: "property.balance")
        }
    }

    static func effectProperty(_ name: String) -> String {
        switch name {
        case "amount": return String(localized: "property.amount")
        case "size": return String(localized: "property.size")
        case "roughness": return String(localized: "property.roughness")
        case "radius": return String(localized: "property.radius")
        default: return String(localized: "property.threshold")
        }
    }

    // MARK: Settings
    static var settingsConnected: String { String(localized: "settings.connected") }
    static var settingsSignIn: String { String(localized: "settings.signIn") }
    static var settingsOtherWays: String { String(localized: "settings.otherWays") }
    static var settingsCodeTitle: String { String(localized: "settings.code.title") }
    static var settingsCodeFooter: String { String(localized: "settings.code.footer") }
    static var settingsGetCode: String { String(localized: "settings.getCode") }
    static var settingsCodePlaceholder: String { String(localized: "settings.code") }
    static var settingsKeyTitle: String { String(localized: "settings.key.title") }
    static var settingsKeyFooter: String { String(localized: "settings.key.footer") }
    static var settingsKeyPlaceholder: String { String(localized: "settings.keyPlaceholder") }
    static var settingsConnect: String { String(localized: "settings.connect") }
    static var settingsDisconnect: String { String(localized: "settings.disconnect") }
    static var settingsDisconnectTitle: String { String(localized: "settings.disconnect.title") }
    static var settingsDisconnectMessage: String { String(localized: "settings.disconnect.message") }
    static var settingsAccountFooter: String { String(localized: "settings.account.footer") }
    static var settingsConnectFailed: String { String(localized: "settings.connectFailed") }
    static var signInExpired: String { String(localized: "settings.signInExpired") }
    static var settingsModel: String { String(localized: "settings.model") }
    static var settingsModelFooter: String { String(localized: "settings.model.footer") }
    static func modelPrice(id: String, input: Double, output: Double) -> String {
        let inputPrice = String(format: "%.2f", input)
        let outputPrice = String(format: "%.2f", output)
        return String(localized: "settings.model.price \(id) \(inputPrice) \(outputPrice)")
    }
    static var usageTitle: String { String(localized: "usage.title") }
    static var usageToday: String { String(localized: "usage.today") }
    static var usageMonth: String { String(localized: "usage.month") }
    static var usageTotal: String { String(localized: "usage.total") }
    static var usageFooter: String { String(localized: "usage.footer") }
    static var privacyTitle: String { String(localized: "privacy.title") }
    static var privacyBody: String { String(localized: "privacy.body") }
}
