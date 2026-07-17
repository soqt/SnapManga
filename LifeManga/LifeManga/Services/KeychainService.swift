//
//  KeychainService.swift
//  LifeManga
//
//  用 iOS Keychain 安全保存用户的 OpenAI API Key。
//

import Foundation
import Security

final class KeychainService {

    static let shared = KeychainService()
    private init() {}

    private let service = "com.lifemanga.app"
    private let account = "openai_api_key"

    // MARK: - Save

    @discardableResult
    func saveAPIKey(_ key: String) -> Bool {
        guard let data = key.data(using: .utf8) else { return false }

        // 先删旧的
        let queryDelete: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(queryDelete as CFDictionary)

        let attributes: [String: Any] = [
            kSecClass as String:        kSecClassGenericPassword,
            kSecAttrService as String:  service,
            kSecAttrAccount as String:  account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData as String:    data
        ]

        let status = SecItemAdd(attributes as CFDictionary, nil)
        return status == errSecSuccess
    }

    // MARK: - Load

    func loadAPIKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String:        kSecClassGenericPassword,
            kSecAttrService as String:  service,
            kSecAttrAccount as String:  account,
            kSecReturnData as String:   true,
            kSecMatchLimit as String:   kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8) else {
            return nil
        }
        return key
    }

    // MARK: - Delete

    @discardableResult
    func deleteAPIKey() -> Bool {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
