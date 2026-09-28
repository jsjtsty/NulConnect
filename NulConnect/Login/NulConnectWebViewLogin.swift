import AppKit
import Combine
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

/// Drives one web sign-in. The web view lives here rather than in the login
/// window so the SSO flow can first run without any window: with SSO
/// "remember me", the portal redirects straight to the callback and the
/// user never needs to see a page. Only when the page actually waits for
/// the user is the same web view (state intact, no reload) moved into the
/// login window.
@MainActor
final class NulConnectWebLoginController: NSObject, ObservableObject, WKNavigationDelegate {
    enum Mode {
        /// Not shown; waiting to see whether SSO completes by itself.
        case silent
        case interactive
    }

    /// Longest silent attempt before the page is assumed to need the user.
    private let silentTimeout: Duration
    /// A page that stops navigating for this long is checked for input
    /// fields the user has to fill in.
    private let settleDelay: Duration

    let session: NulConnectWebLoginSession
    let webView: WKWebView
    @Published private(set) var errorMessage: String?
    private(set) var mode: Mode

    var onCaptured: ((URL) -> Void)?
    /// Called once when a silent attempt turns out to need the user.
    var onNeedsInteraction: ((String) -> Void)?

    private var didCapture = false
    private var isStopped = false
    private var timeoutTask: Task<Void, Never>?
    private var settleTask: Task<Void, Never>?

    init(
        session: NulConnectWebLoginSession,
        mode: Mode,
        silentTimeout: Duration = .seconds(8),
        settleDelay: Duration = .milliseconds(1500)
    ) {
        self.session = session
        self.mode = mode
        self.silentTimeout = silentTimeout
        self.settleDelay = settleDelay
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        // A real size, even while not in a window, so page layout and the
        // visibility check of input fields behave like in the login window.
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 980, height: 600), configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
    }

    func start() {
        print("[NulConnect][WebLogin] load mode=\(mode) startURL=\(loggableURL(session.startURL))")
        webView.load(URLRequest(url: session.startURL))
        if mode == .silent {
            let silentTimeout = self.silentTimeout
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: silentTimeout)
                guard !Task.isCancelled else { return }
                self?.escalate(reason: "timeout")
            }
        }
    }

    /// Switches to a visible sign-in; the page keeps its current state.
    func becomeInteractive() {
        mode = .interactive
        timeoutTask?.cancel()
        settleTask?.cancel()
    }

    func stop() {
        isStopped = true
        timeoutTask?.cancel()
        settleTask?.cancel()
        webView.stopLoading()
        webView.navigationDelegate = nil
    }

    private func escalate(reason: String) {
        guard mode == .silent, !didCapture, !isStopped else { return }
        print("[NulConnect][WebLogin] silent sign-in needs the user: \(reason)")
        becomeInteractive()
        onNeedsInteraction?(reason)
    }

    /// Visible text/password fields mean the portal is waiting for input.
    private func checkForUserInput() {
        let script = """
        (() => {
          const visible = (element) => {
            const rect = element.getBoundingClientRect();
            const style = window.getComputedStyle(element);
            return rect.width > 0 && rect.height > 0 && style.visibility !== "hidden" && style.display !== "none";
          };
          const fields = document.querySelectorAll('input[type="password"], input[type="text"], input[type="tel"], input[type="email"], input[type="number"], input:not([type])');
          return Array.from(fields).some(visible);
        })()
        """
        webView.evaluateJavaScript(script) { [weak self] result, _ in
            Task { @MainActor [weak self] in
                if (result as? Bool) == true {
                    self?.escalate(reason: "page waits for input")
                }
            }
        }
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        settleTask?.cancel()
        print("[NulConnect][WebLogin] didStartProvisionalNavigation url=\(loggableURL(webView.url ?? session.startURL))")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        print("[NulConnect][WebLogin] didFinish url=\(loggableURL(webView.url ?? session.startURL))")
        guard mode == .silent else { return }
        settleTask?.cancel()
        let settleDelay = self.settleDelay
        settleTask = Task { [weak self] in
            try? await Task.sleep(for: settleDelay)
            guard !Task.isCancelled else { return }
            self?.checkForUserInput()
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        report(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        report(error)
    }

    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        print("[NulConnect][WebLogin] didReceiveServerRedirectForProvisionalNavigation url=\(loggableURL(webView.url ?? session.startURL))")
        if !didCapture, let currentURL = webView.url, session.capturePolicy.shouldCapture(currentURL) {
            capture(currentURL)
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
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

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
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

    private func capture(_ url: URL) {
        guard !didCapture, !isStopped else { return }
        didCapture = true
        timeoutTask?.cancel()
        settleTask?.cancel()
        print("[NulConnect][WebLogin] capture mode=\(mode) url=\(loggableURL(url))")
        webView.stopLoading()
        onCaptured?(url)
    }

    private func report(_ error: Error) {
        let nsError = error as NSError
        guard !didCapture, !(nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled) else {
            return
        }
        print("[NulConnect][WebLogin] navigation failed error=\(error.localizedDescription)")
        errorMessage = error.localizedDescription
        escalate(reason: "navigation failed")
    }
}

/// Shows the controller's existing web view; moving it here keeps the page
/// exactly as the silent attempt left it.
struct NulConnectHostedWebView: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(to: container)
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if webView.superview !== nsView {
            nsView.subviews.forEach { $0.removeFromSuperview() }
            attach(to: nsView)
        }
    }

    private func attach(to container: NSView) {
        webView.removeFromSuperview()
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)
    }
}

struct NulConnectWebLoginSheet: View {
    @ObservedObject var controller: NulConnectWebLoginController
    let onCancel: () -> Void

    private var session: NulConnectWebLoginSession {
        controller.session
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            if let errorMessage = controller.errorMessage {
                errorBanner(errorMessage)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 12)
            }

            NulConnectHostedWebView(webView: controller.webView)
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
            if let controller = model.webLoginController {
                NulConnectWebLoginSheet(
                    controller: controller,
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
