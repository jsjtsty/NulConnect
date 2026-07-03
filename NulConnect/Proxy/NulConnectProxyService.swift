import Foundation

enum NulConnectProxyServiceError: LocalizedError {
    case missingSession
    case missingResource
    case sessionExpired(String)
    case listenerFailed(String)
    case invalidEndpoint

    var errorDescription: String? {
        switch self {
        case .missingSession:
            return "proxy mode requires a saved session"
        case .missingResource:
            return "proxy mode requires a resource snapshot"
        case .sessionExpired(let message):
            return message
        case .listenerFailed(let message):
            return message
        case .invalidEndpoint:
            return "invalid proxy endpoint"
        }
    }
}

final class NulConnectProxyService {
    var onSessionInvalidated: (@Sendable (Error) -> Void)?

    private let client: ATRClient
    private let listenHost: String
    private let listenPort: UInt16
    private var service: ATRProxyService?
    private var eventMonitorTask: Task<Void, Never>?
    private(set) var endpoint: NulConnectProxyEndpoint?

    init(
        profile: NulConnectProfile,
        session: ATRSessionMaterial?,
        resource: ATRResourceSnapshot?,
        listenHost: String = "127.0.0.1",
        listenPort: UInt16 = 1080
    ) async throws {
        guard let session else {
            throw NulConnectProxyServiceError.missingSession
        }
        guard let resource else {
            throw NulConnectProxyServiceError.missingResource
        }

        let configuration = ATRClientConfiguration(
            serverHost: profile.serverHost,
            serverPort: profile.serverPort,
            userAgent: profile.userAgent,
            connectTimeout: profile.connectTimeoutMillis,
            ioTimeout: profile.ioTimeoutMillis,
            nodeProbeTimeout: profile.nodeProbeTimeoutMillis,
            allowInsecureTLS: profile.allowInsecureTLS
        )
        let client = try ATRClient(configuration: configuration)
        try client.setSession(session)
        try client.setResource(resource.resourceBytes, serviceHost: profile.serverHost)

        self.client = client
        self.listenHost = listenHost
        self.listenPort = listenPort
    }

    func start() async throws -> NulConnectProxyEndpoint {
        if let endpoint {
            return endpoint
        }

        let service = try client.startProxyService(
            configuration: ATRProxyServiceConfiguration(
                listenHost: listenHost,
                listenPort: listenPort,
                connectTimeout: 10_000,
                idleTimeout: 0,
                enableHTTP: true,
                enableSOCKS5: true
            )
        )
        let atrEndpoint = try service.endpoint()
        let endpoint = NulConnectProxyEndpoint(host: atrEndpoint.host, port: atrEndpoint.port)
        self.service = service
        self.endpoint = endpoint
        startEventMonitor(service)
        return endpoint
    }

    func stop() {
        eventMonitorTask?.cancel()
        eventMonitorTask = nil
        try? service?.stop()
        service = nil
        endpoint = nil
    }

    func probeSOCKS5() async {
        guard let service else {
            print("[NulConnect][ProxyProbe] skipped: proxy service not ready")
            return
        }
        do {
            let endpoint = try service.endpoint()
            let stats = try service.stats()
            print("[NulConnect][ProxyProbe] rust proxy ready endpoint=\(endpoint.host):\(endpoint.port) active=\(stats.activeConnections) total=\(stats.totalConnections)")
            if let lastError = stats.lastError, !lastError.isEmpty {
                print("[NulConnect][ProxyProbe] rust proxy lastError=\(lastError)")
            }
            if let lastEvent = stats.lastEvent {
                print("[NulConnect][ProxyProbe] rust proxy lastEvent=\(lastEvent)")
            }
        } catch {
            print("[NulConnect][ProxyProbe] failed: \(error)")
        }
    }

    private func startEventMonitor(_ service: ATRProxyService) {
        eventMonitorTask?.cancel()
        let onSessionInvalidated = onSessionInvalidated
        eventMonitorTask = Task.detached(priority: .utility) { [service, onSessionInvalidated] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(1))
                    guard !Task.isCancelled else { return }
                    guard let event = try service.takeEvent() else {
                        continue
                    }
                    switch event {
                    case .sessionInvalidated(let message):
                        await MainActor.run {
                            onSessionInvalidated?(
                                NulConnectProxyServiceError.sessionExpired(message)
                            )
                        }
                    case .error:
                        break
                    }
                } catch is CancellationError {
                    return
                } catch {
                    print("[NulConnect][Proxy] event monitor failed: \(error)")
                }
            }
        }
    }
}
