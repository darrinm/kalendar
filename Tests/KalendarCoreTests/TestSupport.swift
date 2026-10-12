// Shared fakes for tests that talk to "Google".
import Foundation
@testable import KalendarCore

final class StubVault: TokenVault {
    func refreshToken(for email: String) throws -> String? { "rt" }
    func setRefreshToken(_ token: String?, for email: String) {}
}

/// A fake Calendar API: one handler decides each response from the request.
final class FakeGoogle: @unchecked Sendable {
    var handler: (URLRequest, [String: String]) -> (Int, String) = { _, _ in (404, "{}") }
    var log: [String] = []
    /// Holds PATCH requests this long, to overlap them with a sync.
    var patchDelay: UInt64 = 0
    /// Every non-auth request, for checking methods, headers and bodies.
    var requests: [URLRequest] = []
    /// Fails every non-auth request as if the Mac were offline.
    var offline = false

    func callAsFunction(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let url = request.url!
        let query = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems ?? []).map { ($0.name, $0.value ?? "") })
        if request.httpMethod == "PATCH", patchDelay > 0 { try await Task.sleep(nanoseconds: patchDelay) }
        let (status, body): (Int, String)
        if url.host == "oauth2.googleapis.com" {
            (status, body) = (200, #"{"access_token":"at","expires_in":3600}"#)
        } else {
            if offline { throw URLError(.notConnectedToInternet) }
            requests.append(request)
            log.append("\(request.httpMethod ?? "GET") \(url.path)" + (query["syncToken"].map { " sync=\($0)" } ?? "")
                       + (query["singleEvents"].map { " single=\($0)" } ?? ""))
            (status, body) = handler(request, query)
        }
        return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

extension URLRequest {
    /// The JSON body as a dictionary.
    var json: [String: Any]? { httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } }
}
