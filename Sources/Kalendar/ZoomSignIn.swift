// Zoom sign-in (§5.1): Zoom's consent page opens in the default browser, which redirects to
// 127.0.0.1 on `ZoomOAuth.redirectPort`. Kalendar listens there only while a sign-in is running,
// answers the one request with a page saying to return to Kalendar, and exchanges the code.
import AppKit
import KalendarCore
import Network

@MainActor
enum Zoom {
    static let account = ZoomAccount()
    private static var listener: NWListener?
    private static var pending: (pkce: GoogleOAuth.PKCE, state: String)?
    private static let portInUse = "Kalendar couldn't listen on port \(ZoomOAuth.redirectPort) for Zoom's sign-in. "
        + "Another app may be using it."

    /// Starts a sign-in; does nothing while one is running.
    static func signIn() {
        guard listener == nil,
              let port = NWEndpoint.Port(rawValue: ZoomOAuth.redirectPort) else { return }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port)
        guard let listener = try? NWListener(using: parameters) else {
            fail(portInUse)
            return
        }
        let pkce = GoogleOAuth.PKCE.generate()
        let state = GoogleOAuth.randomState()
        pending = (pkce, state)
        listener.newConnectionHandler = { connection in
            MainActor.assumeIsolated { receive(connection) }
        }
        // a port in use fails here, after start, not in the initializer
        listener.stateUpdateHandler = { state in
            guard case .failed = state else { return }
            MainActor.assumeIsolated {
                guard self.listener === listener else { return }
                stop()
                fail(portInUse)
            }
        }
        listener.start(queue: .main)
        self.listener = listener
        NSWorkspace.shared.open(ZoomOAuth.authorizationURL(pkce: pkce, state: state))
        // an abandoned sign-in frees the port after five minutes
        DispatchQueue.main.asyncAfter(deadline: .now() + 300) { if self.listener === listener { stop() } }
    }

    private static func receive(_ connection: NWConnection) {
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, _, _ in
            MainActor.assumeIsolated {
                // "GET /zoom?code=…&state=… HTTP/1.1"
                let line = data.flatMap { String(data: $0, encoding: .utf8) }?.split(separator: "\r\n").first ?? ""
                let parts = line.split(separator: " ")
                guard parts.count >= 2, parts[1].hasPrefix("/zoom"),
                      let url = URL(string: "http://127.0.0.1:\(ZoomOAuth.redirectPort)\(parts[1])") else {
                    respond(connection, status: "404 Not Found", text: "Not found.")
                    return
                }
                // the page says how the sign-in ended, so it is sent after the code exchange
                Task { respond(connection, status: "200 OK", text: await finish(url)) }
            }
        }
    }

    private static func respond(_ connection: NWConnection, status: String, text: String) {
        let html = "<!doctype html><meta charset=utf-8><title>Kalendar</title>"
            + "<body style=\"font:16px -apple-system;margin:4em;text-align:center\">\(text)</body>"
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\n"
            + "Content-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }

    /// Exchanges the callback's code; the text for the browser page. A request without this
    /// sign-in's state (a stale tab, another app) is turned away and the sign-in keeps waiting.
    private static func finish(_ callback: URL) async -> String {
        guard let pending else { return "No Zoom sign-in is in progress." }
        let code: String
        do {
            code = try GoogleOAuth.code(fromCallback: callback, expectedState: pending.state)
        } catch GoogleOAuth.Error.stateMismatch {
            return "This sign-in link has expired. Connect Zoom again from Kalendar."
        } catch GoogleOAuth.Error.accessDenied {
            stop()
            Log.auth.info("zoom sign-in declined")
            return "Zoom access was declined. You can close this tab."
        } catch {
            stop()
            return "Zoom sign-in failed: \(error.localizedDescription)"
        }
        stop()
        do {
            try await account.completeSignIn(code: code, pkce: pending.pkce)
            NSApp.activate(ignoringOtherApps: true)
            return "Kalendar is connected to Zoom. You can close this tab."
        } catch {
            let message = "Zoom sign-in failed: \(error.localizedDescription)"
            Log.auth.error("\(message)")
            fail(message)
            return message
        }
    }

    private static func stop() {
        listener?.cancel()
        listener = nil
        pending = nil
    }

    private static func fail(_ message: String) { Dialogs.error("Couldn't connect Zoom", message) }
}
