import Foundation
import NetworkExtension
import Darwin

final class PacketTunnelProvider: NEPacketTunnelProvider {
    private var configuration: NulConnectTunnelLaunchConfiguration?
    private var client: ATRClient?
    private var l3Tunnel: ATRL3Tunnel?
    private var dnsResolver: NulConnectDNSResolver?
    private var packetTask: Task<Void, Never>?
    private var l3ReadTask: Task<Void, Never>?
    private var virtualAddress = "10.255.0.2"
    private var dynamicManagedIPs = Set<String>()
    private let routeLock = NSLock()

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        Task.detached { [weak self] in
            guard let self else { return }
            do {
                try await self.start()
                completionHandler(nil)
            } catch {
                completionHandler(error)
            }
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        packetTask?.cancel()
        l3ReadTask?.cancel()
        packetTask = nil
        l3ReadTask = nil
        l3Tunnel = nil
        client = nil
        completionHandler()
    }

    private func start() async throws {
        let configuration = try NulConnectTunnelSharedStore.load()
        let runtimeProfile = configuration.profile.normalizedForHITAuth()
        let clientConfiguration = ATRClientConfiguration(
            serverHost: runtimeProfile.serverHost,
            serverPort: runtimeProfile.serverPort,
            userAgent: runtimeProfile.userAgent,
            connectTimeout: runtimeProfile.connectTimeoutMillis,
            ioTimeout: runtimeProfile.ioTimeoutMillis,
            nodeProbeTimeout: runtimeProfile.nodeProbeTimeoutMillis,
            allowInsecureTLS: runtimeProfile.allowInsecureTLS
        )
        let client = try ATRClient(configuration: clientConfiguration)
        try client.setSession(configuration.session)
        try client.setResource(configuration.resource.resourceBytes, serviceHost: runtimeProfile.serverHost)
        let tunnel = try client.openL3()
        if let address = try tunnel.virtualIPs().first, !address.isEmpty {
            virtualAddress = address
        }

        self.configuration = configuration
        self.client = client
        self.l3Tunnel = tunnel
        self.dnsResolver = NulConnectDNSResolver(resource: configuration.resource)

        try await applyNetworkSettings()
        startPacketLoop()
        startL3ReadLoop(tunnel)
    }

    private func startPacketLoop() {
        packetTask?.cancel()
        packetTask = Task.detached(priority: .high) { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let packets = await self.readPackets()
                for (packet, protocolNumber) in packets {
                    guard protocolNumber.int32Value == AF_INET else {
                        continue
                    }
                    await self.handleIPv4Packet(packet)
                }
            }
        }
    }

    private func startL3ReadLoop(_ tunnel: ATRL3Tunnel) {
        l3ReadTask?.cancel()
        l3ReadTask = Task.detached(priority: .high) { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    let packet = try tunnel.readPacket()
                    if !packet.isEmpty {
                        self.packetFlow.writePackets([packet], withProtocols: [NSNumber(value: AF_INET)])
                    }
                } catch is CancellationError {
                    return
                } catch {
                    return
                }
            }
        }
    }

    private func readPackets() async -> [(Data, NSNumber)] {
        await withCheckedContinuation { continuation in
            packetFlow.readPackets { packets, protocols in
                continuation.resume(returning: Array(zip(packets, protocols)))
            }
        }
    }

    private func handleIPv4Packet(_ packet: Data) async {
        if let query = NulConnectIPv4DNSQuery(packet: packet), query.destinationPort == 53 {
            await handleDNSQuery(query)
            return
        }

        do {
            _ = try l3Tunnel?.writePacket(packet)
        } catch {
            cancelTunnelWithError(error)
        }
    }

    private func handleDNSQuery(_ query: NulConnectIPv4DNSQuery) async {
        guard let dnsResolver, let request = NulConnectDNSQueryRequest(payload: query.payload) else {
            forwardToL3(query.packet)
            return
        }

        do {
            let resolution = try await dnsResolver.resolveARecords(for: request.domain)
            if resolution.isManagedDomain {
                await addDynamicManagedRoutes(for: resolution.ipv4Addresses)
            }
            let response = request.responsePayload(addresses: resolution.ipv4Addresses)
            let packet = query.responsePacket(payload: response)
            packetFlow.writePackets([packet], withProtocols: [NSNumber(value: AF_INET)])
        } catch {
            let response = request.responsePayload(addresses: [], responseCode: 3)
            let packet = query.responsePacket(payload: response)
            packetFlow.writePackets([packet], withProtocols: [NSNumber(value: AF_INET)])
        }
    }

    private func forwardToL3(_ packet: Data) {
        do {
            _ = try l3Tunnel?.writePacket(packet)
        } catch {
            cancelTunnelWithError(error)
        }
    }

    private func addDynamicManagedRoutes(for addresses: [String]) async {
        let newAddresses = addresses.filter { address in
            routeLock.lock()
            let inserted = dynamicManagedIPs.insert(address).inserted
            routeLock.unlock()
            return inserted
        }
        guard !newAddresses.isEmpty else {
            return
        }
        do {
            try await applyNetworkSettings()
        } catch {
            cancelTunnelWithError(error)
        }
    }

    private func applyNetworkSettings() async throws {
        guard let configuration else {
            return
        }

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: configuration.profile.serverHost)
        settings.mtu = 1400

        let ipv4 = NEIPv4Settings(addresses: [virtualAddress], subnetMasks: ["255.255.255.255"])
        ipv4.includedRoutes = includedIPv4Routes(resource: configuration.resource)
        ipv4.includedRoutes?.append(contentsOf: dynamicIPv4Routes())
        settings.ipv4Settings = ipv4

        let dns = NEDNSSettings(servers: [virtualAddress])
        dns.matchDomains = [""]
        settings.dnsSettings = dns

        try await setTunnelNetworkSettings(settings)
    }

    private func includedIPv4Routes(resource: ATRResourceSnapshot) -> [NEIPv4Route] {
        var routes: [NEIPv4Route] = []
        for item in resource.ipResources where item.protocolName == "all" || item.protocolName == "tcp" || item.protocolName == "udp" {
            routes.append(contentsOf: NulConnectCIDRConverter.routes(from: item.ipMin, to: item.ipMax))
        }
        return routes
    }

    private func dynamicIPv4Routes() -> [NEIPv4Route] {
        routeLock.lock()
        let addresses = Array(dynamicManagedIPs)
        routeLock.unlock()
        return addresses.map { NEIPv4Route(destinationAddress: $0, subnetMask: "255.255.255.255") }
    }
}

private struct NulConnectIPv4DNSQuery {
    let packet: Data
    let sourceAddress: [UInt8]
    let destinationAddress: [UInt8]
    let sourcePort: UInt16
    let destinationPort: UInt16
    let payload: Data

    init?(packet: Data) {
        guard packet.count >= 28 else { return nil }
        let version = packet[0] >> 4
        guard version == 4 else { return nil }
        let headerLength = Int(packet[0] & 0x0f) * 4
        guard headerLength >= 20, packet.count >= headerLength + 8 else { return nil }
        guard packet[9] == 17 else { return nil }
        let udpOffset = headerLength
        let udpLength = Int(packet.uint16(at: udpOffset + 4))
        guard udpLength >= 8, packet.count >= udpOffset + udpLength else { return nil }

        self.packet = packet
        self.sourceAddress = Array(packet[12..<16])
        self.destinationAddress = Array(packet[16..<20])
        self.sourcePort = packet.uint16(at: udpOffset)
        self.destinationPort = packet.uint16(at: udpOffset + 2)
        self.payload = packet.subdata(in: (udpOffset + 8)..<(udpOffset + udpLength))
    }

    func responsePacket(payload: Data) -> Data {
        let ipHeaderLength = 20
        let udpHeaderLength = 8
        let totalLength = ipHeaderLength + udpHeaderLength + payload.count
        var bytes = [UInt8](repeating: 0, count: totalLength)
        bytes[0] = 0x45
        bytes[1] = 0
        bytes.writeUInt16(UInt16(totalLength), at: 2)
        bytes.writeUInt16(0, at: 4)
        bytes.writeUInt16(0, at: 6)
        bytes[8] = 64
        bytes[9] = 17
        bytes.replaceSubrange(12..<16, with: destinationAddress)
        bytes.replaceSubrange(16..<20, with: sourceAddress)
        bytes.writeUInt16(NulConnectChecksum.ipv4Header(bytes[0..<20]), at: 10)

        let udpOffset = 20
        bytes.writeUInt16(destinationPort, at: udpOffset)
        bytes.writeUInt16(sourcePort, at: udpOffset + 2)
        bytes.writeUInt16(UInt16(udpHeaderLength + payload.count), at: udpOffset + 4)
        bytes.writeUInt16(0, at: udpOffset + 6)
        bytes.replaceSubrange((udpOffset + 8)..<bytes.count, with: payload)
        return Data(bytes)
    }
}

private struct NulConnectDNSQueryRequest {
    let id: UInt16
    let flags: UInt16
    let question: Data
    let domain: String
    let qtype: UInt16
    let qclass: UInt16

    init?(payload: Data) {
        guard payload.count >= 12 else { return nil }
        let qdCount = payload.uint16(at: 4)
        guard qdCount > 0 else { return nil }
        var offset = 12
        var labels: [String] = []
        while offset < payload.count {
            let length = Int(payload[offset])
            offset += 1
            if length == 0 {
                break
            }
            guard length < 64, offset + length <= payload.count else { return nil }
            labels.append(String(decoding: payload[offset..<(offset + length)], as: UTF8.self))
            offset += length
        }
        guard offset + 4 <= payload.count else { return nil }
        self.id = payload.uint16(at: 0)
        self.flags = payload.uint16(at: 2)
        self.question = payload.subdata(in: 12..<(offset + 4))
        self.domain = labels.joined(separator: ".")
        self.qtype = payload.uint16(at: offset)
        self.qclass = payload.uint16(at: offset + 2)
    }

    func responsePayload(addresses: [String], responseCode: UInt16 = 0) -> Data {
        let aRecords = qtype == 1 ? addresses.compactMap { NulConnectIPv4Address.bytes($0) } : []
        var data = Data()
        data.appendUInt16(id)
        data.appendUInt16(0x8000 | 0x0400 | (flags & 0x0100) | (responseCode & 0x000f))
        data.appendUInt16(1)
        data.appendUInt16(UInt16(aRecords.count))
        data.appendUInt16(0)
        data.appendUInt16(0)
        data.append(question)

        for record in aRecords {
            data.appendUInt16(0xc00c)
            data.appendUInt16(1)
            data.appendUInt16(qclass)
            data.appendUInt32(60)
            data.appendUInt16(4)
            data.append(contentsOf: record)
        }
        return data
    }
}

private enum NulConnectCIDRConverter {
    static func routes(from start: String, to end: String) -> [NEIPv4Route] {
        guard var startValue = NulConnectIPv4Address.value(start),
              let endValue = NulConnectIPv4Address.value(end),
              startValue <= endValue else {
            return []
        }

        var routes: [NEIPv4Route] = []
        while startValue <= endValue {
            let maxBlock = startValue == 0 ? UInt32.max : startValue & (~startValue + 1)
            var block = maxBlock
            while block > 1 && startValue + block - 1 > endValue {
                block >>= 1
            }
            let prefix = 32 - Int(log2(Double(block)))
            routes.append(NEIPv4Route(
                destinationAddress: NulConnectIPv4Address.string(startValue),
                subnetMask: NulConnectIPv4Address.mask(prefixLength: prefix)
            ))
            if block == UInt32.max {
                break
            }
            startValue += block
        }
        return routes
    }
}

private enum NulConnectIPv4Address {
    static func value(_ string: String) -> UInt32? {
        let parts = string.split(separator: ".")
        guard parts.count == 4 else { return nil }
        var value: UInt32 = 0
        for part in parts {
            guard let byte = UInt8(part) else { return nil }
            value = (value << 8) | UInt32(byte)
        }
        return value
    }

    static func bytes(_ string: String) -> [UInt8]? {
        let parts = string.split(separator: ".")
        guard parts.count == 4 else { return nil }
        var bytes: [UInt8] = []
        for part in parts {
            guard let byte = UInt8(part) else { return nil }
            bytes.append(byte)
        }
        return bytes
    }

    static func string(_ value: UInt32) -> String {
        [
            String((value >> 24) & 0xff),
            String((value >> 16) & 0xff),
            String((value >> 8) & 0xff),
            String(value & 0xff)
        ].joined(separator: ".")
    }

    static func mask(prefixLength: Int) -> String {
        guard prefixLength > 0 else { return "0.0.0.0" }
        let value = UInt32.max << UInt32(32 - prefixLength)
        return string(value)
    }
}

private enum NulConnectChecksum {
    static func ipv4Header(_ bytes: ArraySlice<UInt8>) -> UInt16 {
        var sum: UInt32 = 0
        var iterator = bytes.makeIterator()
        while let high = iterator.next() {
            let low = iterator.next() ?? 0
            sum += UInt32(high) << 8 | UInt32(low)
        }
        while (sum >> 16) != 0 {
            sum = (sum & 0xffff) + (sum >> 16)
        }
        return UInt16(~sum & 0xffff)
    }
}

private extension Data {
    func uint16(at offset: Int) -> UInt16 {
        (UInt16(self[offset]) << 8) | UInt16(self[offset + 1])
    }

    mutating func appendUInt16(_ value: UInt16) {
        append(UInt8((value >> 8) & 0xff))
        append(UInt8(value & 0xff))
    }

    mutating func appendUInt32(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xff))
        append(UInt8((value >> 16) & 0xff))
        append(UInt8((value >> 8) & 0xff))
        append(UInt8(value & 0xff))
    }
}

private extension Array where Element == UInt8 {
    mutating func writeUInt16(_ value: UInt16, at offset: Int) {
        self[offset] = UInt8((value >> 8) & 0xff)
        self[offset + 1] = UInt8(value & 0xff)
    }
}
