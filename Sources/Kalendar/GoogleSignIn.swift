// Runs Google's consent screen in ASWebAuthenticationSession and hands the code to AccountStore.
import AppKit
import AuthenticationServices
import KalendarCore

@MainActor
final class GoogleSignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
    private let accounts: AccountStore
    private var session: ASWebAuthenticationSession?

    init(accounts: AccountStore) {
        self.accounts = accounts
    }

    /// `loginHint` re-authorizes that account; nil adds an account.
    func run(loginHint: String?) async {
        guard session == nil else { return }   // one sign-in at a time
        let pkce = GoogleOAuth.PKCE.generate()
        let state = GoogleOAuth.randomState()
        let url = GoogleOAuth.authorizationURL(pkce: pkce, state: state, loginHint: loginHint)
        do {
            let callback = try await present(url)
            let code = try GoogleOAuth.code(fromCallback: callback, expectedState: state)
            try await accounts.completeSignIn(code: code, pkce: pkce)
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            Log.auth.info("sign-in cancelled")
        } catch GoogleOAuth.Error.accessDenied {
            Log.auth.info("sign-in declined")
        } catch {
            Log.auth.error("sign-in failed: \(error.localizedDescription)")
            showError(error)
        }
    }

    private func present(_ url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: url, callbackURLScheme: GoogleOAuth.redirectScheme
            ) { [weak self] callback, error in
                Task { @MainActor in self?.session = nil }
                if let callback {
                    continuation.resume(returning: callback)
                } else {
                    continuation.resume(throwing: error ?? GoogleOAuth.Error.malformedResponse)
                }
            }
            session.presentationContextProvider = self
            // false: reuse the browser's Google cookies so a signed-in user only picks an account
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            NSApp.activate(ignoringOtherApps: true)
            if !session.start() {
                self.session = nil
                continuation.resume(throwing: GoogleOAuth.Error.server("could not start the sign-in window"))
            }
        }
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            NSApp.keyWindow ?? NSApp.windows.first { $0.isVisible } ?? NSWindow()
        }
    }

    private func showError(_ error: Error) {
        Dialogs.error("Couldn't sign in to Google", error.localizedDescription)
    }
}
