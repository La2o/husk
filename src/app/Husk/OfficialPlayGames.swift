// SPDX-License-Identifier: GPL-2.0-or-later
import AuthenticationServices
import CryptoKit
import Darwin
import Foundation
import Security
import SwiftUI
import UIKit

/// Google Play Games *identity*, not Play Store downloads and not an iCloud
/// backup. Never report a signed-in player until Google's applications.verify
/// endpoint has confirmed that the token belongs to the configured game.
///
/// Requires an iOS OAuth client belonging to and approved for the *game's own*
/// Google Cloud / Play Games project. No arbitrary client ID or generic Google
/// account OAuth token can be substituted for ITRTG's game-scoped identity.
///
/// The publisher-associated client ID and Play Games application ID are
/// injected into Info.plist at packaging time by an authorized build.
private enum PGSOAuthConfig {
    static let clientID = Bundle.main.object(forInfoDictionaryKey: "HuskPGSOAuthClientID") as? String ?? ""
    static let appID = Bundle.main.object(forInfoDictionaryKey: "HuskPGSApplicationID") as? String ?? ""
    static var callbackScheme: String {
        let suffix = ".apps.googleusercontent.com"
        guard clientID.hasSuffix(suffix) else { return "" }
        return "com.googleusercontent.apps." + String(clientID.dropLast(suffix.count))
    }
    static var available: Bool {
        clientID.hasSuffix(".apps.googleusercontent.com") && !callbackScheme.isEmpty &&
        !appID.isEmpty && appID.allSatisfy({ $0.isNumber })
    }
    static var redirectURI: String { callbackScheme + ":/oauth2redirect" }
}

private struct PGSVerifiedCredential: Codable {
    let clientID: String
    let appID: String
    let playerID: String
    let accessToken: String
    let expiresAt: Date
}

/// Native runtime threads query only the verified, unexpired game-scoped ID.
/// Credentials stay in Keychain; no tokens appear in logs or in JNI fields.
private final class PGSVerifiedStore {
    static let shared = PGSVerifiedStore()
    private let lock = NSLock()
    private let service = "com.husk.app.pgs.game-scope"
    private let account = "de.shugasu.itrtg"
    private var credential: PGSVerifiedCredential?

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    private init() {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        if SecItemCopyMatching(q as CFDictionary, &value) == errSecSuccess,
           let data = value as? Data {
            credential = try? JSONDecoder().decode(PGSVerifiedCredential.self, from: data)
        }
    }

    func copyVerifiedPlayerID() -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let value = credential,
              PGSOAuthConfig.available,
              value.clientID == PGSOAuthConfig.clientID,
              value.appID == PGSOAuthConfig.appID,
              value.expiresAt.timeIntervalSinceNow > 30,
              !value.playerID.isEmpty else { return nil }
        return value.playerID
    }

    func save(_ value: PGSVerifiedCredential) throws {
        let data = try JSONEncoder().encode(value)
        lock.lock()
        defer { lock.unlock() }
        SecItemDelete(query as CFDictionary)
        var attrs = query
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let rc = SecItemAdd(attrs as CFDictionary, nil)
        guard rc == errSecSuccess else {
            credential = nil
            throw PGSError("Could not save the verified Google session in iOS Keychain (\(rc)).")
        }
        credential = value
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        credential = nil
        SecItemDelete(query as CFDictionary)
    }
}

/// JNI reads this from Unity's native threads. The string is strdup'd and the
/// translation-layer C caller must free it. NULL means "not authenticated".
@_cdecl("husk_pgs_copy_verified_player_id")
func husk_pgs_copy_verified_player_id() -> UnsafeMutablePointer<CChar>? {
    guard let player = PGSVerifiedStore.shared.copyVerifiedPlayerID() else { return nil }
    return strdup(player)
}

private struct PGSError: LocalizedError {
    let text: String
    init(_ text: String) { self.text = text }
    var errorDescription: String? { text }
}

private final class PGSAuthAnchor: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        for scene in UIApplication.shared.connectedScenes {
            if let window = (scene as? UIWindowScene)?.windows.first(where: { $0.isKeyWindow }) {
                return window
            }
        }
        return ASPresentationAnchor()
    }
}

@MainActor final class OfficialPlayGames: ObservableObject {
    static let shared = OfficialPlayGames()
    @Published private(set) var busy = false
    @Published private(set) var message = "Not signed in to Play Games"
    @Published private(set) var playerID: String?
    var isConfigured: Bool { PGSOAuthConfig.available }
    private var authSession: ASWebAuthenticationSession?
    private let anchor = PGSAuthAnchor()

    private init() { playerID = PGSVerifiedStore.shared.copyVerifiedPlayerID() }

    func signOut() {
        PGSVerifiedStore.shared.clear()
        playerID = nil
        message = "Signed out. Local and online saves were not modified."
    }

    func signIn() async {
        guard isConfigured else {
            message = "ITRTG publisher-authorized Play Games OAuth credentials are required. This test build is not configured."
            return
        }
        guard !busy else { return }
        busy = true
        defer { busy = false }
        message = "Opening Google's authorization screen…"
        do {
            // PKCE prevents a stolen redirect code from being exchanged.
            let verifier = Self.randomVerifier()
            let digest = SHA256.hash(data: Data(verifier.utf8))
            let challenge = Data(digest).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
            let state = UUID().uuidString
            var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
            components.queryItems = [
                .init(name: "client_id", value: PGSOAuthConfig.clientID),
                .init(name: "redirect_uri", value: PGSOAuthConfig.redirectURI),
                .init(name: "response_type", value: "code"),
                .init(name: "scope", value: "https://www.googleapis.com/auth/games_lite"),
                .init(name: "code_challenge", value: challenge),
                .init(name: "code_challenge_method", value: "S256"),
                .init(name: "state", value: state),
                .init(name: "access_type", value: "offline")
            ]
            guard let authURL = components.url else { throw PGSError("Invalid Google authorization URL.") }
            let callback = try await openGoogleLogin(authURL)
            guard callback.scheme == PGSOAuthConfig.callbackScheme,
                  let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems,
                  items.first(where: { $0.name == "state" })?.value == state,
                  let code = items.first(where: { $0.name == "code" })?.value,
                  !code.isEmpty else { throw PGSError("Google login returned an invalid or unexpected response.") }

            message = "Checking your real ITRTG Play Games identity…"
            let token = try await exchangeCode(code, verifier: verifier)
            let player = try await verifyITRTGToken(token.accessToken)
            guard token.expiresIn > 60 else { throw PGSError("Google returned an expired token.") }
            let verified = PGSVerifiedCredential(clientID: PGSOAuthConfig.clientID,
                  appID: PGSOAuthConfig.appID, playerID: player,
                  accessToken: token.accessToken,
                  expiresAt: Date().addingTimeInterval(TimeInterval(token.expiresIn)))
            try PGSVerifiedStore.shared.save(verified)
            playerID = player
            message = "Google verified this account for ITRTG. Restart the game to use Play Games."
            HuskLog.log("pgs", "Google verified a game-scoped ITRTG player identity (ID and token redacted).")
        } catch {
            message = error.localizedDescription
            HuskLog.log("pgs", "Official Play Games authentication did not complete: \(error.localizedDescription)")
        }
    }

    private static func randomVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 48)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            return UUID().uuidString.replacingOccurrences(of: "-", with: "") + UUID().uuidString
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func openGoogleLogin(_ url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: PGSOAuthConfig.callbackScheme) { [weak self] returned, error in
                Task { @MainActor in self?.authSession = nil }
                if let error { continuation.resume(throwing: error) }
                else if let returned { continuation.resume(returning: returned) }
                else { continuation.resume(throwing: PGSError("Google login did not return a callback.")) }
            }
            authSession = session
            session.presentationContextProvider = anchor
            session.prefersEphemeralWebBrowserSession = false
            if !session.start() {
                authSession = nil
                continuation.resume(throwing: PGSError("Could not open Google's sign-in screen."))
            }
        }
    }

    private struct OAuthToken: Decodable {
        let accessToken: String
        let expiresIn: Int
        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token", expiresIn = "expires_in"
        }
    }

    private func exchangeCode(_ code: String, verifier: String) async throws -> OAuthToken {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let pairs = [
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "client_id", value: PGSOAuthConfig.clientID),
            URLQueryItem(name: "code_verifier", value: verifier),
            URLQueryItem(name: "redirect_uri", value: PGSOAuthConfig.redirectURI),
            URLQueryItem(name: "grant_type", value: "authorization_code")
        ]
        var query = URLComponents()
        query.queryItems = pairs
        request.httpBody = query.percentEncodedQuery?.data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw PGSError("Google rejected the OAuth exchange. Verify the iOS client belongs to the ITRTG publisher project.")
        }
        return try JSONDecoder().decode(OAuthToken.self, from: data)
    }

    private func verifyITRTGToken(_ token: String) async throws -> String {
        // This endpoint specifically validates the token AGAINST the ITRTG
        // application ID. A valid Google email or unrelated game token fails.
        let url = URL(string: "https://games.googleapis.com/games/v1/applications/\(PGSOAuthConfig.appID)/verify")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw PGSError("Google did not verify this token for ITRTG's Play Games application. Your publisher-linked OAuth client may not be authorized.")
        }
        struct Verification: Decodable {
            let playerID: String
            enum CodingKeys: String, CodingKey { case playerID = "player_id" }
        }
        let verified = try JSONDecoder().decode(Verification.self, from: data)
        guard !verified.playerID.isEmpty else { throw PGSError("Google returned no ITRTG player ID.") }
        return verified.playerID
    }
}
