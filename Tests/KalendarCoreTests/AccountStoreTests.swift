// AccountStore against a scripted transport: sign-in, refresh, a revoked token, sign-out.
import Security
import XCTest
@testable import KalendarCore

private final class MemoryVault: TokenVault {
    var tokens: [String: String] = [:]
    var readError: Error?
    func refreshToken(for email: String) throws -> String? {
        if let readError { throw readError }
        return tokens[email]
    }
    func setRefreshToken(_ token: String?, for email: String) { tokens[email] = token }
}

/// Answers each request with the next scripted (status, body) and records what was sent.
private final class ScriptedTransport: @unchecked Sendable {
    var responses: [(Int, String)] = []
    var sent: [URLRequest] = []

    func callAsFunction(_ request: URLRequest) async throws -> (Data, URLResponse) {
        sent.append(request)
        let (status, body) = responses.isEmpty ? (200, "{}") : responses.removeFirst()
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (Data(body.utf8), response)
    }
}

@MainActor
final class AccountStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private let vault = MemoryVault()
    private let transport = ScriptedTransport()
    private var clock = Date(timeIntervalSince1970: 1_000_000)

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "AccountStoreTests")!
        defaults.removePersistentDomain(forName: "AccountStoreTests")
    }

    private func makeStore() -> AccountStore {
        let transport = self.transport
        return AccountStore(defaults: defaults, vault: vault,
                            transport: { try await transport($0) },
                            now: { [unowned self] in clock })
    }

    private func tokenJSON(email: String, scope: String? = nil, refresh: Bool = true) -> String {
        let scopes = scope ?? (["openid"] + GoogleOAuth.requiredScopes).joined(separator: " ")
        let refreshField = refresh ? #""refresh_token":"rt-\#(email)","# : ""
        return #"{"access_token":"at1","expires_in":3600,\#(refreshField)"id_token":"\#(GoogleOAuthTests.idToken(email: email))","scope":"\#(scopes)"}"#
    }

    func testSignInStoresAccountAndToken() async throws {
        transport.responses = [(200, tokenJSON(email: "a@example.com"))]
        let store = makeStore()
        try await store.completeSignIn(code: "c", pkce: .init(verifier: "v"))
        XCTAssertEqual(store.accounts.map(\.email), ["a@example.com"])
        XCTAssertEqual(vault.tokens["a@example.com"], "rt-a@example.com")
        // persisted: a new store sees the same account
        XCTAssertEqual(makeStore().accounts.map(\.email), ["a@example.com"])
    }

    func testSignInWithoutCalendarScopeFailsAndRevokes() async {
        transport.responses = [(200, tokenJSON(email: "a@example.com", scope: "openid https://www.googleapis.com/auth/tasks"))]
        let store = makeStore()
        do {
            try await store.completeSignIn(code: "c", pkce: .init(verifier: "v"))
            XCTFail("expected missingScopes")
        } catch {
            XCTAssertEqual(error as? GoogleOAuth.Error, .missingScopes(["https://www.googleapis.com/auth/calendar"]))
        }
        XCTAssertTrue(store.accounts.isEmpty)
        XCTAssertTrue(vault.tokens.isEmpty)
        XCTAssertEqual(transport.sent.last?.url?.path, "/revoke")
    }

    func testAccessTokenIsCachedThenRefreshed() async throws {
        transport.responses = [(200, tokenJSON(email: "a@example.com")),
                               (200, #"{"access_token":"at2","expires_in":3600}"#)]
        let store = makeStore()
        try await store.completeSignIn(code: "c", pkce: .init(verifier: "v"))
        let first = try await store.accessToken(for: "a@example.com")
        XCTAssertEqual(first, "at1")
        XCTAssertEqual(transport.sent.count, 1)
        clock += 3590   // within a minute of expiry
        let second = try await store.accessToken(for: "a@example.com")
        XCTAssertEqual(second, "at2")
        let body = String(data: transport.sent[1].httpBody!, encoding: .utf8)!
        XCTAssertTrue(body.contains("grant_type=refresh_token"))
        XCTAssertTrue(body.contains("refresh_token=rt-a%40example.com"))
    }

    func testConcurrentCallersShareOneRefresh() async throws {
        transport.responses = [(200, tokenJSON(email: "a@example.com")),
                               (200, #"{"access_token":"at2","expires_in":3600}"#)]
        let store = makeStore()
        try await store.completeSignIn(code: "c", pkce: .init(verifier: "v"))
        clock += 4000
        async let first = store.accessToken(for: "a@example.com")
        async let second = store.accessToken(for: "a@example.com")
        let tokens = try await [first, second]
        XCTAssertEqual(tokens, ["at2", "at2"])
        XCTAssertEqual(transport.sent.count, 2)   // the sign-in and one refresh
    }

    func testCalendarList401DiscardsCachedAccessToken() async throws {
        transport.responses = [(200, tokenJSON(email: "a@example.com")),
                               (401, "{}"),
                               (200, #"{"access_token":"at2","expires_in":3600}"#),
                               (200, #"{"items":[{"id":"1","summary":"A","accessRole":"owner"}]}"#)]
        let store = makeStore()
        try await store.completeSignIn(code: "c", pkce: .init(verifier: "v"))
        do {
            _ = try await store.calendars(for: "a@example.com")
            XCTFail("expected an error")
        } catch {}
        let calendars = try await store.calendars(for: "a@example.com")
        XCTAssertEqual(calendars.map(\.id), ["1"])
        XCTAssertEqual(transport.sent[3].value(forHTTPHeaderField: "Authorization"), "Bearer at2")
    }

    func testRevokedRefreshTokenMarksNeedsReauth() async throws {
        transport.responses = [(200, tokenJSON(email: "a@example.com")),
                               (400, #"{"error":"invalid_grant"}"#)]
        let store = makeStore()
        try await store.completeSignIn(code: "c", pkce: .init(verifier: "v"))
        clock += 4000
        do {
            _ = try await store.accessToken(for: "a@example.com")
            XCTFail("expected invalidGrant")
        } catch {
            XCTAssertEqual(error as? GoogleOAuth.Error, .invalidGrant)
        }
        XCTAssertEqual(store.accounts.first?.needsReauth, true)
        XCTAssertEqual(makeStore().accounts.first?.needsReauth, true)

        // signing in again clears it
        transport.responses = [(200, tokenJSON(email: "a@example.com"))]
        try await store.completeSignIn(code: "c2", pkce: .init(verifier: "v"))
        XCTAssertEqual(store.accounts.first?.needsReauth, false)
        XCTAssertEqual(store.accounts.count, 1)
    }

    func testSignOutRevokesAndForgets() async throws {
        transport.responses = [(200, tokenJSON(email: "a@example.com")), (200, tokenJSON(email: "b@example.com"))]
        let store = makeStore()
        try await store.completeSignIn(code: "c", pkce: .init(verifier: "v"))
        try await store.completeSignIn(code: "c", pkce: .init(verifier: "v"))
        await store.signOut("a@example.com")
        XCTAssertEqual(store.accounts.map(\.email), ["b@example.com"])
        XCTAssertNil(vault.tokens["a@example.com"])
        XCTAssertEqual(transport.sent.last?.url?.path, "/revoke")
        XCTAssertEqual(makeStore().accounts.map(\.email), ["b@example.com"])
    }

    /// A locked keychain or a denied access prompt is temporary; it must not force a new sign-in.
    func testKeychainReadErrorDoesNotMarkNeedsReauth() async throws {
        transport.responses = [(200, tokenJSON(email: "a@example.com"))]
        let store = makeStore()
        try await store.completeSignIn(code: "c", pkce: .init(verifier: "v"))
        clock += 4000
        vault.readError = Keychain.ReadError(status: errSecInteractionNotAllowed)
        do {
            _ = try await store.accessToken(for: "a@example.com")
            XCTFail("expected the read error")
        } catch {
            XCTAssertEqual(error as? Keychain.ReadError, Keychain.ReadError(status: errSecInteractionNotAllowed))
        }
        XCTAssertEqual(store.accounts.first?.needsReauth, false)
    }
}
