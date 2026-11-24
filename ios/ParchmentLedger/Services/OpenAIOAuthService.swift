// MARK: - ChatGPT OAuth PKCE Sign-In
//
// Implements OAuth 2.0 + PKCE against OpenAI's auth endpoints via `ASWebAuthenticationSession`
// using the `veldafitness://oauth/openai` callback scheme, persisting tokens in `KeychainStore`.

import AuthenticationServices
import CryptoKit
import Foundation
import UIKit

enum OpenAIOAuthError: LocalizedError {
    case invalidAuthURL
    case missingCallbackCode
    case stateMismatch
    case tokenExchangeFailed(String)
    case notSignedIn

    var errorDescription: String? {
        switch self {
        case .invalidAuthURL:
            return "Could not construct OpenAI Sign-In URL."
        case .missingCallbackCode:
            return "OpenAI Sign-In did not return an authorization code."
        case .stateMismatch:
            return "OAuth state verification failed. Please try signing in again."
        case .tokenExchangeFailed(let msg):
            return msg
        case .notSignedIn:
            return "Not signed in with ChatGPT. Tap Sign in with ChatGPT in Vault."
        }
    }
}

@MainActor
final class OpenAIOAuthService: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = OpenAIOAuthService()

    private let authorizeEndpoint = "https://auth.openai.com/api/accounts/authorize"
    private let tokenEndpoint = URL(string: "https://auth.openai.com/api/accounts/oauth/token")!
    private let callbackScheme = "veldafitness"
    private let redirectURI = "veldafitness://oauth/openai"
    private let scopes = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"

    private let keychain = KeychainStore.shared
    private var activeSession: ASWebAuthenticationSession?

    private override init() {
        super.init()
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
                .first { $0.isKeyWindow } ?? ASPresentationAnchor()
        }
    }

    func signInWithChatGPT() async throws -> String {
        let verifier = randomURLSafeString(byteCount: 32)
        let challenge = sha256Base64URL(verifier)
        let state = randomURLSafeString(byteCount: 16)

        let existingClientId = keychain.get(forKey: "ai.openai.oauth.client_id")
        let hostId = persistentHostId()

        var comps = URLComponents(string: authorizeEndpoint)
        var items: [URLQueryItem] = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "resource", value: "https://api.openai.com/v1"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        if let cid = existingClientId, !cid.isEmpty {
            items.append(URLQueryItem(name: "client_id", value: cid))
        } else {
            items.append(URLQueryItem(name: "client_id", value: "dynamic_agent_client"))
            items.append(URLQueryItem(name: "agent_name_hint", value: "VeldaFitness"))
            items.append(URLQueryItem(name: "ext_agent_host_id", value: hostId))
        }
        comps?.queryItems = items

        guard let authURL = comps?.url else {
            throw OpenAIOAuthError.invalidAuthURL
        }

        let callbackURL: URL = try await withCheckedThrowingContinuation { cont in
            let session = ASWebAuthenticationSession(
                url: authURL,
                callbackURLScheme: callbackScheme
            ) { url, error in
                if let error {
                    cont.resume(throwing: error)
                    return
                }
                guard let url else {
                    cont.resume(throwing: OpenAIOAuthError.missingCallbackCode)
                    return
                }
                cont.resume(returning: url)
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.activeSession = session
            session.start()
        }
        activeSession = nil

        let cbComps = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)
        let queryMap = Dictionary(
            uniqueKeysWithValues: (cbComps?.queryItems ?? []).compactMap { item -> (String, String)? in
                guard let v = item.value else { return nil }
                return (item.name, v)
            }
        )

        if let errDesc = queryMap["error_description"] ?? queryMap["error"] {
            throw OpenAIOAuthError.tokenExchangeFailed("OpenAI Sign-In declined: \(errDesc)")
        }
        guard queryMap["state"] == state else {
            throw OpenAIOAuthError.stateMismatch
        }
        guard let code = queryMap["code"], !code.isEmpty else {
            throw OpenAIOAuthError.missingCallbackCode
        }

        let resolvedClientId = queryMap["client_id"] ?? existingClientId ?? "dynamic_agent_client"
        if !resolvedClientId.isEmpty && resolvedClientId != "dynamic_agent_client" {
            keychain.set(resolvedClientId, forKey: "ai.openai.oauth.client_id")
        }

        return try await exchangeCode(code: code, verifier: verifier, clientId: resolvedClientId)
    }

    func validAccessToken() async throws -> String {
        guard let access = keychain.get(forKey: "ai.openai.oauth.access_token"), !access.isEmpty else {
            throw OpenAIOAuthError.notSignedIn
        }
        if let expStr = keychain.get(forKey: "ai.openai.oauth.expires_at"),
           let expTs = Double(expStr),
           Date().timeIntervalSince1970 > (expTs - 90),
           let refresh = keychain.get(forKey: "ai.openai.oauth.refresh_token"),
           !refresh.isEmpty,
           let clientId = keychain.get(forKey: "ai.openai.oauth.client_id"),
           !clientId.isEmpty {
            return try await refreshToken(refreshToken: refresh, clientId: clientId)
        }
        return access
    }

    func signOut() {
        keychain.delete(forKey: "ai.openai.oauth.access_token")
        keychain.delete(forKey: "ai.openai.oauth.refresh_token")
        keychain.delete(forKey: "ai.openai.oauth.expires_at")
        keychain.delete(forKey: "ai.openai.oauth.email")
        keychain.clearVerification(for: .openai, mode: .signIn)
    }

    private func exchangeCode(code: String, verifier: String, clientId: String) async throws -> String {
        let params: [String: String] = [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "client_id": clientId,
            "code_verifier": verifier,
        ]
        return try await performTokenRequest(params: params)
    }

    private func refreshToken(refreshToken: String, clientId: String) async throws -> String {
        let params: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientId,
        ]
        return try await performTokenRequest(params: params)
    }

    private func performTokenRequest(params: [String: String]) async throws -> String {
        var req = URLRequest(url: tokenEndpoint)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var comps = URLComponents()
        comps.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        req.httpBody = comps.percentEncodedQuery?.data(using: .utf8)

        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode >= 400 {
            let msg = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw OpenAIOAuthError.tokenExchangeFailed("OpenAI token error (\(http.statusCode)): \(String(msg.prefix(200)))")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String,
              !accessToken.isEmpty else {
            throw OpenAIOAuthError.tokenExchangeFailed("OpenAI token response did not contain an access token.")
        }

        keychain.set(accessToken, forKey: "ai.openai.oauth.access_token")
        if let rt = json["refresh_token"] as? String, !rt.isEmpty {
            keychain.set(rt, forKey: "ai.openai.oauth.refresh_token")
        }
        if let exp = json["expires_in"] as? Double {
            keychain.set(String(Date().timeIntervalSince1970 + exp), forKey: "ai.openai.oauth.expires_at")
        }
        let email = extractEmailFromJWT(json["id_token"] as? String) ?? "ChatGPT Account"
        keychain.set(email, forKey: "ai.openai.oauth.email")
        return email
    }

    private func persistentHostId() -> String {
        if let existing = keychain.get(forKey: "ai.openai.oauth.host_id"), !existing.isEmpty {
            return existing
        }
        let fresh = "velda-\(UUID().uuidString.lowercased())"
        keychain.set(fresh, forKey: "ai.openai.oauth.host_id")
        return fresh
    }

    private func extractEmailFromJWT(_ jwt: String?) -> String? {
        guard let jwt else { return nil }
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return (obj["email"] as? String) ?? (obj["name"] as? String)
    }

    private func randomURLSafeString(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func sha256Base64URL(_ input: String) -> String {
        let digest = SHA256.hash(data: Data(input.utf8))
        return Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
