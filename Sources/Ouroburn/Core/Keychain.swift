import Foundation
import Security

/// Tiny generic-password helper. Used for the OAuth token + admin API key so secrets don't sit
/// in UserDefaults or shell history. Failures are non-fatal — the caller still falls back to
/// environment variables when the keychain is unavailable.
enum Keychain {
    static let service = "dev.sheldonhull.ouroburn"

    static func read(account: String) -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            if status != errSecItemNotFound {
                Log.error(Log.app, "Keychain read failed for \(account): OSStatus \(status)")
            }
            _ = query
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func write(account: String, value: String) {
        let data = Data(value.utf8)
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        // Try update first; fall back to add when no entry exists.
        let updateAttrs: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, updateAttrs as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var addQuery = baseQuery
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            if addStatus != errSecSuccess {
                Log.error(Log.app, "Keychain add failed for \(account): OSStatus \(addStatus)")
            }
        } else if updateStatus != errSecSuccess {
            Log.error(Log.app, "Keychain update failed for \(account): OSStatus \(updateStatus)")
        }
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess, status != errSecItemNotFound {
            Log.error(Log.app, "Keychain delete failed for \(account): OSStatus \(status)")
        }
    }
}
