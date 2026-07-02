import Foundation
import Darwin
import Network

struct NulConnectProxyEndpoint: Sendable, Codable, Equatable {
    var host: String
    var port: UInt16

    var displayString: String {
        "\(host):\(port)"
    }
}

enum NulConnectProxyServiceError: LocalizedError {
    case missingSession
    case missingResource
    case listenerFailed(String)
    case invalidEndpoint

    var errorDescription: String? {
        switch self {
        case .missingSession:
            return "proxy mode requires a saved session"
        case .missingResource:
            return "proxy mode requires a resource snapshot"
        case .listenerFailed(let message):
            return message
        case .invalidEndpoint:
            return "invalid proxy endpoint"
        }
    }
}

@MainActor
final class NulConnectProxyGateway {
    private let client: ATRClient

    init(profile: NulConnectProfile, session: ATRSessionMaterial, resource: ATRResourceSnapshot) throws {
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
    }

    func routeTCP(host: String, port: UInt16) async throws -> ATRRouteDecision {
        try client.routeTCP(host: host, port: port)
    }

    func openTCP(host: String, port: UInt16) async throws -> ATRTcpTunnel {
        try client.openTCP(host: host, port: port)
    }
}

final class NulConnectProxyService {
    private let gateway: NulConnectProxyGateway
    private let resource: ATRResourceSnapshot
    private let listenHostString: String
    private let listenHost: NWEndpoint.Host
    private let listenPort: NWEndpoint.Port
    private let queue = DispatchQueue(label: "com.nulstudio.NulConnect.proxy", qos: .utility)
    private var listener: NWListener?
    private(set) var endpoint: NulConnectProxyEndpoint?

    init(profile: NulConnectProfile, session: ATRSessionMaterial?, resource: ATRResourceSnapshot?, listenHost: String = "127.0.0.1", listenPort: UInt16 = 1080) async throws {
        guard let session else {
            throw NulConnectProxyServiceError.missingSession
        }
        guard let resource else {
            throw NulConnectProxyServiceError.missingResource
        }
        guard let nwPort = NWEndpoint.Port(rawValue: listenPort) else {
            throw NulConnectProxyServiceError.invalidEndpoint
        }
        self.gateway = try await MainActor.run {
            try NulConnectProxyGateway(profile: profile, session: session, resource: resource)
        }
        self.resource = resource
        self.listenHostString = listenHost
        self.listenHost = NWEndpoint.Host(listenHost)
        self.listenPort = nwPort
    }

    func start() async throws -> NulConnectProxyEndpoint {
        if let endpoint {
            return endpoint
        }

        let parameters = NWParameters.tcp
        let listener = try NWListener(using: parameters, on: listenPort)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            Task {
                await self.handle(connection: connection)
            }
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var didResume = false
            func finish(_ result: Result<Void, Error>) {
                guard !didResume else { return }
                didResume = true
                listener.stateUpdateHandler = nil
                switch result {
                case .success:
                    continuation.resume(returning: ())
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    finish(.success(()))
                case .failed(let error):
                    finish(.failure(error))
                case .cancelled:
                    finish(.failure(NulConnectProxyServiceError.listenerFailed("listener cancelled")))
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }

        self.listener = listener

        let endpoint = NulConnectProxyEndpoint(host: listenHostString, port: listenPort.rawValue)
        self.endpoint = endpoint
        logResourceSnapshot()
        return endpoint
    }

    func stop() {
        listener?.cancel()
        listener = nil
        endpoint = nil
    }

    private func handle(connection: NWConnection) async {
        let inbound = NulConnectNWByteChannel(connection: connection, queue: queue)
        await inbound.start()

        do {
            let firstChunk = try await inbound.receive(maxLength: 16 * 1024)
            guard let firstChunk, !firstChunk.isEmpty else {
                await inbound.close()
                return
            }

            if firstChunk.first == 0x05 {
                print("[NulConnect][Proxy] inbound SOCKS5 handshake started")
                try await handleSOCKS5(connection: inbound, initialData: firstChunk)
            } else {
                print("[NulConnect][Proxy] inbound HTTP proxy request started")
                try await handleHTTPProxy(connection: inbound, initialData: firstChunk)
            }
        } catch {
            print("[NulConnect][Proxy] inbound handler failed: \(error)")
            await inbound.close()
        }
    }

    private func handleHTTPProxy(connection: NulConnectNWByteChannel, initialData: Data) async throws {
        var buffer = initialData
        while NulConnectProxyParser.parseHTTPProxyRequest(buffer) == nil {
            guard let chunk = try await connection.receive(maxLength: 16 * 1024), !chunk.isEmpty else {
                await connection.close()
                return
            }
            buffer.append(chunk)
            if buffer.count > 64 * 1024 {
                await connection.close()
                return
            }
        }

        guard let request = NulConnectProxyParser.parseHTTPProxyRequest(buffer) else {
            await connection.close()
            return
        }

        print("[NulConnect][Proxy][HTTP] method='\(request.method)' target='\(request.target)' bodyBytes=\(request.body.count)")

        if request.method.uppercased() == "CONNECT" {
            try await handleConnectTunnel(
                clientChannel: connection,
                hostPort: request.target,
                leftover: request.body,
                mode: .httpConnect
            )
            return
        }

        let (host, port) = try parseHTTPDestination(from: request)
        print("[NulConnect][Proxy][HTTP] parsed destination host='\(host)' port=\(port)")
        let rewrittenRequest = NulConnectProxyParser.rewriteHTTPProxyRequest(request, host: host, port: port)
        try await forwardRequest(clientChannel: connection, host: host, port: port, initialPayload: rewrittenRequest)
    }

    private func handleSOCKS5(connection: NulConnectNWByteChannel, initialData: Data) async throws {
        var buffer = initialData
        while NulConnectProxyParser.parseSOCKS5Greeting(buffer) == nil {
            guard let chunk = try await connection.receive(maxLength: 16 * 1024), !chunk.isEmpty else {
                await connection.close()
                return
            }
            buffer.append(chunk)
        }

        guard NulConnectProxyParser.parseSOCKS5Greeting(buffer) == true else {
            await connection.close()
            return
        }
        try await connection.send(NulConnectProxyParser.socks5GreetingResponse())

        buffer.removeAll(keepingCapacity: true)
        while true {
            guard let chunk = try await connection.receive(maxLength: 16 * 1024), !chunk.isEmpty else {
                await connection.close()
                return
            }
            buffer.append(chunk)
            if let request = try NulConnectProxyParser.parseSOCKS5ConnectRequest(buffer) {
                print("[NulConnect][Proxy][SOCKS5] connect request host='\(request.host)' port=\(request.port) leftover=\(request.remainingData.count)")
                try await handleConnectTunnel(
                    clientChannel: connection,
                    hostPort: "\(request.host):\(request.port)",
                    leftover: request.remainingData,
                    mode: .socks5
                )
                return
            }
            if buffer.count > 64 * 1024 {
                await connection.close()
                return
            }
        }
    }

    private func handleConnectTunnel(clientChannel: NulConnectNWByteChannel, hostPort: String, leftover: Data, mode: ProxyTunnelMode) async throws {
        let (host, port) = try parseHostPort(hostPort)
        do {
            print("[NulConnect][Proxy][CONNECT] begin host='\(host)' port=\(port) mode=\(mode)")
            let route = try await resolvedTCPRoute(host: host, port: port)
            print("[NulConnect][Proxy][CONNECT] route=\(route.decision) connectHost='\(route.connectHost)' reason='\(route.reason)'")

            let remote: NulConnectByteChannel
            switch route.decision {
            case .managed:
                let tunnel = try await gateway.openTCP(host: route.connectHost, port: port)
                remote = NulConnectATRTunnelChannel(tunnel: tunnel)
                print("[NulConnect][Proxy][CONNECT] managed tunnel opened host='\(route.connectHost)' originalHost='\(host)' port=\(port)")
            case .direct:
                remote = try await NulConnectNWByteChannel.connect(host: host, port: port, queue: queue)
                print("[NulConnect][Proxy][CONNECT] direct connection opened host='\(host)' port=\(port)")
            }

            switch mode {
            case .httpConnect:
                try await clientChannel.send(Data("HTTP/1.1 200 Connection Established\r\nProxy-Agent: NulConnect\r\n\r\n".utf8))
            case .socks5:
                try await clientChannel.send(NulConnectProxyParser.socks5ConnectSuccessResponse())
            }

            if !leftover.isEmpty {
                print("[NulConnect][Proxy][CONNECT] forwarding leftover bytes=\(leftover.count)")
                try await remote.send(leftover)
            }
            await relayBidirectional(a: clientChannel, b: remote, label: "\(host):\(port)")
        } catch {
            print("[NulConnect][Proxy][CONNECT] failed host='\(host)' port=\(port) error=\(error)")
            switch mode {
            case .httpConnect:
                await clientChannel.close()
            case .socks5:
                try? await clientChannel.send(NulConnectProxyParser.socks5FailureResponse())
                await clientChannel.close()
            }
        }
    }

    private func forwardRequest(clientChannel: NulConnectNWByteChannel, host: String, port: UInt16, initialPayload: Data) async throws {
        let route = try await resolvedTCPRoute(host: host, port: port)
        print("[NulConnect][Proxy][HTTP] forward host='\(host)' port=\(port) route=\(route.decision) connectHost='\(route.connectHost)' reason='\(route.reason)' payloadBytes=\(initialPayload.count)")
        let remote: NulConnectByteChannel
        switch route.decision {
        case .managed:
            let tunnel = try await gateway.openTCP(host: route.connectHost, port: port)
            remote = NulConnectATRTunnelChannel(tunnel: tunnel)
            print("[NulConnect][Proxy][HTTP] managed tunnel opened host='\(route.connectHost)' originalHost='\(host)' port='\(port)'")
        case .direct:
            remote = try await NulConnectNWByteChannel.connect(host: host, port: port, queue: queue)
            print("[NulConnect][Proxy][HTTP] direct connection opened host='\(host)' port='\(port)'")
        }

        try await remote.send(initialPayload)
        await relayBidirectional(a: clientChannel, b: remote, label: "\(host):\(port)")
    }

    private func resolvedTCPRoute(host: String, port: UInt16) async throws -> ProxyResolvedRoute {
        let route = try await gateway.routeTCP(host: host, port: port)
        if route == .managed {
            return ProxyResolvedRoute(decision: .managed, connectHost: host, reason: "host")
        }

        guard Self.ipv4Number(host) == nil else {
            return ProxyResolvedRoute(decision: .direct, connectHost: host, reason: "ip-direct")
        }

        let resolvedIPs = Self.resolveIPv4Addresses(host: host)
        for ip in resolvedIPs {
            let resolvedRoute = try await gateway.routeTCP(host: ip, port: port)
            if resolvedRoute == .managed {
                return ProxyResolvedRoute(decision: .managed, connectHost: ip, reason: "resolved-ip:\(host)->\(ip)")
            }
        }

        if resolvedIPs.isEmpty {
            print("[NulConnect][Proxy][Route] host='\(host)' port=\(port) dnsA=[]")
        } else {
            print("[NulConnect][Proxy][Route] host='\(host)' port=\(port) dnsA=\(resolvedIPs.joined(separator: ",")) route=direct")
        }
        return ProxyResolvedRoute(decision: .direct, connectHost: host, reason: "direct")
    }

    private func relayBidirectional(a: NulConnectByteChannel, b: NulConnectByteChannel, label: String) async {
        print("[NulConnect][Proxy][Relay] start \(label)")
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await self.copyLoop(source: a, destination: b, direction: "client->remote", label: label)
            }
            group.addTask {
                await self.copyLoop(source: b, destination: a, direction: "remote->client", label: label)
            }
            await group.next()
            group.cancelAll()
        }
        await a.close()
        await b.close()
        print("[NulConnect][Proxy][Relay] end \(label)")
    }

    private func copyLoop(source: NulConnectByteChannel, destination: NulConnectByteChannel, direction: String, label: String) async {
        do {
            var totalBytes = 0
            var nextLogThreshold = 1024 * 1024
            while !Task.isCancelled {
                guard let chunk = try await source.receive(maxLength: 64 * 1024), !chunk.isEmpty else {
                    print("[NulConnect][Proxy][Relay] \(label) \(direction) closed totalBytes=\(totalBytes)")
                    break
                }
                totalBytes += chunk.count
                if totalBytes >= nextLogThreshold {
                    print("[NulConnect][Proxy][Relay] \(label) \(direction) transferred totalBytes=\(totalBytes)")
                    nextLogThreshold += 1024 * 1024
                }
                try await destination.send(chunk)
            }
        } catch {
            print("[NulConnect][Proxy][Relay] \(label) \(direction) error=\(error)")
        }
    }

    private func parseHostPort(_ hostPort: String) throws -> (String, UInt16) {
        if hostPort.hasPrefix("[") {
            guard let closingBracket = hostPort.firstIndex(of: "]") else {
                throw NulConnectProxyServiceError.invalidEndpoint
            }
            let host = String(hostPort[hostPort.index(after: hostPort.startIndex)..<closingBracket])
            let remainder = hostPort[hostPort.index(after: closingBracket)...]
            guard remainder.hasPrefix(":"), let port = UInt16(remainder.dropFirst()) else {
                throw NulConnectProxyServiceError.invalidEndpoint
            }
            return (host, port)
        }

        let parts = hostPort.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2, let port = UInt16(parts[1]) else {
            throw NulConnectProxyServiceError.invalidEndpoint
        }
        return (String(parts[0]), port)
    }

    private func parseHTTPDestination(from request: NulConnectHTTPProxyRequest) throws -> (String, UInt16) {
        if let url = URL(string: request.target), let host = url.host {
            let port = url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80)
            return (host, UInt16(port))
        }

        if let hostHeader = request.headers["host"] {
            return try parseHostPort(hostHeader.contains(":") ? hostHeader : "\(hostHeader):80")
        }

        throw NulConnectProxyServiceError.invalidEndpoint
    }

    func probeSOCKS5() async {
        await probeSOCKS5(host: "example.com", port: 80, label: "direct-example", sendHTTP: true)
        if let sample = managedProbeTarget() {
            await probeSOCKS5(host: sample.host, port: sample.port, label: "managed-sample", sendHTTP: false)
        } else {
            print("[NulConnect][ProxyProbe] managed-sample skipped: no managed TCP resource found")
        }
    }

    private func probeSOCKS5(host: String, port: UInt16, label: String, sendHTTP: Bool) async {
        guard let endpoint else {
            print("[NulConnect][ProxyProbe] skipped: proxy endpoint not ready")
            return
        }

        do {
            let channel = try await NulConnectNWByteChannel.connect(host: endpoint.host, port: endpoint.port, queue: queue)
            defer { Task { await channel.close() } }

            print("[NulConnect][ProxyProbe][\(label)] connected to \(endpoint.displayString), target=\(host):\(port)")

            try await channel.send(Data([0x05, 0x01, 0x00]))
            let greeting = try await channel.receive(maxLength: 16)
            print("[NulConnect][ProxyProbe][\(label)] socks5 greeting response=\(Self.hexDump(greeting ?? Data()))")

            let hostBytes = Array(host.utf8)
            guard hostBytes.count <= UInt8.max else {
                print("[NulConnect][ProxyProbe][\(label)] skipped: host too long")
                return
            }
            var connectRequest = Data([0x05, 0x01, 0x00, 0x03, UInt8(hostBytes.count)])
            connectRequest.append(contentsOf: hostBytes)
            connectRequest.append(UInt8(port >> 8))
            connectRequest.append(UInt8(port & 0xff))
            try await channel.send(connectRequest)
            let reply = try await channel.receive(maxLength: 32)
            print("[NulConnect][ProxyProbe][\(label)] socks5 connect reply=\(Self.hexDump(reply ?? Data()))")

            guard sendHTTP else { return }

            let request = Data("GET / HTTP/1.1\r\nHost: \(host)\r\nConnection: close\r\n\r\n".utf8)
            try await channel.send(request)
            let response = try await channel.receive(maxLength: 256)
            print("[NulConnect][ProxyProbe][\(label)] socks5 http response=\(Self.hexDump(response ?? Data()))")
            if let response, let text = String(data: response, encoding: .utf8) {
                print("[NulConnect][ProxyProbe][\(label)] socks5 http text=\(text.prefix(160))")
            }
        } catch {
            print("[NulConnect][ProxyProbe][\(label)] failed: \(error)")
        }
    }

    private func logResourceSnapshot() {
        print("[NulConnect][ProxyResource] bytes=\(resource.resourceBytes.count) ip=\(resource.ipResources.count) domain=\(resource.domainResources.count) dns=\(resource.dnsResources.count) nodeGroups=\(resource.nodeGroups.count) majorNodeGroup='\(resource.majorNodeGroup)'")
        for item in resource.domainResources.prefix(12) {
            print("[NulConnect][ProxyResource] domain='\(item.domain)' ports=\(item.portMin)-\(item.portMax) proto='\(item.protocolName)' appID='\(item.appID)' nodeGroupID='\(item.nodeGroupID)'")
        }
        for item in resource.ipResources.prefix(8) {
            print("[NulConnect][ProxyResource] ip=\(item.ipMin)-\(item.ipMax) ports=\(item.portMin)-\(item.portMax) proto='\(item.protocolName)' appID='\(item.appID)' nodeGroupID='\(item.nodeGroupID)'")
        }
        for group in resource.nodeGroups.prefix(8) {
            print("[NulConnect][ProxyResource] nodeGroup='\(group.groupID)' addresses=\(group.addresses.joined(separator: ","))")
        }
    }

    private func managedProbeTarget() -> (host: String, port: UInt16)? {
        if let domain = resource.domainResources.first(where: { ($0.protocolName == "tcp" || $0.protocolName == "all") && Self.probeHost(from: $0.domain) != nil }) {
            guard let host = Self.probeHost(from: domain.domain) else {
                return nil
            }
            return (host, Self.preferredProbePort(min: domain.portMin, max: domain.portMax))
        }
        if let ip = resource.ipResources.first(where: { $0.protocolName == "tcp" || $0.protocolName == "all" }) {
            return (ip.ipMin, Self.preferredProbePort(min: ip.portMin, max: ip.portMax))
        }
        return nil
    }

    private static func probeHost(from domainPattern: String) -> String? {
        let trimmed = domainPattern.trimmingCharacters(in: CharacterSet(charactersIn: "*."))
        guard trimmed.contains("."), !trimmed.isEmpty else {
            return nil
        }
        if domainPattern.hasPrefix(".") || domainPattern.hasPrefix("*.") {
            return "www.\(trimmed)"
        }
        return trimmed
    }

    private static func preferredProbePort(min: UInt16, max: UInt16) -> UInt16 {
        if min <= 443, 443 <= max {
            return 443
        }
        if min <= 80, 80 <= max {
            return 80
        }
        return min == 0 ? 80 : min
    }

    private static func hexDump(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    private static func ipv4Number(_ value: String) -> UInt32? {
        var addr = in_addr()
        guard inet_pton(AF_INET, value, &addr) == 1 else {
            return nil
        }
        return UInt32(bigEndian: addr.s_addr)
    }

    private static func resolveIPv4Addresses(host: String) -> [String] {
        var hints = addrinfo()
        hints.ai_flags = AI_ADDRCONFIG
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP

        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, nil, &hints, &result)
        guard status == 0, let first = result else {
            return []
        }
        defer { freeaddrinfo(first) }

        var addresses: [String] = []
        var seen = Set<String>()
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let current = cursor {
            defer { cursor = current.pointee.ai_next }
            guard current.pointee.ai_family == AF_INET, let socketAddress = current.pointee.ai_addr else {
                continue
            }

            var ipv4 = socketAddress.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { pointer in
                pointer.pointee.sin_addr
            }
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &ipv4, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else {
                continue
            }
            let address = String(cString: buffer)
            if seen.insert(address).inserted {
                addresses.append(address)
            }
        }
        return addresses
    }

}

private struct ProxyResolvedRoute {
    var decision: ATRRouteDecision
    var connectHost: String
    var reason: String
}

private enum ProxyTunnelMode {
    case httpConnect
    case socks5
}

protocol NulConnectByteChannel: AnyObject {
    func send(_ data: Data) async throws
    func receive(maxLength: Int) async throws -> Data?
    func close() async
}

private final class NulConnectNWByteChannel: NulConnectByteChannel {
    private let connection: NWConnection
    private let queue: DispatchQueue

    init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    static func connect(host: String, port: UInt16, queue: DispatchQueue) async throws -> NulConnectNWByteChannel {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw NulConnectProxyServiceError.invalidEndpoint
        }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        let channel = NulConnectNWByteChannel(connection: connection, queue: queue)
        try await channel.startAndWait()
        return channel
    }

    func start() async {
        connection.start(queue: queue)
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            })
        }
    }

    func receive(maxLength: Int) async throws -> Data? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, Error>) in
            self.receiveOnce(maxLength: maxLength, continuation: continuation)
        }
    }

    func close() async {
        connection.cancel()
    }

    private func startAndWait() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var didResume = false
            func finish(_ result: Result<Void, Error>) {
                guard !didResume else { return }
                didResume = true
                connection.stateUpdateHandler = nil
                switch result {
                case .success:
                    continuation.resume(returning: ())
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    finish(.success(()))
                case .failed(let error):
                    finish(.failure(error))
                case .cancelled:
                    finish(.failure(NulConnectProxyServiceError.listenerFailed("connection cancelled")))
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    private func receiveOnce(
        maxLength: Int,
        continuation: CheckedContinuation<Data?, Error>
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: maxLength) { data, _, isComplete, error in
            if let error {
                continuation.resume(throwing: error)
                return
            }
            if let data, !data.isEmpty {
                continuation.resume(returning: data)
                return
            }
            if isComplete {
                continuation.resume(returning: nil)
                return
            }
            self.receiveOnce(maxLength: maxLength, continuation: continuation)
        }
    }
}

private final class NulConnectATRTunnelChannel: NulConnectByteChannel {
    private let tunnel: ATRTcpTunnel
    private let readQueue = DispatchQueue(label: "com.nulstudio.NulConnect.atr-tunnel.read", qos: .utility)
    private let writeQueue = DispatchQueue(label: "com.nulstudio.NulConnect.atr-tunnel.write", qos: .utility)

    init(tunnel: ATRTcpTunnel) {
        self.tunnel = tunnel
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writeQueue.async {
                do {
                    _ = try self.tunnel.write(data)
                    continuation.resume(returning: ())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func receive(maxLength: Int) async throws -> Data? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, Error>) in
            readQueue.async {
                do {
                    let data = try self.tunnel.read(maxLength: maxLength)
                    continuation.resume(returning: data.isEmpty ? nil : data)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func close() async {
        writeQueue.async {
            try? self.tunnel.close()
        }
    }
}
