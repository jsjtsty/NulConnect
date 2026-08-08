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
    private var keepAlive: ATRKeepAliveService?
    private var eventMonitorTask: Task<Void, Never>?
    private(set) var endpoint: NulConnectProxyEndpoint?

    init(
        profile: NulConnectProfile,
        session: ATRSessionMaterial?,
        resource: ATRResourceSnapshot?,
        listenHost: String = "127.0.0.1",
        listenPort: UInt16 = 1920
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
            NulConnectDiagnostics.log("[NulConnect][Proxy] start: reusing endpoint=\(endpoint.host):\(endpoint.port)")
            return endpoint
        }

        NulConnectDiagnostics.log("[NulConnect][Proxy] start: listen=\(listenHost):\(listenPort) socks5=true http=true")
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
        let keepAlive = try client.startKeepAlive()
        self.keepAlive = keepAlive
        self.endpoint = endpoint
        NulConnectDiagnostics.log("[NulConnect][Proxy] start: ready endpoint=\(endpoint.host):\(endpoint.port)")
        startEventMonitor(service, keepAlive: keepAlive)
        return endpoint
    }

    func stop() {
        if let endpoint {
            NulConnectDiagnostics.log("[NulConnect][Proxy] stop: endpoint=\(endpoint.host):\(endpoint.port)")
        } else {
            NulConnectDiagnostics.log("[NulConnect][Proxy] stop: no active endpoint")
        }
        eventMonitorTask?.cancel()
        eventMonitorTask = nil
        try? keepAlive?.stop()
        keepAlive = nil
        try? service?.stop()
        service = nil
        endpoint = nil
    }

    func probeSOCKS5() async {
        guard let service else {
            NulConnectDiagnostics.log("[NulConnect][ProxyProbe] skipped: proxy service not ready")
            return
        }
        do {
            let endpoint = try service.endpoint()
            let stats = try service.stats()
            NulConnectDiagnostics.log("[NulConnect][ProxyProbe] rust proxy ready endpoint=\(endpoint.host):\(endpoint.port) active=\(stats.activeConnections) total=\(stats.totalConnections)")
            if let lastError = stats.lastError, !lastError.isEmpty {
                NulConnectDiagnostics.log("[NulConnect][ProxyProbe] rust proxy lastError=\(lastError)")
            }
            if let lastEvent = stats.lastEvent {
                NulConnectDiagnostics.log("[NulConnect][ProxyProbe] rust proxy lastEvent=\(lastEvent)")
            }
        } catch {
            NulConnectDiagnostics.log("[NulConnect][ProxyProbe] failed: \(error)")
        }
    }

    func trafficCounters() throws -> NulConnectTrafficCounters {
        guard let service else {
            return .zero
        }
        let stats = try service.trafficStats()
        return NulConnectTrafficCounters(
            uploadedBytes: stats.managedUploadBytes,
            downloadedBytes: stats.managedDownloadBytes,
            uploadedPackets: 0,
            downloadedPackets: 0
        )
    }

    private func startEventMonitor(_ service: ATRProxyService, keepAlive: ATRKeepAliveService) {
        eventMonitorTask?.cancel()
        let onSessionInvalidated = onSessionInvalidated
        eventMonitorTask = Task.detached(priority: .utility) { [service, keepAlive, onSessionInvalidated] in
            var pollCount = 0
            var reportedKeepAliveError: String?
            var reportedStats: String?
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(1))
                    guard !Task.isCancelled else { return }
                    pollCount += 1
                    if pollCount % 2 == 0 {
                        let stats = try service.stats()
                        let lastEvent = stats.lastEvent.map { String(describing: $0) } ?? "nil"
                        let snapshot = "active=\(stats.activeConnections) total=\(stats.totalConnections) lastError=\(stats.lastError ?? "nil") lastEvent=\(lastEvent)"
                        if snapshot != reportedStats || pollCount % 60 == 0 {
                            reportedStats = snapshot
                            NulConnectDiagnostics.log("[NulConnect][Proxy] stats: \(snapshot)")
                        }
                    }
                    if pollCount % 30 == 0 {
                        let status = try keepAlive.status()
                        if let message = status.lastError, message != reportedKeepAliveError {
                            reportedKeepAliveError = message
                            NulConnectDiagnostics.log("[NulConnect][Proxy] keep-alive failed: \(message)")
                            if Self.isSessionInvalidationMessage(message) {
                                await MainActor.run {
                                    onSessionInvalidated?(
                                        NulConnectProxyServiceError.sessionExpired(message)
                                    )
                                }
                            }
                        } else if status.lastError == nil {
                            reportedKeepAliveError = nil
                        }
                    }
                    guard let event = try service.takeEvent() else {
                        continue
                    }
                    switch event {
                    case .sessionInvalidated(let message):
                        NulConnectDiagnostics.log("[NulConnect][Proxy] event: sessionInvalidated message=\(message)")
                        await MainActor.run {
                            onSessionInvalidated?(
                                NulConnectProxyServiceError.sessionExpired(message)
                            )
                        }
                    case .error(let message):
                        NulConnectDiagnostics.log("[NulConnect][Proxy] event: error message=\(message)")
                    }
                } catch is CancellationError {
                    return
                } catch {
                    NulConnectDiagnostics.log("[NulConnect][Proxy] event monitor failed: \(error)")
                }
            }
        }
    }

    private nonisolated static func isSessionInvalidationMessage(_ message: String) -> Bool {
        let normalized = message.lowercased()
        return normalized.contains("invalid sid")
            || normalized.contains("not logged in")
            || normalized.contains("unauthorized")
    }
}
