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

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let vault: TokenVault
    @ObservationIgnored private let transport: Transport
    @ObservationIgnored private var accessTokens: [String: (token: String, expiry: Date)] = [:]
    /// One refresh per account at a time; concurrent callers await the same request.
    @ObservationIgnored private var refreshes: [String: Task<String, Swift.Error>] = [:]
    @ObservationIgnored private let now: () -> Date

    private static let accountsKey = "accounts"
    private static let reauthKey = "accountsNeedingReauth"

    public init(defaults: UserDefaults = .standard,
                vault: TokenVault = KeychainVault(),
                transport: @escaping Transport = { try await URLSession.shared.data(for: $0) },
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
    @discardableResult
    public func completeSignIn(code: String, pkce: GoogleOAuth.PKCE) async throws -> Account {
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
        accessTokens[email] = (response.accessToken, now().addingTimeInterval(response.expiresIn))
        let account = Account(email: email, needsReauth: false)
        if let i = accounts.firstIndex(where: { $0.email == email }) {
            accounts[i] = account
        } else {
            accounts.append(account)
        }
        persist()
        Log.auth.info("signed in \(email, privacy: .private)")
        return account
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
            accessTokens[email] = (response.accessToken, now().addingTimeInterval(response.expiresIn))
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
        Log.auth.info("signed out \(email, privacy: .private)")
    }

    private func markNeedsReauth(_ email: String) {
        accessTokens[email] = nil
        guard let i = accounts.firstIndex(where: { $0.email == email }), !accounts[i].needsReauth else { return }
        accounts[i].needsReauth = true
        persist()
    }

    /// Sends a Google API request made with `accessToken(for:)`. A 401 means Google no longer accepts
    /// the cached access token, so it is discarded and the next call refreshes it.
    func sendAuthorized(_ request: URLRequest, for email: String) async throws -> (Data, Int) {
        let (data, response) = try await transport(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 { accessTokens[email] = nil }
        return (data, status)
    }

    private func send(_ request: URLRequest) async throws -> GoogleOAuth.TokenResponse {
        let (data, response) = try await transport(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return try GoogleOAuth.parseTokenResponse(data: data, status: status)
    }

    private func persist() {
        defaults.set(accounts.map(\.email), forKey: Self.accountsKey)
        defaults.set(accounts.filter(\.needsReauth).map(\.email), forKey: Self.reauthKey)
    }
}
