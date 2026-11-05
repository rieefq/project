import CryptoKit
import Foundation
import Observation
import Security
import AsideKit

/// Minimal Keychain wrapper for small secrets (encryption key, API credentials, tokens).
enum Keychain {
    private static let service = "app.aside.secrets"

    private static func baseQuery(_ account: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        #if os(macOS)
        query[kSecUseDataProtectionKeychain as String] = true
        #endif
        return query
    }

    static func data(_ account: String) -> Data? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    static func string(_ account: String) -> String? {
        data(account).flatMap { String(data: $0, encoding: .utf8) }
    }

    @discardableResult
    static func set(_ data: Data, for account: String) -> Bool {
        let query = baseQuery(account)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert.merge(attributes) { $1 }
            return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }

    @discardableResult
    static func set(_ string: String, for account: String) -> Bool {
        set(Data(string.utf8), for: account)
    }

    static func remove(_ account: String) {
        SecItemDelete(baseQuery(account) as CFDictionary)
    }
}

/// Encrypted on-disk storage for Aside's data. Every file is sealed with AES-GCM using a
/// device-only key held in the Keychain, so copied files are unreadable elsewhere.
actor EncryptedFileStore: PersistentStore {
    private let directory: URL
    private let keyAccount = "storage.key.v1"
    private var cachedKey: SymmetricKey?

    init(folder: String = "Aside") {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        directory = base.appendingPathComponent(folder, isDirectory: true).appendingPathComponent("Store", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var url = directory
        try? url.setResourceValues(values)
    }

    private func key() -> SymmetricKey {
        if let cachedKey { return cachedKey }
        if let data = Keychain.data(keyAccount), data.count == 32 {
            let key = SymmetricKey(data: data)
            cachedKey = key
            return key
        }
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        Keychain.set(data, for: keyAccount)
        cachedKey = key
        return key
    }

    private func url(_ name: String) -> URL {
        let safe = name.replacingOccurrences(of: "/", with: "_")
        return directory.appendingPathComponent(safe).appendingPathExtension("sealed")
    }

    func load(_ key: String) async throws -> Data? {
        let file = url(key)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let sealed = try Data(contentsOf: file)
        let box = try AES.GCM.SealedBox(combined: sealed)
        return try AES.GCM.open(box, using: self.key())
    }

    func save(_ data: Data, for key: String) async throws {
        let box = try AES.GCM.seal(data, using: self.key())
        guard let combined = box.combined else { return }
        #if os(iOS)
        try combined.write(to: url(key), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try combined.write(to: url(key), options: [.atomic])
        #endif
    }

    func remove(_ key: String) async throws {
        try? FileManager.default.removeItem(at: url(key))
    }

    /// Deletes every stored file and the encryption key.
    func eraseAll() {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        Keychain.remove(keyAccount)
        cachedKey = nil
    }
}

/// Cloud credentials, kept only in the Keychain.
@MainActor
@Observable
final class CredentialStore {
    private let apiKeyAccount = "claude.apiKey"
    private let relayURLKey = "claude.relayURL"
    private let relayTokenAccount = "claude.relayToken"

    private(set) var hasCredential: Bool = false

    init() {
        hasCredential = credential() != nil
    }

    var relayURL: URL? {
        UserDefaults.standard.string(forKey: relayURLKey).flatMap(URL.init(string:))
    }

    func credential() -> ClaudeConfiguration.Credential? {
        if relayURL != nil, let token = Keychain.string(relayTokenAccount), !token.isEmpty { return .bearer(token) }
        if let key = Keychain.string(apiKeyAccount), !key.isEmpty { return .apiKey(key) }
        return nil
    }

    func setAPIKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { Keychain.remove(apiKeyAccount) } else { Keychain.set(trimmed, for: apiKeyAccount) }
        hasCredential = credential() != nil
    }

    func setRelay(url: String, token: String) {
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedURL.isEmpty {
            UserDefaults.standard.removeObject(forKey: relayURLKey)
            Keychain.remove(relayTokenAccount)
        } else {
            UserDefaults.standard.set(trimmedURL, forKey: relayURLKey)
            Keychain.set(token.trimmingCharacters(in: .whitespacesAndNewlines), for: relayTokenAccount)
        }
        hasCredential = credential() != nil
    }

    func removeAll() {
        Keychain.remove(apiKeyAccount)
        Keychain.remove(relayTokenAccount)
        UserDefaults.standard.removeObject(forKey: relayURLKey)
        hasCredential = false
    }

    /// A short masked form for display ("sk-ant-…3f9c").
    var maskedKey: String? {
        guard let key = Keychain.string(apiKeyAccount), key.count > 8 else { return nil }
        return String(key.prefix(7)) + "…" + String(key.suffix(4))
    }
}
