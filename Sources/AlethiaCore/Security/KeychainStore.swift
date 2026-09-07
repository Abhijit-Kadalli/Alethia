import Foundation
#if canImport(Security)
import Security
#endif

/// Small generic-password Keychain wrapper. On non-Apple platforms (tests) it falls back
/// to an in-memory store.
public enum KeychainStore {
    static let service = "app.alethia"

    #if !canImport(Security)
    private static let memoryLock = NSLock()
    nonisolated(unsafe) private static var memory: [String: String] = [:]
    #endif

    public static func get(account: String) -> String? {
        #if canImport(Security)
        if let value = copy(account: account, service: service) { return value }
        // 0.1.x stored the OpenRouter key under a different service and account.
        if account == "llm.apiKey",
           let legacy = copy(account: "openrouter.apiKey", service: "app.alethia.macos"),
           !legacy.isEmpty {
            try? set(legacy, account: account)
            return legacy
        }
        return nil
        #else
        memoryLock.lock(); defer { memoryLock.unlock() }
        return memory[account]
        #endif
    }

    public static func set(_ value: String, account: String) throws {
        #if canImport(Security)
        if value.isEmpty {
            delete(account: account)
            return
        }
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]
        let update = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if update == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            let status = SecItemAdd(add as CFDictionary, nil)
            guard status == errSecSuccess else {
                throw AlethiaError.database("Keychain write failed (\(status))")
            }
        } else if update != errSecSuccess {
            throw AlethiaError.database("Keychain update failed (\(update))")
        }
        #else
        memoryLock.lock(); defer { memoryLock.unlock() }
        if value.isEmpty { memory.removeValue(forKey: account) } else { memory[account] = value }
        #endif
    }

    public static func delete(account: String) {
        #if canImport(Security)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        #else
        memoryLock.lock(); defer { memoryLock.unlock() }
        memory.removeValue(forKey: account)
        #endif
    }

    #if canImport(Security)
    private static func copy(account: String, service: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    #endif
}
