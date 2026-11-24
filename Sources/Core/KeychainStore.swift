import Foundation
import Security

/// Хранение ключа входа в Keychain. Приложения без подписи (симулятор, некоторые
/// способы установки — LiveContainer и т.п.) не имеют доступа к Keychain: тогда
/// ключ хранится в настройках приложения, иначе вход теряется при переподключении.
enum KeychainStore {
    private static let service = "5pda"
    private static func fallbackKey(_ key: String) -> String { "kc_fallback_" + key }

    static func set(_ value: String, for key: String) {
        remove(key)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        if SecItemAdd(query as CFDictionary, nil) == errSecSuccess, get(key, fallback: false) == value {
            UserDefaults.standard.removeObject(forKey: fallbackKey(key))
        } else {
            UserDefaults.standard.set(value, forKey: fallbackKey(key))
        }
    }

    static func get(_ key: String) -> String? { get(key, fallback: true) }

    private static func get(_ key: String, fallback: Bool) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else {
            return fallback ? UserDefaults.standard.string(forKey: fallbackKey(key)) : nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func remove(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
        UserDefaults.standard.removeObject(forKey: fallbackKey(key))
    }
}
