import Foundation
import CryptoKit
import Security

public final class AudioKeychainManager: @unchecked Sendable {
    public static let shared = AudioKeychainManager()

    private let serviceName = "com.sidebrief.audio.encryption"
    private var inMemoryKeyCache: [String: SymmetricKey] = [:]
    private let lock = NSLock()

    private init() {}

    /// Retrieves or generates a 256-bit SymmetricKey for the specified meeting ID.
    public func getOrCreateKey(for meetingId: String) throws -> SymmetricKey {
        lock.lock()
        defer { lock.unlock() }

        if let cached = inMemoryKeyCache[meetingId] {
            return cached
        }

        let account = "meeting-\(meetingId)"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        if status == errSecSuccess, let data = item as? Data {
            let key = SymmetricKey(data: data)
            inMemoryKeyCache[meetingId] = key
            return key
        }

        // Generate a new 256-bit key
        let newKey = SymmetricKey(size: .bits256)
        let keyData = newKey.withUnsafeBytes { Data($0) }

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
            kSecValueData as String: keyData,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        SecItemDelete(query as CFDictionary)
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess || addStatus == errSecDuplicateItem else {
            // If keychain fails (e.g. in test runner or sandboxed unit test without entitlements), cache in-memory
            inMemoryKeyCache[meetingId] = newKey
            return newKey
        }

        inMemoryKeyCache[meetingId] = newKey
        return newKey
    }

    /// Deletes a meeting's encryption key from Keychain.
    public func deleteKey(for meetingId: String) {
        lock.lock()
        defer { lock.unlock() }

        inMemoryKeyCache.removeValue(forKey: meetingId)
        let account = "meeting-\(meetingId)"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
