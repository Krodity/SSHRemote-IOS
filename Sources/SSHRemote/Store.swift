import Foundation
import Security
import Crypto
import NIOSSH

/// Hosts as JSON in Application Support; secrets in the Keychain.
enum Store {
    private static var file: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("hosts.json")
    }

    static func loadHosts() -> [Host] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        return (try? JSONDecoder().decode([Host].self, from: data)) ?? []
    }

    static func saveHosts(_ hosts: [Host]) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(hosts) {
            try? data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    // ── passwords, one per host ──────────────────────────────────────────────
    static func password(for hostId: String) -> String? {
        keychainRead("password.\(hostId)").map { String(decoding: $0, as: UTF8.self) }
    }

    static func setPassword(_ pw: String?, for hostId: String) {
        keychainWrite("password.\(hostId)", pw.flatMap { $0.isEmpty ? nil : Data($0.utf8) })
    }

    // ── this device's identity ───────────────────────────────────────────────
    /// The app's Ed25519 key, created on first use and never leaving the
    /// Keychain (this-device-only, so it is not synced or backed up).
    static func identity() -> Curve25519.Signing.PrivateKey {
        if let raw = keychainRead("identity.ed25519"),
           let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) {
            return key
        }
        let key = Curve25519.Signing.PrivateKey()
        keychainWrite("identity.ed25519", key.rawRepresentation)
        return key
    }

    static var identityKey: NIOSSHPrivateKey { NIOSSHPrivateKey(ed25519Key: identity()) }

    static var publicKeyLine: String {
        Keys.openSSH(identityKey.publicKey, comment: "ssh-remote-ios")
    }

    // ── Keychain ─────────────────────────────────────────────────────────────
    /// Follows the bundle ID, so each build keeps its own secrets.
    private static let service = Bundle.main.bundleIdentifier ?? "sshremote"

    private static func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: key]
    }

    private static func keychainRead(_ key: String) -> Data? {
        var q = query(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    private static func keychainWrite(_ key: String, _ value: Data?) {
        SecItemDelete(query(key) as CFDictionary)
        guard let value else { return }
        var q = query(key)
        q[kSecValueData as String] = value
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }
}
