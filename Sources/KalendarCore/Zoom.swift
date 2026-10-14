// Zoom (§5.1): Kalendar signs in to the user's Zoom account and creates a Zoom meeting for an event,
// as Google Calendar's Zoom add-on does. Zoom's public-client OAuth: authorization code with PKCE and
// no client secret, redirected to a loopback port Kalendar listens on while the browser signs in.
import Foundation

public enum ZoomOAuth {
    /// The public client ID of the "Kalendar" app on marketplace.zoom.us, registered in the Playful
    /// Software Zoom account (App Credentials, "Use Public Client OAuth").
    public static let clientID = "Sje6twrQRMusBBFYmWV9Q"

    /// Registered as the app's redirect URL. Kalendar listens on this port only during sign-in.
    public static let redirectPort: UInt16 = 47823
    public static var redirectURI: String { "http://127.0.0.1:\(redirectPort)/zoom" }

    static let authEndpoint = URL(string: "https://zoom.us/oauth/authorize")!
    static let tokenEndpoint = URL(string: "https://zoom.us/oauth/token")!

    public static func authorizationURL(pkce: GoogleOAuth.PKCE, state: String) -> URL {
        var c = URLComponents(url: authEndpoint, resolvingAgainstBaseURL: false)!
        c.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        return c.url!
    }

    /// A public client sends its client ID in the body and no Authorization header.
    public static func tokenRequest(code: String, pkce: GoogleOAuth.PKCE) -> URLRequest {
        GoogleOAuth.form(tokenEndpoint, [
            "grant_type": "authorization_code", "code": code, "redirect_uri": redirectURI,
            "code_verifier": pkce.verifier, "client_id": clientID,
        ])
    }

    public static func refreshRequest(refreshToken: String) -> URLRequest {
        GoogleOAuth.form(tokenEndpoint, ["grant_type": "refresh_token", "refresh_token": refreshToken, "client_id": clientID])
    }
}

public enum ZoomAPI {
    public struct Meeting: Equatable, Decodable {
        public var id: Int
        public var joinURL: String

        enum CodingKeys: String, CodingKey {
            case id
            case joinURL = "join_url"
        }
    }

    public enum Error: Swift.Error, Equatable, LocalizedError {
        case notConnected
        case http(Int, String?)
        /// Zoom's token endpoint refused a sign-in or refresh, with its error code.
        case signIn(String)

        public var errorDescription: String? {
            switch self {
            case .notConnected: "Kalendar isn't signed in to Zoom. Connect Zoom in Settings › Accounts."
            case .http(let status, let message): "Zoom couldn't create the meeting: \(message ?? "HTTP \(status)")."
            case .signIn(let code): "Zoom refused the sign-in (\(code))."
            }
        }
    }

    /// A scheduled meeting (type 2) in the signed-in user's account.
    public static func createMeetingRequest(topic: String, start: Date, minutes: Int, timeZone: String,
                                            accessToken: String) -> URLRequest {
        var r = URLRequest(url: URL(string: "https://api.zoom.us/v2/users/me/meetings")!)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let body: [String: Any] = [
            "topic": topic.isEmpty ? "Meeting" : topic, "type": 2, "start_time": GoogleCalendarAPI.iso(start),
            "duration": max(minutes, 1), "timezone": timeZone,
        ]
        r.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return r
    }

    public static func parseMeeting(data: Data, status: Int) throws -> Meeting {
        guard (200..<300).contains(status) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String
            throw Error.http(status, message)
        }
        do { return try JSONDecoder().decode(Meeting.self, from: data) } catch { throw Error.http(status, "unreadable response") }
    }
}

/// The user's Zoom sign-in: the refresh token in the Keychain, the access token in memory.
@MainActor
@Observable
public final class ZoomAccount {
    /// The vault key for Zoom's refresh token, beside the Google accounts' tokens.
    static let vaultKey = "zoom"

    public private(set) var isConnected: Bool
    @ObservationIgnored private let vault: TokenVault
    @ObservationIgnored private let transport: AccountStore.Transport
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var accessToken: (token: String, expiry: Date)?
    /// The refresh in flight. Zoom revokes a refresh token once it is used, so concurrent callers
    /// share one refresh instead of each spending the same token.
    @ObservationIgnored private var refreshing: Task<String, Swift.Error>?

    public init(vault: TokenVault = KeychainVault(),
                transport: @escaping AccountStore.Transport = { try await AccountStore.session.data(for: $0) },
                now: @escaping () -> Date = Date.init) {
        self.vault = vault
        self.transport = transport
        self.now = now
        isConnected = ((try? vault.refreshToken(for: Self.vaultKey)) ?? nil) != nil
    }

    public func completeSignIn(code: String, pkce: GoogleOAuth.PKCE) async throws {
        let response = try await token(ZoomOAuth.tokenRequest(code: code, pkce: pkce))
        guard response.refreshToken != nil else { throw GoogleOAuth.Error.malformedResponse }
        isConnected = true
    }

    public func disconnect() {
        vault.setRefreshToken(nil, for: Self.vaultKey)
        accessToken = nil
        isConnected = false
    }

    /// Creates a meeting for an event. Retries once with a fresh token when Zoom answers 401.
    public func createMeeting(topic: String, start: Date, minutes: Int, timeZone: String) async throws -> ZoomAPI.Meeting {
        var (data, status) = try await send(topic, start, minutes, timeZone, token: try await validToken())
        if status == 401 {
            accessToken = nil
            (data, status) = try await send(topic, start, minutes, timeZone, token: try await validToken())
        }
        return try ZoomAPI.parseMeeting(data: data, status: status)
    }

    private func send(_ topic: String, _ start: Date, _ minutes: Int, _ timeZone: String, token: String) async throws -> (Data, Int) {
        let (data, response) = try await transport(ZoomAPI.createMeetingRequest(
            topic: topic, start: start, minutes: minutes, timeZone: timeZone, accessToken: token))
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    private func validToken() async throws -> String {
        if let accessToken, accessToken.expiry > now().addingTimeInterval(60) { return accessToken.token }
        if let refreshing { return try await refreshing.value }
        guard let refresh = try vault.refreshToken(for: Self.vaultKey) else {
            isConnected = false
            throw ZoomAPI.Error.notConnected
        }
        let task = Task { () async throws -> String in
            defer { refreshing = nil }
            do {
                return try await token(ZoomOAuth.refreshRequest(refreshToken: refresh)).accessToken
            } catch GoogleOAuth.Error.invalidGrant {
                disconnect()
                throw ZoomAPI.Error.notConnected
            }
        }
        refreshing = task
        return try await task.value
    }

    /// Sends a token request and keeps what it returns. Zoom issues a new refresh token on every
    /// refresh and revokes the old one, so each one is stored.
    private func token(_ request: URLRequest) async throws -> GoogleOAuth.TokenResponse {
        let (data, response) = try await transport(request)
        let parsed: GoogleOAuth.TokenResponse
        do {
            parsed = try GoogleOAuth.parseTokenResponse(data: data, status: (response as? HTTPURLResponse)?.statusCode ?? 0)
        } catch GoogleOAuth.Error.server(let code) {
            // GoogleOAuth's own messages name Google
            throw ZoomAPI.Error.signIn(code)
        } catch GoogleOAuth.Error.malformedResponse {
            throw ZoomAPI.Error.signIn("unreadable response")
        }
        if let refresh = parsed.refreshToken { vault.setRefreshToken(refresh, for: Self.vaultKey) }
        accessToken = (parsed.accessToken, now().addingTimeInterval(parsed.expiresIn))
        return parsed
    }
}
