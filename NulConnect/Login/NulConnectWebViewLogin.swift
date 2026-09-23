import AppKit
import SwiftUI
import WebKit

/// SSO callback/redirect URLs can carry one-time auth tickets or tokens in
/// their query string (e.g. CAS `?ticket=...`), so logs must never include
/// them — only scheme/host/path, which is enough to see where the flow is.
private func loggableURL(_ url: URL) -> String {
    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
        return "<unparseable>"
    }
    components.query = nil
    components.fragment = nil
    return components.string ?? "<unparseable>"
}

struct NulConnectWebViewLoginView: NSViewRepresentable {
    let session: NulConnectWebLoginSession
    let onCaptured: (URL) -> Void
    let onStatusChange: (String) -> Void
    let onFailure: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            session: session,
            onCaptured: onCaptured,
            onStatusChange: onStatusChange,
            onFailure: onFailure
        )
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        context.coordinator.attach(webView)
        print("[NulConnect][WebLogin] load startURL=\(loggableURL(session.startURL))")
        webView.load(URLRequest(url: session.startURL))
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        context.coordinator.update(session: session)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private var session: NulConnectWebLoginSession
        private let onCaptured: (URL) -> Void
        private let onStatusChange: (String) -> Void
        private let onFailure: (String) -> Void
        private weak var webView: WKWebView?
        private var didCapture = false

        init(
            session: NulConnectWebLoginSession,
            onCaptured: @escaping (URL) -> Void,
            onStatusChange: @escaping (String) -> Void,
            onFailure: @escaping (String) -> Void
        ) {
            self.session = session
            self.onCaptured = onCaptured
            self.onStatusChange = onStatusChange
            self.onFailure = onFailure
        }

        func attach(_ webView: WKWebView) {
            self.webView = webView
        }

        func update(session: NulConnectWebLoginSession) {
            self.session = session
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            let url = webView.url?.absoluteString ?? session.startURL.absoluteString
            print("[NulConnect][WebLogin] didStartProvisionalNavigation url=\(loggableURL(webView.url ?? session.startURL))")
            onStatusChange(url)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            let url = webView.url?.absoluteString ?? session.startURL.absoluteString
            print("[NulConnect][WebLogin] didFinish url=\(loggableURL(webView.url ?? session.startURL))")
            onStatusChange(url)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            guard shouldReport(error: error) else { return }
            print("[NulConnect][WebLogin] didFail error=\(error.localizedDescription)")
            onFailure(error.localizedDescription)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            guard shouldReport(error: error) else { return }
            print("[NulConnect][WebLogin] didFailProvisionalNavigation error=\(error.localizedDescription)")
            onFailure(error.localizedDescription)
        }

        func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
            let url = webView.url?.absoluteString ?? session.startURL.absoluteString
            print("[NulConnect][WebLogin] didReceiveServerRedirectForProvisionalNavigation url=\(loggableURL(webView.url ?? session.startURL))")
            if didCapture {
                return
            }
            if let currentURL = webView.url, session.capturePolicy.shouldCapture(currentURL) {
                capture(currentURL)
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }
            handle(url: url, decisionHandler: decisionHandler)
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            guard let url = navigationResponse.response.url else {
                decisionHandler(.allow)
                return
            }
            if didCapture {
                decisionHandler(.cancel)
                return
            }
            if session.capturePolicy.shouldCapture(url) {
                decisionHandler(.cancel)
                capture(url)
                return
            }
            decisionHandler(.allow)
        }

        private func handle(url: URL, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if didCapture {
                decisionHandler(.cancel)
                return
            }
            if session.capturePolicy.shouldCapture(url) {
                decisionHandler(.cancel)
                capture(url)
                return
            }
            decisionHandler(.allow)
        }

        private func capture(_ url: URL) {
            guard !didCapture else { return }
            didCapture = true
            print("[NulConnect][WebLogin] capture url=\(loggableURL(url))")
            onStatusChange(NulConnectLocalization.text("Callback URL captured"))
            onCaptured(url)
            webView?.stopLoading()
        }

        private func shouldReport(error: Error) -> Bool {
            if didCapture {
                return false
            }
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
                return false
            }
            return true
        }
    }
}

struct NulConnectWebLoginSheet: View {
    let session: NulConnectWebLoginSession
    let onCaptured: (URL) -> Void
    let onCancel: () -> Void
    @State private var errorMessage: String?

    init(session: NulConnectWebLoginSession, onCaptured: @escaping (URL) -> Void, onCancel: @escaping () -> Void) {
        self.session = session
        self.onCaptured = onCaptured
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            if let errorMessage {
                errorBanner(errorMessage)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 12)
            }

            NulConnectWebViewLoginView(
                session: session,
                onCaptured: onCaptured,
                onStatusChange: { _ in },
                onFailure: { message in
                    errorMessage = message
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
            .padding(.horizontal, 18)
            .padding(.bottom, 18)
        }
        .frame(minWidth: 980, minHeight: 680)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "person.badge.key")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 36, height: 36)

                VStack(alignment: .leading, spacing: 3) {
                    Text(session.title)
                        .font(.title3.weight(.semibold))
                    Text(session.subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button(NulConnectLocalization.text("Cancel")) {
                    onCancel()
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(18)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func errorBanner(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(.orange)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct NulConnectWebLoginWindow: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var windowCoordinator: NulConnectWindowCoordinator
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Group {
            if let session = model.webLoginSession {
                NulConnectWebLoginSheet(
                    session: session,
                    onCaptured: { callbackURL in
                        model.completeWebLogin(with: callbackURL)
                    },
                    onCancel: {
                        model.cancelWebLogin()
                    }
                )
            } else {
                ProgressView()
                    .frame(minWidth: 980, minHeight: 680)
            }
        }
        .background(
            NulConnectWindowAccessor { window in
                windowCoordinator.register(window: window, role: .webLogin)
            }
        )
        .onChange(of: model.webLoginSession?.id) { _, sessionID in
            if sessionID == nil {
                dismissWindow(id: "web-login")
            }
        }
        .onDisappear {
            if model.webLoginSession != nil {
                model.cancelWebLogin()
            }
        }
    }
}
