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
    static var settings: String { String(localized: "common.settings") }

    // MARK: Library
    static var libraryEmptyTitle: String { String(localized: "library.empty.title") }
    static var libraryEmptyMessage: String { String(localized: "library.empty.message") }
    static var addPhoto: String { String(localized: "library.add") }
    static var fromPhotos: String { String(localized: "library.fromPhotos") }
    static var fromFiles: String { String(localized: "library.fromFiles") }
    static var importFailed: String { String(localized: "library.importFailed") }

    // MARK: Photo
    static var photoUnreadable: String { String(localized: "photo.unreadable") }
    static var original: String { String(localized: "photo.original") }
    static var undo: String { String(localized: "photo.undo") }
    static var redo: String { String(localized: "photo.redo") }
    static var more: String { String(localized: "photo.more") }
    static var export: String { String(localized: "photo.export") }
    static var exportJPEG: String { String(localized: "photo.export.jpeg") }
    static var exportHEIC: String { String(localized: "photo.export.heic") }
    static var exportFailed: String { String(localized: "photo.export.failed") }
    static var resetEdits: String { String(localized: "photo.reset") }
    static var resetTitle: String { String(localized: "photo.reset.title") }
    static var resetMessage: String { String(localized: "photo.reset.message") }

    // MARK: Assistant
    static var promptPlaceholder: String { String(localized: "assistant.placeholder") }
    static var send: String { String(localized: "assistant.send") }
    static var stop: String { String(localized: "assistant.stop") }
    static var revert: String { String(localized: "assistant.revert") }
    static var connectToEdit: String { String(localized: "assistant.connect") }
    static var assistantLooking: String { String(localized: "assistant.looking") }
    static func step(_ number: Int) -> String {
        let text = String(number)
        return String(localized: "step.title \(text)")
    }
    static var before: String { String(localized: "photo.before") }
    static var beforeHint: String { String(localized: "photo.before.hint") }
    static var conversationHint: String { String(localized: "conversation.hint") }
    static var assistantStopped: String { String(localized: "assistant.stopped") }
    static func cost(_ amount: String) -> String { String(localized: "assistant.cost \(amount)") }
    /// Ideas for a first instruction: a short label, and what is sent.
    static var suggestions: [(label: String, instruction: String)] {
        [
            (String(localized: "suggest.cinematic.label"), String(localized: "suggest.cinematic")),
            (String(localized: "suggest.sky.label"), String(localized: "suggest.sky")),
            (String(localized: "suggest.natural.label"), String(localized: "suggest.natural")),
            (String(localized: "suggest.mono.label"), String(localized: "suggest.mono")),
        ]
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

    // MARK: Conversation
    static var conversation: String { String(localized: "conversation.title") }
    static var conversationEmpty: String { String(localized: "conversation.empty") }
    static var scriptStopped: String { String(localized: "script.stopped") }
    static var showScript: String { String(localized: "conversation.showScript") }
    static func stepTitle(_ number: Int, _ state: TranscriptItem.ScriptState) -> String {
        let title = step(number)
        switch state {
        case .applied: return title
        case .running: return "\(title) · \(String(localized: "script.running"))"
        case .unchanged: return "\(title) · \(String(localized: "script.unchanged"))"
        case .failed: return "\(title) · \(String(localized: "script.failed"))"
        case .stale: return "\(title) · \(String(localized: "script.stale"))"
        }
    }
    static func moreChanges(_ count: Int) -> String {
        let text = String(count)
        return String(localized: "conversation.more \(text)")
    }

    /// A change a script made, in words: "Highlights −45", "Blue · saturation −10", "Tone curve".
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
            return "\(color(parts[1])) · \(property(parts[2])) \(signed(change.to))"
        case ("grading", 3):
            let value = parts[2] == "hue" ? "\(plain(change.to))°" : percent(change.to)
            return "\(String(localized: "change.grading")) \(range(parts[1])) · \(property(parts[2])) \(value)"
        case ("grading", 2):
            return "\(String(localized: "change.grading")) · \(property(parts[1])) \(percent(change.to))"
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

    // MARK: Filters
    static var filters: String { String(localized: "filters.title") }
    static var filtersEmpty: String { String(localized: "filters.empty") }
    static var filterNamePlaceholder: String { String(localized: "filters.name") }

    // MARK: Settings
    static var settingsAccount: String { String(localized: "settings.account") }
    static var settingsConnected: String { String(localized: "settings.connected") }
    static var settingsKey: String { String(localized: "settings.key") }
    static var settingsSignIn: String { String(localized: "settings.signIn") }
    static var settingsGetCode: String { String(localized: "settings.getCode") }
    static var settingsCodePlaceholder: String { String(localized: "settings.code") }
    static var settingsKeyPlaceholder: String { String(localized: "settings.keyPlaceholder") }
    static var settingsUse: String { String(localized: "settings.use") }
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
    static var usageKey: String { String(localized: "usage.key") }
    static var usageFooter: String { String(localized: "usage.footer") }
    static var privacyTitle: String { String(localized: "privacy.title") }
    static var privacyBody: String { String(localized: "privacy.body") }
}
