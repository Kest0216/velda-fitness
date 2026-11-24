// MARK: - Apple Keychain Credential Store
//
// Stores user-supplied AI API keys and ChatGPT OAuth tokens encrypted in Apple Keychain
// (`kSecAttrSynchronizable` first so credentials sync privately with the user's Apple ID, falling
// back to device-local keychain when iCloud Keychain entitlement is unavailable).

import Foundation
import Security

final class KeychainStore: @unchecked Sendable {
    static let shared = KeychainStore()

    private let service = "com.veldaapp.veldafitness.credentials"
    private let defaults = UserDefaults.standard

    private init() {}

    // MARK: - Generic iCloud Keychain Read/Write

    func set(_ value: String, forKey key: String) {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else {
            delete(forKey: key)
            return
        }
        guard let data = clean.data(using: .utf8) else { return }

        delete(forKey: key)

        // Try iCloud Keychain (synchronizable) first; fall back to device-local keychain if entitlement is absent.
        let syncQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecAttrSynchronizable as String: kCFBooleanTrue as Any,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData as String: data,
        ]
        let status = SecItemAdd(syncQuery as CFDictionary, nil)
        if status != errSecSuccess {
            let localQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: key,
                kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
                kSecValueData as String: data,
            ]
            SecItemAdd(localQuery as CFDictionary, nil)
        }
    }

    func get(forKey key: String) -> String? {
        if let synced = readItem(forKey: key, synchronizable: kCFBooleanTrue as Any) {
            return synced
        }
        return readItem(forKey: key, synchronizable: kCFBooleanFalse as Any)
    }

    func delete(forKey key: String) {
        for syncFlag in [kCFBooleanTrue as Any, kCFBooleanFalse as Any, kSecAttrSynchronizableAny] {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: key,
                kSecAttrSynchronizable as String: syncFlag,
            ]
            SecItemDelete(query as CFDictionary)
        }
    }

    private func readItem(forKey key: String, synchronizable: Any) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecAttrSynchronizable as String: synchronizable,
            kSecReturnData as String: kCFBooleanTrue as Any,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Provider Credential Helpers

    static func apiKeyIdentifier(for provider: AIProvider) -> String {
        "ai.\(provider.rawValue).api_key"
    }

    static func maskCredential(_ raw: String) -> String {
        let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return "" }
        if clean.count > 8 {
            return "\(clean.prefix(4))••••\(clean.suffix(4))"
        }
        return "••••"
    }

    func migrateLegacySQLiteKeyIfNeeded(db: DatabaseManager) {
        if let legacy = db.consumeLegacySQLiteGeminiKey(), !legacy.isEmpty {
            let keyId = Self.apiKeyIdentifier(for: .gemini)
            if (get(forKey: keyId) ?? "").isEmpty {
                set(legacy, forKey: keyId)
            }
        }
    }

    func activeDisplayKey(for providerRaw: String) -> String {
        let provider = AIProvider(rawValue: providerRaw) ?? .gemini
        let mode = authMode(for: provider)
        if provider == .openai && mode == .signIn {
            return get(forKey: "ai.openai.oauth.access_token") ?? ""
        }
        return get(forKey: Self.apiKeyIdentifier(for: provider)) ?? ""
    }

    func authMode(for provider: AIProvider) -> AIAuthMode {
        let key = "velda.ai.\(provider.rawValue).auth_mode"
        let raw = defaults.string(forKey: key) ?? AIAuthMode.apiKey.rawValue
        let parsed = AIAuthMode(rawValue: raw) ?? .apiKey
        if !provider.supportsSignInNow && parsed == .signIn {
            return .apiKey
        }
        return parsed
    }

    func setAuthMode(_ mode: AIAuthMode, for provider: AIProvider) {
        defaults.set(mode.rawValue, forKey: "velda.ai.\(provider.rawValue).auth_mode")
    }

    func saveVerifiedPing(_ result: AIPingResult) {
        let prefix = "velda.ai.\(result.provider.rawValue).\(result.authMode.rawValue)"
        defaults.set(result.success, forKey: "\(prefix).verified")
        defaults.set(result.latencyMs, forKey: "\(prefix).latency_ms")
        defaults.set(result.timestampISO, forKey: "\(prefix).verified_at")
    }

    func clearVerification(for provider: AIProvider, mode: AIAuthMode) {
        let prefix = "velda.ai.\(provider.rawValue).\(mode.rawValue)"
        defaults.removeObject(forKey: "\(prefix).verified")
        defaults.removeObject(forKey: "\(prefix).latency_ms")
        defaults.removeObject(forKey: "\(prefix).verified_at")
    }

    func configState(for provider: AIProvider) -> AIProviderConfigState {
        let mode = authMode(for: provider)
        let prefix = "velda.ai.\(provider.rawValue).\(mode.rawValue)"
        let verified = defaults.bool(forKey: "\(prefix).verified")
        let latencyObj = defaults.object(forKey: "\(prefix).latency_ms") as? Int
        let verifiedAt = defaults.string(forKey: "\(prefix).verified_at")

        if provider == .openai && mode == .signIn {
            let token = get(forKey: "ai.openai.oauth.access_token") ?? ""
            let email = get(forKey: "ai.openai.oauth.email") ?? ""
            return AIProviderConfigState(
                provider: provider,
                authMode: mode,
                hasCredential: !token.isEmpty,
                maskedCredential: token.isEmpty ? "" : (email.isEmpty ? "ChatGPT Session" : email),
                accountLabel: email,
                isVerified: !token.isEmpty && verified,
                lastPingLatencyMs: latencyObj,
                lastVerifiedAt: verifiedAt
            )
        }

        let rawKey = get(forKey: Self.apiKeyIdentifier(for: provider)) ?? ""
        return AIProviderConfigState(
            provider: provider,
            authMode: mode,
            hasCredential: !rawKey.isEmpty,
            maskedCredential: Self.maskCredential(rawKey),
            accountLabel: "",
            isVerified: !rawKey.isEmpty && verified,
            lastPingLatencyMs: latencyObj,
            lastVerifiedAt: verifiedAt
        )
    }

    func wipeAllAICredentials() {
        for p in AIProvider.allCases {
            delete(forKey: Self.apiKeyIdentifier(for: p))
            clearVerification(for: p, mode: .apiKey)
            clearVerification(for: p, mode: .signIn)
        }
        for k in [
            "ai.openai.oauth.access_token",
            "ai.openai.oauth.refresh_token",
            "ai.openai.oauth.expires_at",
            "ai.openai.oauth.email",
            "ai.openai.oauth.client_id",
            "ai.openai.oauth.host_id",
        ] {
            delete(forKey: k)
        }
    }
}
