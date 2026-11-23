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
    static func assistantEditing(step: Int) -> String {
        let number = String(step)
        return String(localized: "assistant.editing \(number)")
    }
    static var assistantStopped: String { String(localized: "assistant.stopped") }
    static func cost(_ amount: String) -> String { String(localized: "assistant.cost \(amount)") }
    static var suggestions: [String] {
        [
            String(localized: "suggest.cinematic"), String(localized: "suggest.sky"), String(localized: "suggest.natural"),
            String(localized: "suggest.mono"),
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
    static func scriptTitle(_ state: TranscriptItem.ScriptState) -> String {
        switch state {
        case .running: return String(localized: "script.running")
        case .applied(let changes):
            let count = String(changes)
            return String(localized: "script.applied \(count)")
        case .unchanged: return String(localized: "script.unchanged")
        case .failed: return String(localized: "script.failed")
        case .stale: return String(localized: "script.stale")
        }
    }

    // MARK: Filters
    static var filters: String { String(localized: "filters.title") }
    static var filterSaveTitle: String { String(localized: "filters.save.title") }
    static var filterSaveFooter: String { String(localized: "filters.save.footer") }
    static var filterSavedTitle: String { String(localized: "filters.saved.title") }
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
