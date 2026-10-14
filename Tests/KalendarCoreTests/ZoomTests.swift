// Zoom (§5.1): the public-client OAuth requests, and creating a meeting with a refreshed token.
import XCTest
@testable import KalendarCore

/// What the fake Zoom saw; a class, so the transport closure can count into it.
private final class Calls: @unchecked Sendable {
    var meetings = 0
    var refreshes: [String] = []
}

private final class MemoryVault: TokenVault {
    var tokens: [String: String] = [:]
    func refreshToken(for email: String) throws -> String? { tokens[email] }
    func setRefreshToken(_ token: String?, for email: String) { tokens[email] = token }
}

@MainActor
final class ZoomTests: XCTestCase {
    private let pkce = GoogleOAuth.PKCE(verifier: "v" + String(repeating: "x", count: 42))
    private let start = ISO8601DateFormatter().date(from: "2026-10-15T21:00:00Z")!

    private func form(_ r: URLRequest) -> [String: String] {
        let pairs = String(data: r.httpBody!, encoding: .utf8)!.split(separator: "&").map { $0.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false) }
        return Dictionary(uniqueKeysWithValues: pairs.map { (String($0[0]), String($0[1]).removingPercentEncoding!) })
    }

    func testAuthorizationAndTokenRequestsArePublicClientPKCE() {
        let url = ZoomOAuth.authorizationURL(pkce: pkce, state: "s1")
        let items = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!
            .queryItems!.map { ($0.name, $0.value!) })
        XCTAssertEqual(url.host, "zoom.us")
        XCTAssertEqual(items["code_challenge"], pkce.challenge)
        XCTAssertEqual(items["code_challenge_method"], "S256")
        XCTAssertEqual(items["redirect_uri"], "http://127.0.0.1:47823/zoom")
        XCTAssertEqual(items["state"], "s1")

        let token = ZoomOAuth.tokenRequest(code: "c1", pkce: pkce)
        XCTAssertNil(token.value(forHTTPHeaderField: "Authorization"), "a public client sends no secret")
        XCTAssertEqual(form(token)["grant_type"], "authorization_code")
        XCTAssertEqual(form(token)["code_verifier"], pkce.verifier)
        XCTAssertEqual(form(token)["redirect_uri"], ZoomOAuth.redirectURI)
    }

    func testCreateMeetingRefreshesStoresTheRotatedTokenAndRetriesA401() async throws {
        let vault = MemoryVault()
        vault.tokens["zoom"] = "r1"
        let calls = Calls()
        let zoom = ZoomAccount(vault: vault, transport: { request in
            let url = request.url!
            let status: Int, body: String
            if url.host == "zoom.us" {
                calls.refreshes.append(String(data: request.httpBody!, encoding: .utf8)!)
                let n = calls.refreshes.count
                (status, body) = (200, #"{"access_token":"a\#(n)","expires_in":3600,"refresh_token":"r\#(n + 1)"}"#)
            } else {
                calls.meetings += 1
                let json = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
                XCTAssertEqual(json["topic"] as? String, "Mike / Darrin")
                XCTAssertEqual(json["start_time"] as? String, "2026-10-15T21:00:00Z")
                XCTAssertEqual(json["duration"] as? Int, 30)
                // the first access token is rejected, as if revoked
                (status, body) = calls.meetings == 1 ? (401, "{}") : (201, #"{"id":123,"join_url":"https://playful.zoom.us/j/123"}"#)
            }
            return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
        })
        XCTAssertTrue(zoom.isConnected)
        let meeting = try await zoom.createMeeting(topic: "Mike / Darrin", start: start, minutes: 30, timeZone: "America/Los_Angeles")
        XCTAssertEqual(meeting, ZoomAPI.Meeting(id: 123, joinURL: "https://playful.zoom.us/j/123"))
        XCTAssertEqual(calls.meetings, 2)
        XCTAssertEqual(calls.refreshes.count, 2)
        XCTAssertTrue(calls.refreshes[1].contains("refresh_token=r2"), "the second refresh uses the rotated token")
        XCTAssertEqual(vault.tokens["zoom"], "r3")
    }

    func testRevokedRefreshTokenDisconnects() async {
        let vault = MemoryVault()
        vault.tokens["zoom"] = "r1"
        let zoom = ZoomAccount(vault: vault, transport: { request in
            (Data(#"{"error":"invalid_grant"}"#.utf8),
             HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!)
        })
        do {
            _ = try await zoom.createMeeting(topic: "x", start: start, minutes: 30, timeZone: "UTC")
            XCTFail("expected notConnected")
        } catch {
            XCTAssertEqual(error as? ZoomAPI.Error, .notConnected)
        }
        XCTAssertFalse(zoom.isConnected)
        XCTAssertNil(vault.tokens["zoom"])
    }
}
