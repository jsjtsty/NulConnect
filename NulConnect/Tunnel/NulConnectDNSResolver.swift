import Foundation
import Network

enum NulConnectDNSResolutionSource: String, Sendable {
    case snapshot
    case serviceDNS
    case publicDNS
}

struct NulConnectDNSResolution: Sendable, Equatable {
    var domain: String
    var ipv4Addresses: [String]
    var source: NulConnectDNSResolutionSource
    var isManagedDomain: Bool
    var expiresAt: Date
}

struct NulConnectResolvedRoute: Sendable, Equatable {
    var ipAddress: String
    var isManaged: Bool
    var sourceDomain: String?
    var source: NulConnectDNSResolutionSource
    var expiresAt: Date
}

struct NulConnectDNSResolverConfiguration: Sendable {
    var serviceDNSServers: [String]
    var publicDNSServers: [String]
    var queryTimeout: TimeInterval
    var serviceTTLUpperBound: TimeInterval
    var publicFallbackTTLUpperBound: TimeInterval
    var negativeTTL: TimeInterval

    static let `default` = NulConnectDNSResolverConfiguration(
        serviceDNSServers: [],
        publicDNSServers: ["1.1.1.1", "8.8.8.8"],
        queryTimeout: 2,
        serviceTTLUpperBound: 30 * 60,
        publicFallbackTTLUpperBound: 5 * 60,
        negativeTTL: 30
    )
}

enum NulConnectDNSResolverError: Error, LocalizedError {
    case noDNSServers
    case noARecords(String)
    case malformedResponse
    case queryFailed(String)

    var errorDescription: String? {
        switch self {
        case .noDNSServers:
            return "no DNS servers configured"
        case .noARecords(let domain):
            return "no A records for \(domain)"
        case .malformedResponse:
            return "malformed DNS response"
        case .queryFailed(let message):
            return message
        }
    }
}

actor NulConnectDNSCache {
    private var resolutions: [String: NulConnectDNSResolution] = [:]
    private var negativeExpiresAt: [String: Date] = [:]
    private var routes: [String: NulConnectResolvedRoute] = [:]

    func resolution(for domain: String, now: Date = .now) -> NulConnectDNSResolution? {
        let key = NulConnectDomainRule.normalize(domain)
        guard let cached = resolutions[key] else {
            return nil
        }
        if cached.expiresAt <= now {
            resolutions.removeValue(forKey: key)
            return nil
        }
        return cached
    }

    func isNegativeCached(_ domain: String, now: Date = .now) -> Bool {
        let key = NulConnectDomainRule.normalize(domain)
        guard let expiresAt = negativeExpiresAt[key] else {
            return false
        }
        if expiresAt <= now {
            negativeExpiresAt.removeValue(forKey: key)
            return false
        }
        return true
    }

    func store(_ resolution: NulConnectDNSResolution) {
        let key = NulConnectDomainRule.normalize(resolution.domain)
        resolutions[key] = resolution
        negativeExpiresAt.removeValue(forKey: key)
        for ip in resolution.ipv4Addresses {
            routes[ip] = NulConnectResolvedRoute(
                ipAddress: ip,
                isManaged: resolution.isManagedDomain,
                sourceDomain: key,
                source: resolution.source,
                expiresAt: resolution.expiresAt
            )
        }
    }

    func storeNegative(domain: String, expiresAt: Date) {
        negativeExpiresAt[NulConnectDomainRule.normalize(domain)] = expiresAt
    }

    func route(for ipAddress: String, now: Date = .now) -> NulConnectResolvedRoute? {
        guard let cached = routes[ipAddress] else {
            return nil
        }
        if cached.expiresAt <= now {
            routes.removeValue(forKey: ipAddress)
            return nil
        }
        return cached
    }

    func removeAll() {
        resolutions.removeAll()
        negativeExpiresAt.removeAll()
        routes.removeAll()
    }
}

final class NulConnectDNSResolver: @unchecked Sendable {
    private let resource: ATRResourceSnapshot
    private let configuration: NulConnectDNSResolverConfiguration
    private let cache: NulConnectDNSCache
    private let queue = DispatchQueue(label: "com.nulstudio.NulConnect.dns", qos: .utility)
    private let domainRules: [NulConnectDomainRule]
    private let staticDNS: [String: [String]]

    init(
        resource: ATRResourceSnapshot,
        configuration: NulConnectDNSResolverConfiguration = .default,
        cache: NulConnectDNSCache = NulConnectDNSCache()
    ) {
        self.resource = resource
        self.configuration = configuration
        self.cache = cache
        self.domainRules = resource.domainResources.map { NulConnectDomainRule(pattern: $0.domain) }

        var staticDNS: [String: [String]] = [:]
        for record in resource.dnsResources {
            let key = NulConnectDomainRule.normalize(record.domain)
            staticDNS[key, default: []].append(record.ip)
        }
        self.staticDNS = staticDNS.mapValues { Array(Set($0)).sorted() }
    }

    func resolveARecords(for domain: String, now: Date = .now) async throws -> NulConnectDNSResolution {
        let normalizedDomain = NulConnectDomainRule.normalize(domain)
        guard !normalizedDomain.isEmpty else {
            throw NulConnectDNSResolverError.noARecords(domain)
        }

        if let cached = await cache.resolution(for: normalizedDomain, now: now) {
            return cached
        }
        if await cache.isNegativeCached(normalizedDomain, now: now) {
            throw NulConnectDNSResolverError.noARecords(normalizedDomain)
        }

        let isManaged = isManagedDomain(normalizedDomain)
        if let snapshotIPs = staticDNS[normalizedDomain], !snapshotIPs.isEmpty {
            let resolution = NulConnectDNSResolution(
                domain: normalizedDomain,
                ipv4Addresses: snapshotIPs,
                source: .snapshot,
                isManagedDomain: isManaged,
                expiresAt: .distantFuture
            )
            await cache.store(resolution)
            return resolution
        }

        do {
            let service = try await queryFirstAvailable(
                domain: normalizedDomain,
                servers: serviceDNSServers(),
                source: .serviceDNS,
                ttlUpperBound: configuration.serviceTTLUpperBound,
                now: now
            )
            await cache.store(service.withManagedDomain(isManaged))
            return service.withManagedDomain(isManaged)
        } catch {
            let fallback = try await queryFirstAvailable(
                domain: normalizedDomain,
                servers: configuration.publicDNSServers,
                source: .publicDNS,
                ttlUpperBound: configuration.publicFallbackTTLUpperBound,
                now: now
            )
            let resolution = fallback.withManagedDomain(isManaged)
            await cache.store(resolution)
            return resolution
        }
    }

    func cachedRoute(for ipAddress: String) async -> NulConnectResolvedRoute? {
        await cache.route(for: ipAddress)
    }

    func isManagedDomain(_ domain: String) -> Bool {
        let normalizedDomain = NulConnectDomainRule.normalize(domain)
        return domainRules.contains { $0.matches(normalizedDomain) }
    }

    func isManagedIPAddress(_ ipAddress: String) -> Bool {
        guard let ip = NulConnectIPv4Range.ipv4Number(ipAddress) else {
            return false
        }
        return resource.ipResources.contains { item in
            guard item.protocolName == "tcp" || item.protocolName == "udp" || item.protocolName == "all" else {
                return false
            }
            guard
                let min = NulConnectIPv4Range.ipv4Number(item.ipMin),
                let max = NulConnectIPv4Range.ipv4Number(item.ipMax)
            else {
                return false
            }
            return min <= ip && ip <= max
        }
    }

    private func serviceDNSServers() -> [String] {
        var servers: [String] = []
        if let dnsServer = resource.dnsServer, !dnsServer.isEmpty {
            servers.append(dnsServer)
        }
        servers.append(contentsOf: configuration.serviceDNSServers)

        var seen = Set<String>()
        return servers.filter { seen.insert($0).inserted }
    }

    private func queryFirstAvailable(
        domain: String,
        servers: [String],
        source: NulConnectDNSResolutionSource,
        ttlUpperBound: TimeInterval,
        now: Date
    ) async throws -> NulConnectDNSResolution {
        guard !servers.isEmpty else {
            throw NulConnectDNSResolverError.noDNSServers
        }

        var lastError: Error?
        for server in servers {
            do {
                let response = try await queryARecords(domain: domain, server: server)
                guard !response.ipv4Addresses.isEmpty else {
                    continue
                }
                let ttl = max(1, min(TimeInterval(response.minimumTTL), ttlUpperBound))
                return NulConnectDNSResolution(
                    domain: domain,
                    ipv4Addresses: response.ipv4Addresses,
                    source: source,
                    isManagedDomain: false,
                    expiresAt: now.addingTimeInterval(ttl)
                )
            } catch {
                lastError = error
            }
        }

        await cache.storeNegative(domain: domain, expiresAt: now.addingTimeInterval(configuration.negativeTTL))
        if let lastError {
            throw lastError
        }
        throw NulConnectDNSResolverError.noARecords(domain)
    }

    private func queryARecords(domain: String, server: String) async throws -> NulConnectDNSResponse {
        let request = try NulConnectDNSMessage.makeAQuery(domain: domain)
        let response = try await sendUDPQuery(request.data, server: server, port: 53)
        return try NulConnectDNSMessage.parseAResponse(response, expectedID: request.id)
    }

    private func sendUDPQuery(_ query: Data, server: String, port: UInt16) async throws -> Data {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw NulConnectDNSResolverError.queryFailed("invalid DNS port")
        }

        let connection = NWConnection(host: NWEndpoint.Host(server), port: nwPort, using: .udp)
        connection.start(queue: queue)
        defer { connection.cancel() }

        return try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(self.configuration.queryTimeout * 1_000_000_000))
                throw NulConnectDNSResolverError.queryFailed("DNS query timed out: \(server)")
            }
            group.addTask {
                try await withCheckedThrowingContinuation { continuation in
                    connection.send(content: query, completion: .contentProcessed { error in
                        if let error {
                            continuation.resume(throwing: error)
                            return
                        }
                        connection.receiveMessage { data, _, _, error in
                            if let error {
                                continuation.resume(throwing: error)
                                return
                            }
                            guard let data, !data.isEmpty else {
                                continuation.resume(throwing: NulConnectDNSResolverError.malformedResponse)
                                return
                            }
                            continuation.resume(returning: data)
                        }
                    })
                }
            }

            guard let result = try await group.next() else {
                throw NulConnectDNSResolverError.queryFailed("DNS query produced no result")
            }
            group.cancelAll()
            return result
        }
    }
}

private extension NulConnectDNSResolution {
    func withManagedDomain(_ isManaged: Bool) -> NulConnectDNSResolution {
        var copy = self
        copy.isManagedDomain = isManaged
        return copy
    }
}

private struct NulConnectDNSResponse {
    var ipv4Addresses: [String]
    var minimumTTL: UInt32
}

private enum NulConnectDNSMessage {
    private static let aRecordType: UInt16 = 1
    private static let internetClass: UInt16 = 1

    static func makeAQuery(domain: String) throws -> (id: UInt16, data: Data) {
        var data = Data()
        let id = UInt16.random(in: 0...UInt16.max)
        data.appendUInt16(id)
        data.appendUInt16(0x0100)
        data.appendUInt16(1)
        data.appendUInt16(0)
        data.appendUInt16(0)
        data.appendUInt16(0)
        try data.appendDNSName(domain)
        data.appendUInt16(aRecordType)
        data.appendUInt16(internetClass)
        return (id, data)
    }

    static func parseAResponse(_ data: Data, expectedID: UInt16) throws -> NulConnectDNSResponse {
        var reader = NulConnectDNSReader(data: data)
        guard
            try reader.readUInt16() == expectedID,
            data.count >= 12
        else {
            throw NulConnectDNSResolverError.malformedResponse
        }

        let flags = try reader.readUInt16()
        guard flags & 0x8000 != 0 else {
            throw NulConnectDNSResolverError.malformedResponse
        }

        let questionCount = Int(try reader.readUInt16())
        let answerCount = Int(try reader.readUInt16())
        _ = try reader.readUInt16()
        _ = try reader.readUInt16()

        for _ in 0..<questionCount {
            try reader.skipDNSName()
            _ = try reader.readUInt16()
            _ = try reader.readUInt16()
        }

        var addresses: [String] = []
        var minimumTTL = UInt32.max
        for _ in 0..<answerCount {
            try reader.skipDNSName()
            let type = try reader.readUInt16()
            let recordClass = try reader.readUInt16()
            let ttl = try reader.readUInt32()
            let length = Int(try reader.readUInt16())
            if type == aRecordType, recordClass == internetClass, length == 4 {
                let bytes = try reader.readBytes(count: 4)
                addresses.append(bytes.map(String.init).joined(separator: "."))
                minimumTTL = min(minimumTTL, ttl)
            } else {
                try reader.skipBytes(count: length)
            }
        }

        return NulConnectDNSResponse(
            ipv4Addresses: Array(Set(addresses)).sorted(),
            minimumTTL: minimumTTL == UInt32.max ? 60 : minimumTTL
        )
    }
}

private struct NulConnectDNSReader {
    private let data: Data
    private var offset = 0

    init(data: Data) {
        self.data = data
    }

    mutating func readUInt16() throws -> UInt16 {
        let bytes = try readBytes(count: 2)
        return (UInt16(bytes[0]) << 8) | UInt16(bytes[1])
    }

    mutating func readUInt32() throws -> UInt32 {
        let bytes = try readBytes(count: 4)
        return (UInt32(bytes[0]) << 24) | (UInt32(bytes[1]) << 16) | (UInt32(bytes[2]) << 8) | UInt32(bytes[3])
    }

    mutating func readBytes(count: Int) throws -> [UInt8] {
        guard count >= 0, offset + count <= data.count else {
            throw NulConnectDNSResolverError.malformedResponse
        }
        defer { offset += count }
        return Array(data[offset..<(offset + count)])
    }

    mutating func skipBytes(count: Int) throws {
        _ = try readBytes(count: count)
    }

    mutating func skipDNSName() throws {
        var jumped = false
        var cursor = offset
        var jumps = 0

        while true {
            guard cursor < data.count else {
                throw NulConnectDNSResolverError.malformedResponse
            }
            let length = data[cursor]
            if length & 0xC0 == 0xC0 {
                guard cursor + 1 < data.count else {
                    throw NulConnectDNSResolverError.malformedResponse
                }
                if !jumped {
                    offset = cursor + 2
                }
                let pointer = (Int(length & 0x3F) << 8) | Int(data[cursor + 1])
                cursor = pointer
                jumped = true
                jumps += 1
                if jumps > 16 {
                    throw NulConnectDNSResolverError.malformedResponse
                }
                continue
            }
            if length == 0 {
                if !jumped {
                    offset = cursor + 1
                }
                return
            }
            cursor += 1 + Int(length)
            guard cursor <= data.count else {
                throw NulConnectDNSResolverError.malformedResponse
            }
        }
    }
}

private struct NulConnectDomainRule: Sendable {
    private let pattern: String

    nonisolated init(pattern: String) {
        self.pattern = Self.normalize(pattern.trimmingCharacters(in: CharacterSet(charactersIn: "*")))
    }

    nonisolated func matches(_ domain: String) -> Bool {
        let normalizedDomain = Self.normalize(domain)
        if pattern.hasPrefix(".") {
            let suffix = String(pattern.dropFirst())
            return normalizedDomain == suffix || normalizedDomain.hasSuffix(".\(suffix)")
        }
        return normalizedDomain == pattern || normalizedDomain.hasSuffix(".\(pattern)")
    }

    nonisolated static func normalize(_ domain: String) -> String {
        domain.trimmingCharacters(in: CharacterSet(charactersIn: ". \n\r\t"))
            .lowercased()
    }
}

private enum NulConnectIPv4Range {
    nonisolated static func ipv4Number(_ value: String) -> UInt32? {
        var addr = in_addr()
        guard inet_pton(AF_INET, value, &addr) == 1 else {
            return nil
        }
        return UInt32(bigEndian: addr.s_addr)
    }
}

private extension Data {
    mutating func appendUInt16(_ value: UInt16) {
        append(UInt8((value >> 8) & 0xff))
        append(UInt8(value & 0xff))
    }

    mutating func appendDNSName(_ domain: String) throws {
        let labels = NulConnectDomainRule.normalize(domain).split(separator: ".")
        guard !labels.isEmpty else {
            throw NulConnectDNSResolverError.noARecords(domain)
        }
        for label in labels {
            let bytes = Array(label.utf8)
            guard bytes.count <= 63 else {
                throw NulConnectDNSResolverError.malformedResponse
            }
            append(UInt8(bytes.count))
            append(contentsOf: bytes)
        }
        append(0)
    }
}
