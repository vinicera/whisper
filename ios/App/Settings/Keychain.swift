import Foundation
import Security

/// Guarda segredos (token da ponte, chave do Gemini) no Keychain do iPhone.
/// `AfterFirstUnlock` permite ler com a tela bloqueada (necessario na Fase 3).
enum Keychain {
    private static let service = "dev.whisper.app"

    private static func baseQuery(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }

    static func set(_ value: String, for key: String) {
        SecItemDelete(baseQuery(key) as CFDictionary)
        guard !value.isEmpty else { return }
        var add = baseQuery(key)
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(add as CFDictionary, nil)
        if status != errSecSuccess { print("Keychain: falha ao salvar \(key): \(status)") }
    }

    static func get(_ key: String) -> String {
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else {
            return ""
        }
        return String(decoding: data, as: UTF8.self)
    }
}
