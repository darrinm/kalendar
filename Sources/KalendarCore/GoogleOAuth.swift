// Google OAuth 2.0 for a native app: authorization code flow with PKCE, no client secret.
//
// The client is registered in Google Cloud project kalendar-511416 as an "iOS" client for bundle ID
// com.massena.kalendar (Google uses that client type for native macOS apps). Its redirect URI uses
// the reversed client ID as a custom URL scheme, which ASWebAuthenticationSession intercepts.
// This file builds the requests and parses the responses; it does no I/O, so it is unit-tested.
import CryptoKit
import Foundation
import Security

public enum GoogleOAuth {
    public static let clientID = "592663087020-a63og6tg0r67prkfcp9oa9l5s4qs2l96.apps.googleusercontent.com"
    public static let redirectScheme = "com.googleusercontent.apps.592663087020-a63og6tg0r67prkfcp9oa9l5s4qs2l96"
    public static var redirectURI: String { "\(redirectScheme):/oauth2redirect" }

    static let authEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!
    static let revokeEndpoint = URL(string: "https://oauth2.googleapis.com/revoke")!

    /// Kalendar cannot work without these. Google's consent screen lets the user untick individual
    /// scopes, so a successful sign-in can still lack one; that is reported as `missingScopes`.
    public static let requiredScopes = [
        "https://www.googleapis.com/auth/calendar",
        "https://www.googleapis.com/auth/tasks",
    ]
    /// Invitee suggestions (§18.4). Without them, suggestions fall back to cached attendees.
    public static let optionalScopes = [
        "https://www.googleapis.com/auth/contacts.readonly",
        "https://www.googleapis.com/auth/contacts.other.readonly",
        "https://www.googleapis.com/auth/directory.readonly",
    ]
    /// The full URL form of the email scope, because that is the form Google echoes back in `scope`.
    static let identityScopes = ["openid", "https://www.googleapis.com/auth/userinfo.email"]
    public static var allScopes: [String] { identityScopes + requiredScopes + optionalScopes }

    public enum Error: Swift.Error, Equatable {
        /// The user cancelled or declined on Google's consent screen.
        case accessDenied
        /// The callback's `state` does not match the request's.
        case stateMismatch
        /// The refresh token was revoked or expired. The account must sign in again.
        case invalidGrant
        /// Signed in, but without scopes Kalendar needs.
        case missingScopes([String])
        /// The token response has no id_token email.
        case noEmail
        /// Any other error response, with Google's `error` code or the HTTP status.
        case server(String)
        case malformedResponse
    }

    static let scopeNames = [
        "https://www.googleapis.com/auth/calendar": "Google Calendar",
        "https://www.googleapis.com/auth/tasks": "Google Tasks",
    ]

    // MARK: PKCE (RFC 7636)

    public struct PKCE: Equatable {
        public let verifier: String
        public var challenge: String { Self.challenge(for: verifier) }

        public init(verifier: String) { self.verifier = verifier }

        /// 32 random bytes, base64url: a 43-character verifier, the minimum RFC 7636 allows.
        public static func generate() -> PKCE {
            var bytes = [UInt8](repeating: 0, count: 32)
            _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            return PKCE(verifier: Data(bytes).base64URLEncoded)
        }

        public static func challenge(for verifier: String) -> String {
            Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded
        }
    }

    public static func randomState() -> String { PKCE.generate().verifier }

    // MARK: Requests

    /// `loginHint` preselects an account, used for "Sign in again to <email>".
    public static func authorizationURL(pkce: PKCE, state: String, loginHint: String? = nil) -> URL {
        var c = URLComponents(url: authEndpoint, resolvingAgainstBaseURL: false)!
        c.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: allScopes.joined(separator: " ")),
            .init(name: "code_challenge", value: pkce.challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
            // select_account lets "Add Account…" pick a second account instead of reusing the
            // browser's signed-in one; consent guarantees a refresh token in the response.
            .init(name: "prompt", value: "select_account consent"),
        ]
        if let loginHint { c.queryItems?.append(.init(name: "login_hint", value: loginHint)) }
        return c.url!
    }

    /// Returns the authorization code from the redirect URL.
    public static func code(fromCallback url: URL, expectedState: String) throws -> String {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        if let error = value("error") { throw error == "access_denied" ? Error.accessDenied : Error.server(error) }
        guard value("state") == expectedState else { throw Error.stateMismatch }
        guard let code = value("code"), !code.isEmpty else { throw Error.malformedResponse }
        return code
    }

    public static func tokenRequest(code: String, pkce: PKCE) -> URLRequest {
        form(tokenEndpoint, [
            "code": code,
            "client_id": clientID,
            "redirect_uri": redirectURI,
            "grant_type": "authorization_code",
            "code_verifier": pkce.verifier,
        ])
    }

    public static func refreshRequest(refreshToken: String) -> URLRequest {
        form(tokenEndpoint, [
            "refresh_token": refreshToken,
            "client_id": clientID,
            "grant_type": "refresh_token",
        ])
    }

    public static func revokeRequest(token: String) -> URLRequest {
        form(revokeEndpoint, ["token": token])
    }

    static func form(_ url: URL, _ fields: [String: String]) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        request.httpBody = fields.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed)!)" }
            .joined(separator: "&")
            .data(using: .utf8)
        return request
    }

    // MARK: Responses

    public struct TokenResponse: Equatable {
        public var accessToken: String
        public var expiresIn: TimeInterval
        /// Present on the code exchange, absent on a refresh.
        public var refreshToken: String?
        public var idToken: String?
        public var grantedScopes: Set<String>
    }

    private struct TokenJSON: Decodable {
        var access_token: String
        var expires_in: TimeInterval
        var refresh_token: String?
        var id_token: String?
        var scope: String?
    }

    private struct ErrorJSON: Decodable { var error: String }

    public static func parseTokenResponse(data: Data, status: Int) throws -> TokenResponse {
        guard (200..<300).contains(status) else {
            let code = (try? JSONDecoder().decode(ErrorJSON.self, from: data))?.error
            if code == "invalid_grant" { throw Error.invalidGrant }
            throw Error.server(code ?? "HTTP \(status)")
        }
        guard let json = try? JSONDecoder().decode(TokenJSON.self, from: data) else {
            throw Error.malformedResponse
        }
        return TokenResponse(
            accessToken: json.access_token,
            expiresIn: json.expires_in,
            refreshToken: json.refresh_token,
            idToken: json.id_token,
            grantedScopes: Set((json.scope ?? "").split(separator: " ").map(String.init)))
    }

    /// Required scopes absent from `granted`, in `requiredScopes` order.
    public static func missingRequiredScopes(_ granted: Set<String>) -> [String] {
        requiredScopes.filter { !granted.contains($0) }
    }

    /// The `email` claim of an id_token. The token came straight from Google's token endpoint over
    /// TLS, so OpenID Connect allows using its claims without verifying the signature.
    public static func email(fromIDToken token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count == 3, let payload = Data(base64URLEncoded: String(parts[1])),
              let claims = try? JSONSerialization.jsonObject(with: payload) as? [String: Any]
        else { return nil }
        return claims["email"] as? String
    }
}

extension GoogleOAuth.Error: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .accessDenied: "Sign-in was cancelled."
        case .stateMismatch: "Sign-in failed because the response didn't match the request. Try again."
        case .invalidGrant: "Google no longer accepts this account's sign-in. Sign in again."
        case .missingScopes(let scopes):
            "Kalendar needs access to "
                + scopes.map { GoogleOAuth.scopeNames[$0] ?? $0 }.joined(separator: " and ")
                + ". Sign in again and leave those boxes checked."
        case .noEmail: "Google didn't return the account's email address."
        case .server(let code): "Google returned an error (\(code))."
        case .malformedResponse: "Google returned a response Kalendar couldn't read."
        }
    }
}

extension Data {
    var base64URLEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URLEncoded string: String) {
        var s = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        s += String(repeating: "=", count: (4 - s.count % 4) % 4)
        self.init(base64Encoded: s)
    }
}
