import SwiftUI
import WebKit

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
        print("[NulConnect][WebLogin] load startURL=\(session.startURL.absoluteString)")
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
            print("[NulConnect][WebLogin] didStartProvisionalNavigation url=\(url)")
            onStatusChange(url)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            let url = webView.url?.absoluteString ?? session.startURL.absoluteString
            print("[NulConnect][WebLogin] didFinish url=\(url)")
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
            print("[NulConnect][WebLogin] didReceiveServerRedirectForProvisionalNavigation url=\(url)")
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
            print("[NulConnect][WebLogin] capture url=\(url.absoluteString)")
            onStatusChange("已捕获回调地址")
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
    @State private var currentAddress: String
    @State private var errorMessage: String?

    init(session: NulConnectWebLoginSession, onCaptured: @escaping (URL) -> Void, onCancel: @escaping () -> Void) {
        self.session = session
        self.onCaptured = onCaptured
        self.onCancel = onCancel
        _currentAddress = State(initialValue: session.startURL.absoluteString)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.12)
            NulConnectWebViewLoginView(
                session: session,
                onCaptured: onCaptured,
                onStatusChange: { address in
                    currentAddress = address
                },
                onFailure: { message in
                    errorMessage = message
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider().opacity(0.12)
            footer
        }
        .frame(minWidth: 1200, minHeight: 860)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.08, green: 0.10, blue: 0.14),
                    Color(red: 0.11, green: 0.13, blue: 0.18)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .overlay(alignment: .topTrailing) {
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.top, 16)
                    .padding(.trailing, 18)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.title)
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text(session.subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.68))
                }
                Spacer()
                Button("取消") {
                    onCancel()
                }
                .buttonStyle(.bordered)
            }

            Text(session.captureHint)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.70))

            HStack(spacing: 10) {
                Image(systemName: "link")
                    .foregroundStyle(.white.opacity(0.6))
                Text(currentAddress)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .padding(20)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var footer: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("完成登录后窗口会自动关闭")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.72))
                Text("如果页面跳转过快，仍会在捕获到回调后结束")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.48))
            }
            Spacer()
            Button("关闭窗口") {
                onCancel()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(20)
        .fixedSize(horizontal: false, vertical: true)
    }
}
