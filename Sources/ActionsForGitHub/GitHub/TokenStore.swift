//
//  TokenStore.swift
//  ActionsForGitHub
//
//  Copyright (C) 2026 René Jiménez
//  SPDX-License-Identifier: AGPL-3.0-or-later
//  Linking exception for DroppyKit: see LICENSE-EXCEPTION
//
//  Where the GitHub token lives.
//
//  Not in `host.preferences`: that service is the right home for a repository
//  list and a poll interval, and the wrong one for a credential, because it
//  writes into Droppy's preferences domain as plain text that anything reading
//  the user's home directory can lift. A personal access token with the
//  Actions scope reads every private repository the user can, so it goes in
//  the keychain.
//
//  A droplet runs inside Droppy's process, so the item belongs to Droppy's
//  code signature and no prompt is raised for it. The service string is
//  namespaced to this droplet the same way preference keys are, so a second
//  droplet cannot read it by guessing the account name.
//

import Foundation
import Security

/// Reads and writes this droplet's GitHub token in the login keychain.
public enum TokenStore {
    /// Keychain service, namespaced to the droplet.
    private static let service = "app.getdroppy.droplet.actions-for-github"
    /// Keychain account. One token per droplet, so the name is a constant.
    private static let account = "github-token"

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    /// The stored token, or `nil` when none has been saved.
    public static func read() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Saves a token, replacing any existing one. Passing `nil` or blank
    /// clears it, which is what the settings pane's empty field means.
    ///
    /// - Returns: `true` when the keychain accepted the write.
    @discardableResult
    public static func write(_ token: String?) -> Bool {
        let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return clear() }
        guard let data = trimmed.data(using: .utf8) else { return false }

        // Update first: SecItemAdd on an existing item fails with
        // errSecDuplicateItem, and the update path is the common one.
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else { return false }

        var insert = baseQuery
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        // The item is only ever read while Droppy runs, so it has no business
        // syncing to the user's other Macs.
        insert[kSecAttrSynchronizable as String] = false
        return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
    }

    /// Removes the stored token. Succeeds when there was nothing to remove.
    @discardableResult
    public static func clear() -> Bool {
        let status = SecItemDelete(baseQuery as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// Whether a token is stored, without copying it out.
    public static func exists() -> Bool {
        var query = baseQuery
        query[kSecReturnData as String] = false
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    /// A token shortened for display: the prefix GitHub uses to name the token
    /// type, then the last four characters. Never the middle.
    public static func redacted(_ token: String) -> String {
        guard token.count > 12 else { return String(repeating: "•", count: max(token.count, 8)) }
        let prefix = token.prefix(while: { $0 != "_" })
        let head = prefix.count < token.count ? "\(prefix)_" : ""
        return "\(head)••••\(token.suffix(4))"
    }
}
