import Foundation
import Security

/// Where the OpenRouter key is kept. The app uses the keychain; UI tests use memory.
protocol SecretStore: AnyObject {
    func read(_ name: String) -> String?
    func write(_ name: String, _ value: String?)
}

final class KeychainSecrets: SecretStore {
    private let service = "com.rudilosso.oscuru"

    private func query(_ name: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: name]
    }

    func read(_ name: String) -> String? {
        var query = query(name)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func write(_ name: String, _ value: String?) {
        SecItemDelete(query(name) as CFDictionary)
        guard let value else { return }
        var item = query(name)
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }
}

final class MemorySecrets: SecretStore {
    private var values: [String: String] = [:]

    init(_ values: [String: String] = [:]) {
        self.values = values
    }

    func read(_ name: String) -> String? { values[name] }
    func write(_ name: String, _ value: String?) { values[name] = value }
}
