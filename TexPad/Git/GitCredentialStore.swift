// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 TexPad contributors

import Foundation
import Security

struct GitCredential: Codable, Equatable {
    var username: String
    var token: String
}

/// Personal access tokens, one per host, in the iOS Keychain (this device only, available after first unlock).
/// Tokens are never written to disk elsewhere, never put in URLs or `.git/config`, and never logged.
enum GitCredentialStore {
    static let service = "dev.texpad.git"

    static func normalizedHost(_ host: String) -> String { host.lowercased() }

    private static func query(_ host: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: normalizedHost(host)]
    }

    @discardableResult
    static func save(_ c: GitCredential, host: String) -> Bool {
        guard let data = try? JSONEncoder().encode(c) else { return false }
        SecItemDelete(query(host) as CFDictionary)
        var q = query(host)
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }

    static func load(host: String) -> GitCredential? {
        var q = query(host)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return try? JSONDecoder().decode(GitCredential.self, from: d)
    }

    static func delete(host: String) { SecItemDelete(query(host) as CFDictionary) }

    /// Hosts that have a saved token (the tokens themselves are not returned).
    static func hosts() -> [String] {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitAll]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let items = out as? [[String: Any]] else { return [] }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }.sorted()
    }
}
