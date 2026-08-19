import Foundation
import Security

/// Minimaler Keychain-Wrapper — nur für die Session-Cookies der "gemerkten Konten" genutzt
/// (User-Anfrage 2026-08-19: Offline-Benutzerwechsel). Session-Cookies sind so mächtig wie ein
/// Passwort (voller Account-Zugriff), gehören deshalb NICHT in UserDefaults (unverschlüsseltes
/// Plist) — die generische, öffentlich dokumentierte SecItem-API ist der richtige Ort dafür.
enum KeychainHelper {
    private static let service = "com.goldfish.rememberedSessions"

    static func set(_ data: Data, forKey key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attributes as CFDictionary, nil)
    }

    static func get(forKey key: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    static func delete(forKey key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
