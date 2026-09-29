import Foundation
import Network
import Testing
@testable import NulConnect

/// Serves a few fake SSO pages on loopback:
/// - `/auto` redirects straight to the CAS callback (SSO "remember me"),
/// - `/form` shows a password form,
/// - `/idle` shows a page that neither redirects nor asks for input.
private final class FakePortal: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "fake-portal")

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [queue] connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, _ in
                let request = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
                let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
                let response: String
                switch path {
                case "/auto":
                    response = "HTTP/1.1 302 Found\r\nLocation: /cas/login?ticket=ST-1\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                default:
                    let body = path == "/form"
                        ? "<html><body><form><input type=\"text\" name=\"user\"><input type=\"password\" name=\"pw\"></form></body></html>"
                        : "<html><body><p>Please wait</p></body></html>"
                    response = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                }
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
        }
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
        }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
    }

    var port: UInt16 { listener.port?.rawValue ?? 0 }

    deinit { listener.cancel() }
}

@MainActor
struct WebLoginControllerTests {
    private func session(path: String, port: UInt16) -> NulConnectWebLoginSession {
        NulConnectWebLoginSession(
            id: UUID(),
            method: ATRAuthMethod(loginDomain: "", authType: "auth/cas", authName: "CAS", loginURL: ""),
            deviceID: "device",
            title: "Sign in",
            subtitle: "",
            startURL: URL(string: "http://127.0.0.1:\(port)\(path)")!,
            captureHint: "",
            capturePolicy: .cas(baseHost: "127.0.0.1", allowedHosts: ["127.0.0.1"])
        )
    }

    private enum Outcome: Equatable {
        case captured(String)
        case needsInteraction(String)
    }

    private func run(path: String, silentTimeout: Duration = .seconds(3)) async throws -> Outcome {
        let portal = try FakePortal()
        let controller = NulConnectWebLoginController(
            session: session(path: path, port: portal.port),
            mode: .silent,
            silentTimeout: silentTimeout,
            settleDelay: .milliseconds(300)
        )
        var outcome: Outcome?
        controller.onCaptured = { outcome = .captured($0.query ?? "") }
        controller.onNeedsInteraction = { outcome = .needsInteraction($0) }
        controller.start()
        let deadline = ContinuousClock.now + silentTimeout + .seconds(10)
        while outcome == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        controller.stop()
        withExtendedLifetime(portal) {}
        return try #require(outcome)
    }

    @Test func rememberedSSOCompletesWithoutShowingTheWindow() async throws {
        #expect(try await run(path: "/auto") == .captured("ticket=ST-1"))
    }

    @Test func loginFormAsksForTheUserQuickly() async throws {
        // WebKit's cold start alone can take seconds on a busy CI runner, so use
        // a long timeout: the form must be reported as waiting for input, well
        // before the timeout would have fired.
        let started = ContinuousClock.now
        #expect(try await run(path: "/form", silentTimeout: .seconds(20)) == .needsInteraction("page waits for input"))
        #expect(ContinuousClock.now - started < .seconds(15))
    }

    @Test func stuckPageFallsBackAfterTheTimeout() async throws {
        #expect(try await run(path: "/idle") == .needsInteraction("timeout"))
    }
}
