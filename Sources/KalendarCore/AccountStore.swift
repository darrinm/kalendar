// The signed-in Google accounts and their tokens.
//
// The account list (emails, in the order added) lives in UserDefaults. Each account's refresh token
// lives in the Keychain. Access tokens are kept in memory only and refreshed on demand.
import Foundation
import Observation

/// Where refresh tokens are kept. The Keychain in the app, a dictionary in tests.
public protocol TokenVault: AnyObject {
    /// nil when the account has no stored token; throws when the store cannot be read right now.
    func refreshToken(for email: String) throws -> String?
    func setRefreshToken(_ token: String?, for email: String)
}

public final class KeychainVault: TokenVault {
    public init() {}
    public func refreshToken(for email: String) throws -> String? { try Keychain.get("refresh:\(email)") }
    public func setRefreshToken(_ token: String?, for email: String) { Keychain.set(token, for: "refresh:\(email)") }
}

@MainActor
@Observable
public final class AccountStore {
    public struct Account: Identifiable, Equatable {
        public var email: String
        /// The refresh token was revoked or expired; the UI shows "Sign in again to <email>".
        public var needsReauth: Bool
        public var id: String { email }
    }

    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    public private(set) var accounts: [Account] = []

    /// The signed-in emails, those in `email`'s domain first: a Workspace shares calendars and
    /// free/busy within the organization (§21).
    public func emails(preferringDomainOf email: String) -> [String] {
        let domain = "@" + (email.split(separator: "@").last?.lowercased() ?? "")
        let all = accounts.map(\.email)
        return all.filter { $0.lowercased().hasSuffix(domain) } + all.filter { !$0.lowercased().hasSuffix(domain) }
    }
    /// Called after an account signs out, so its cached data can be deleted (§8.5).
    @ObservationIgnored public var onSignedOut: (String) -> Void = { _ in }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let vault: TokenVault
    /// Google's API with no response cache. With URLSession.shared, which caches GET responses, a
    /// task DELETE after a GET of the same URL gets 412 "conditionNotMet, If-Match" although
    /// Kalendar sends no If-Match. With this session it succeeds (-selfTest, run both ways).
    public static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    @ObservationIgnored private let transport: Transport
    @ObservationIgnored private var accessTokens: [String: (token: String, expiry: Date)] = [:]
    /// One refresh per account at a time; concurrent callers await the same request.
    @ObservationIgnored private var refreshes: [String: Task<String, Swift.Error>] = [:]
    @ObservationIgnored private let now: () -> Date

    private static let accountsKey = "accounts"
    private static let reauthKey = "accountsNeedingReauth"

    public init(defaults: UserDefaults = .standard,
                vault: TokenVault = KeychainVault(),
                transport: @escaping Transport = { try await AccountStore.session.data(for: $0) },
                now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.vault = vault
        self.transport = transport
        self.now = now
        let emails = defaults.stringArray(forKey: Self.accountsKey) ?? []
        let reauth = Set(defaults.stringArray(forKey: Self.reauthKey) ?? [])
        accounts = emails.map { Account(email: $0, needsReauth: reauth.contains($0)) }
    }

    /// Exchanges an authorization code for tokens and adds (or re-authorizes) the account.
    public func completeSignIn(code: String, pkce: GoogleOAuth.PKCE) async throws {
        let response = try await send(GoogleOAuth.tokenRequest(code: code, pkce: pkce))
        let missing = GoogleOAuth.missingRequiredScopes(response.grantedScopes)
        guard missing.isEmpty else {
            // Revoke the partial grant so the next attempt shows the full consent screen again.
            _ = try? await transport(GoogleOAuth.revokeRequest(token: response.accessToken))
            throw GoogleOAuth.Error.missingScopes(missing)
        }
        guard let email = response.idToken.flatMap(GoogleOAuth.email(fromIDToken:)) else {
            throw GoogleOAuth.Error.noEmail
        }
        guard let refresh = response.refreshToken else { throw GoogleOAuth.Error.malformedResponse }
        vault.setRefreshToken(refresh, for: email)
        cacheAccessToken(response, for: email)
        let account = Account(email: email, needsReauth: false)
        if let i = accounts.firstIndex(where: { $0.email == email }) {
            accounts[i] = account
        } else {
            accounts.append(account)
        }
        persist()
        Log.auth.info("signed in \(email, privacy: .private)")
    }

    /// A valid access token, refreshed when it expires within a minute.
    /// Throws `invalidGrant` and marks the account `needsReauth` when the refresh token is dead.
    public func accessToken(for email: String) async throws -> String {
        if let cached = accessTokens[email], cached.expiry > now().addingTimeInterval(60) {
            return cached.token
        }
        if let pending = refreshes[email] { return try await pending.value }
        let task = Task { try await refreshAccessToken(for: email) }
        refreshes[email] = task
        defer { refreshes[email] = nil }
        return try await task.value
    }

    private func refreshAccessToken(for email: String) async throws -> String {
        guard let refresh = try vault.refreshToken(for: email) else {
            markNeedsReauth(email)
            throw GoogleOAuth.Error.invalidGrant
        }
        do {
            let response = try await send(GoogleOAuth.refreshRequest(refreshToken: refresh))
            cacheAccessToken(response, for: email)
            return response.accessToken
        } catch GoogleOAuth.Error.invalidGrant {
            markNeedsReauth(email)
            throw GoogleOAuth.Error.invalidGrant
        }
    }

    /// Revokes the grant at Google (best effort; signing out works offline) and forgets the account.
    public func signOut(_ email: String) async {
        if let refresh = try? vault.refreshToken(for: email) {
            _ = try? await transport(GoogleOAuth.revokeRequest(token: refresh))
        }
        vault.setRefreshToken(nil, for: email)
        accessTokens[email] = nil
        accounts.removeAll { $0.email == email }
        persist()
        onSignedOut(email)
        Log.auth.info("signed out \(email, privacy: .private)")
    }

    private func markNeedsReauth(_ email: String) {
        accessTokens[email] = nil
        guard let i = accounts.firstIndex(where: { $0.email == email }), !accounts[i].needsReauth else { return }
        accounts[i].needsReauth = true
        persist()
    }

    /// Sends a Google API request built by `make` with the account's access token. A 401 means
    /// Google no longer accepts that token (for example, access was revoked at
    /// myaccount.google.com), so it is discarded and the request is retried once with a fresh one;
    /// a dead refresh token then surfaces as `invalidGrant`.
    public func sendAuthorized(for email: String, _ make: (String) -> URLRequest) async throws -> (Data, Int) {
        let (data, status) = try await perform(make(try await accessToken(for: email)))
        guard status == 401 else { return (data, status) }
        accessTokens[email] = nil
        return try await perform(make(try await accessToken(for: email)))
    }

    private func send(_ request: URLRequest) async throws -> GoogleOAuth.TokenResponse {
        let (data, status) = try await perform(request)
        return try GoogleOAuth.parseTokenResponse(data: data, status: status)
    }

    private func perform(_ request: URLRequest) async throws -> (Data, Int) {
        let (data, response) = try await transport(request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    private func cacheAccessToken(_ response: GoogleOAuth.TokenResponse, for email: String) {
        accessTokens[email] = (response.accessToken, now().addingTimeInterval(response.expiresIn))
    }

    private func persist() {
        defaults.set(accounts.map(\.email), forKey: Self.accountsKey)
        defaults.set(accounts.filter(\.needsReauth).map(\.email), forKey: Self.reauthKey)
    }
}
