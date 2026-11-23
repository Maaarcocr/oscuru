import AuthenticationServices
import CryptoKit
import Foundation
import Observation
import OscuruCore
import SwiftUI

/// The person's OpenRouter connection, model choice and usage record.
///
/// There is no Oscuru server: everyone signs in to their own OpenRouter account (or pastes a key)
/// and pays for their own usage. The key lives in the keychain and is only ever sent to OpenRouter.
/// Usage is recorded so the person can see what they spend; nothing here limits it.
@MainActor
@Observable
final class Account {
    /// Tried in order; the first one OpenRouter currently offers is used until the person picks another.
    static let preferredModels = ["anthropic/claude-sonnet-5.5", "anthropic/claude-sonnet-5", "google/gemini-4-carbon", "openai/gpt-6.1-terra"]

    private(set) var apiKey: String?
    /// A stable name for whoever pays: usage is recorded per user.
    private(set) var user: String?
    private(set) var keyInfo: KeyInfo?
    private(set) var models: [ModelInfo] = []
    private(set) var ledger = UsageLedger()
    var chosenModel: String? {
        didSet { saveSettings() }
    }

    private let secrets: SecretStore
    private let folder: URL?
    private let transport: HTTPTransport
    /// Kept between opening OpenRouter's page and getting a code back, including a code typed in by hand.
    private var pendingVerifier: String?

    private struct Settings: Codable {
        var model: String?
    }

    init(secrets: SecretStore, folder: URL?, transport: @escaping HTTPTransport) {
        self.secrets = secrets
        self.folder = folder
        self.transport = transport
        apiKey = secrets.read("openrouter-key")
        user = secrets.read("openrouter-user")
        if let folder {
            if let data = try? Data(contentsOf: folder.appending(path: "settings.json")), let settings = try? JSONDecoder().decode(Settings.self, from: data) {
                chosenModel = settings.model
            }
            if let data = try? Data(contentsOf: folder.appending(path: "usage.json")), let saved = try? JSONDecoder().decode(UsageLedger.self, from: data) {
                ledger = saved
            }
        }
    }

    var isConnected: Bool { apiKey != nil }

    /// The model requests go to: the person's choice, else the first preferred model on offer.
    var activeModel: String {
        if let chosenModel { return chosenModel }
        let offered = Set(models.map(\.id))
        return Account.preferredModels.first { offered.contains($0) } ?? Account.preferredModels[0]
    }

    func client() -> OpenRouter { OpenRouter(apiKey: apiKey, transport: transport) }

    private func saveSettings() {
        guard let folder, let data = try? JSONEncoder().encode(Settings(model: chosenModel)) else { return }
        try? data.write(to: folder.appending(path: "settings.json"), options: .atomic)
    }

    /// Fetches the model list and what OpenRouter says about the key. Failures are left for the next request to report.
    func refresh() async {
        if let list = try? await client().editingModels() { models = list.sorted { $0.name < $1.name } }
        if isConnected, let info = try? await client().keyInfo() { keyInfo = info }
    }

    /// Checks a key with OpenRouter and, when it works, stores it in the keychain.
    func connect(key: String, userFromSignIn: String? = nil) async throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let info = try await OpenRouter(apiKey: trimmed, transport: transport).keyInfo()
        // Without a user id from sign-in, a fingerprint of the key stands in.
        let digest = SHA256.hash(data: Data(trimmed.utf8)).map { String(format: "%02x", $0) }.joined()
        let name = userFromSignIn ?? "key-\(digest.prefix(16))"
        secrets.write("openrouter-key", trimmed)
        secrets.write("openrouter-user", name)
        apiKey = trimmed
        user = name
        keyInfo = info
    }

    func disconnect() {
        secrets.write("openrouter-key", nil)
        secrets.write("openrouter-user", nil)
        apiKey = nil
        user = nil
        keyInfo = nil
    }

    private func newChallenge() -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let verifier = String((0..<64).map { _ in alphabet[Int.random(in: 0..<alphabet.count)] })
        pendingVerifier = verifier
        return Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    /// Signs in with OpenRouter (OAuth PKCE): OpenRouter creates a key for the person and sends
    /// back a one-time code. Returns false when the page closed without one.
    func signIn(using session: WebAuthenticationSession) async throws -> Bool {
        guard let url = URL(string: OpenRouter.signInURL(codeChallenge: newChallenge(), callback: "oscuru://openrouter")) else { return false }
        let callback: URL
        do {
            callback = try await session.authenticate(using: url, callbackURLScheme: "oscuru")
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            return false
        }
        guard let code = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            return false
        }
        try await finishSignIn(code: code)
        return true
    }

    /// The same sign-in without a redirect: OpenRouter shows the code and the person pastes it in.
    /// For when the redirect back to the app does not work.
    func codeSignInURL() -> URL? {
        URL(string: OpenRouter.signInURL(codeChallenge: newChallenge(), callback: nil))
    }

    func finishSignIn(code: String) async throws {
        guard let verifier = pendingVerifier else { throw ModelError(.badRequest, L10n.signInExpired) }
        let result = try await OpenRouter(apiKey: nil, transport: transport).exchange(code: code.trimmingCharacters(in: .whitespacesAndNewlines), verifier: verifier)
        pendingVerifier = nil
        try await connect(key: result.key, userFromSignIn: result.userID)
    }

    // MARK: Usage

    /// Records what a request cost. Returns the cost.
    @discardableResult
    func record(_ usage: Usage, model: String, run: String, photo: String) -> Double {
        guard let user else { return 0 }
        let cost = OpenRouter.cost(of: usage, model: models.first { $0.id == model })
        ledger.add(.init(date: Date(), user: user, model: model, cost: cost, promptTokens: usage.promptTokens, completionTokens: usage.completionTokens, run: run, photo: photo))
        if let folder, let data = try? JSONEncoder().encode(ledger) { try? data.write(to: folder.appending(path: "usage.json"), options: .atomic) }
        return cost
    }

    func spent(onRun run: String) -> Double { user.map { ledger.spent(by: $0, onRun: run) } ?? 0 }

    var spentToday: Double { user.map { ledger.spent(by: $0, since: Calendar.current.startOfDay(for: Date())) } ?? 0 }

    var spentThisMonth: Double {
        guard let user, let start = Calendar.current.dateInterval(of: .month, for: Date())?.start else { return 0 }
        return ledger.spent(by: user, since: start)
    }

    var spentInTotal: Double { user.map { ledger.total(for: $0) } ?? 0 }
}
