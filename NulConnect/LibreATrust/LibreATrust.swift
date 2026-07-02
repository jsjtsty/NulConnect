import Foundation
import Darwin

enum LibreATrustError: Error, LocalizedError {
    case invalidArgument(String)
    case parseFailed(String)
    case networkFailed(String)
    case unauthorized(String)
    case challengeRequired(String)
    case invalidState(String)
    case cryptoFailed(String)
    case notFound(String)
    case unsupported(String)
    case internalError(String)
    case unknown(code: Int32, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidArgument(let message): return message
        case .parseFailed(let message): return message
        case .networkFailed(let message): return message
        case .unauthorized(let message): return message
        case .challengeRequired(let message): return message
        case .invalidState(let message): return message
        case .cryptoFailed(let message): return message
        case .notFound(let message): return message
        case .unsupported(let message): return message
        case .internalError(let message): return message
        case .unknown(_, let message): return message
        }
    }
}

enum ATRRouteDecision: Equatable {
    case direct
    case managed
}

enum ATRAuthChallenge {
    case captcha(Data)
    case smsCode(authID: String)
    case callbackURL(url: String, kind: ATRCallbackKind)
    case done(ATRSessionMaterial)
}

enum ATRCallbackKind {
    case captcha
    case smsCode
    case callbackURL
}

struct ATRCookie: Sendable, Codable {
    var host: String
    var scheme: String
    var name: String
    var value: String
}

struct ATRSessionMaterial: Sendable, Codable {
    var username: String
    var sid: String
    var deviceID: String
    var connectionID: String
    var signKeyHex: String
    var cookies: [ATRCookie]
}

struct ATRAuthMethod: Sendable, Identifiable {
    var id: String { "\(loginDomain):\(authType)" }
    var loginDomain: String
    var authType: String
    var authName: String
    var loginURL: String
}

struct ATRClientConfiguration: Sendable {
    var serverHost: String
    var serverPort: UInt16
    var userAgent: String
    var connectTimeout: UInt64
    var ioTimeout: UInt64
    var nodeProbeTimeout: UInt64
    var allowInsecureTLS: Bool
}

struct ATRAuthConfiguration: Sendable {
    var serverHost: String
    var serverPort: UInt16
    var userAgent: String
    var clientType: String
    var platform: String
    var loginDomain: String
    var preferredAuthType: String?
    var ioTimeout: UInt64
    var allowInsecureTLS: Bool
}

struct ATRIPResource: Sendable, Codable {
    var ipMin: String
    var ipMax: String
    var portMin: UInt16
    var portMax: UInt16
    var protocolName: String
    var appID: String
    var nodeGroupID: String
}

struct ATRDomainResource: Sendable, Codable {
    var domain: String
    var portMin: UInt16
    var portMax: UInt16
    var protocolName: String
    var appID: String
    var nodeGroupID: String
}

struct ATRDNSResource: Sendable, Codable {
    var domain: String
    var ip: String
}

struct ATRNodeGroup: Sendable, Codable {
    var groupID: String
    var addresses: [String]
}

struct ATRResourceSnapshot: Sendable, Codable {
    var resourceBytes: Data
    var dnsServer: String?
    var majorNodeGroup: String
    var ipResources: [ATRIPResource]
    var domainResources: [ATRDomainResource]
    var dnsResources: [ATRDNSResource]
    var nodeGroups: [ATRNodeGroup]
    var excludedIPs: [String]
}

nonisolated final class ATRAuthSession {
    private var raw: OpaquePointer?

    init(configuration: ATRAuthConfiguration) throws {
        var session: OpaquePointer?
        try withAuthConfiguration(configuration) { config in
            var config = config
            try check(atr_auth_session_new(&config, &session))
        }
        self.raw = session
    }

    deinit {
        if let raw {
            atr_auth_session_free(raw)
        }
    }

    func availableMethods() throws -> [ATRAuthMethod] {
        try withRaw { raw in
            var list = atr_auth_method_list_t(items: nil, len: 0)
            try check(atr_auth_session_available_methods(raw, &list))
            defer { atr_auth_method_list_free(&list) }
            return decodeAuthMethods(list)
        }
    }

    func resolveLoginURL(_ loginURL: String) throws -> URL {
        try withRaw { raw in
            try withCStringValue(loginURL) { loginURLPtr in
                var resolved: UnsafeMutablePointer<CChar>?
                try check(atr_auth_session_resolve_login_url(raw, loginURLPtr, &resolved))
                defer { if let resolved { atr_string_free(resolved) } }
                guard let resolved else {
                    throw LibreATrustError.internalError("resolved login url is nil")
                }
                guard let url = URL(string: String(cString: resolved)) else {
                    throw LibreATrustError.parseFailed("failed to parse resolved login url")
                }
                return url
            }
        }
    }

    func prepareCallbackLogin(deviceID: String) throws {
        try withRaw { raw in
            try withCStringValue(deviceID) { deviceIDPtr in
                try check(atr_auth_session_prepare_callback_login(raw, deviceIDPtr))
            }
        }
    }

    func completeCallback(_ callbackURL: URL) throws -> ATRAuthChallenge {
        try withRaw { raw in
            try withCStringValue(callbackURL.absoluteString) { callbackPtr in
                var challenge = makeEmptyChallenge()
                var target = atr_callback_target_t(callback_url: callbackPtr)
                try check(atr_auth_session_complete_callback(raw, &target, &challenge))
                defer { atr_auth_challenge_free(&challenge) }
                return decodeChallenge(challenge)
            }
        }
    }

    func completeCallback(_ callbackURL: URL, deviceID: String) throws -> ATRAuthChallenge {
        try withRaw { raw in
            try withCStringValue(callbackURL.absoluteString) { callbackPtr in
                try withCStringValue(deviceID) { deviceIDPtr in
                    var challenge = makeEmptyChallenge()
                    var target = atr_callback_target_t(callback_url: callbackPtr)
                    try check(atr_auth_session_complete_callback_with_device(raw, &target, deviceIDPtr, &challenge))
                    defer { atr_auth_challenge_free(&challenge) }
                    return decodeChallenge(challenge)
                }
            }
        }
    }

    func exportSession() throws -> ATRSessionMaterial {
        try withRaw { raw in
            var material = makeEmptySessionMaterial()
            try check(atr_auth_session_export_session(raw, &material))
            defer { atr_session_material_free(&material) }
            return decodeSessionMaterial(material)
        }
    }

    func resumeSession(_ material: ATRSessionMaterial) throws -> ATRSessionMaterial {
        try withRaw { raw in
            try withSessionMaterialInput(material) { input in
                var input = input
                var output = makeEmptySessionMaterial()
                try check(atr_auth_session_resume_session(raw, &input, &output))
                defer { atr_session_material_free(&output) }
                return decodeSessionMaterial(output)
            }
        }
    }

    func fetchClientResource() throws -> Data {
        try withRaw { raw in
            var blob = atr_blob_t(data: nil, len: 0)
            try check(atr_auth_session_fetch_client_resource(raw, &blob))
            defer { atr_blob_free(&blob) }
            return data(from: blob)
        }
    }

    private func withRaw<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        guard let raw else {
            throw LibreATrustError.invalidState("auth session is released")
        }
        return try body(raw)
    }
}

nonisolated final class ATRClient {
    private var raw: OpaquePointer?

    init(configuration: ATRClientConfiguration) throws {
        var client: OpaquePointer?
        try withClientConfiguration(configuration) { config in
            var config = config
            try check(atr_client_new(&config, &client))
        }
        self.raw = client
    }

    deinit {
        if let raw {
            atr_client_free(raw)
        }
    }

    func setSession(_ material: ATRSessionMaterial) throws {
        try withRaw { raw in
            try withSessionMaterialInput(material) { input in
                var input = input
                try check(atr_client_set_session(raw, &input))
            }
        }
    }

    func setResource(_ data: Data, serviceHost: String) throws {
        try withRaw { raw in
            try withCStringValue(serviceHost) { serviceHostPtr in
                try data.withUnsafeBytes { bytes in
                    guard let baseAddress = bytes.bindMemory(to: UInt8.self).baseAddress else {
                        throw LibreATrustError.invalidArgument("resource bytes are empty")
                    }
                    try check(atr_client_set_resource(raw, baseAddress, data.count, serviceHostPtr))
                }
            }
        }
    }

    func routeTCP(host: String, port: UInt16) throws -> ATRRouteDecision {
        try withRaw { raw in
            try withCStringValue(host) { hostPtr in
                var managed = false
                try check(atr_client_route_tcp(raw, hostPtr, port, &managed))
                return managed ? .managed : .direct
            }
        }
    }

    func routeUDP(host: String, port: UInt16) throws -> ATRRouteDecision {
        try withRaw { raw in
            try withCStringValue(host) { hostPtr in
                var managed = false
                try check(atr_client_route_udp(raw, hostPtr, port, &managed))
                return managed ? .managed : .direct
            }
        }
    }

    func routeICMP(host: String) throws -> ATRRouteDecision {
        try withRaw { raw in
            try withCStringValue(host) { hostPtr in
                var managed = false
                try check(atr_client_route_icmp(raw, hostPtr, &managed))
                return managed ? .managed : .direct
            }
        }
    }

    func resourceSnapshot() throws -> ATRResourceSnapshot {
        try withRaw { raw in
            var snapshot = makeEmptyResourceSnapshot()
            try check(atr_client_get_resource_snapshot(raw, &snapshot))
            defer { atr_resource_snapshot_free(&snapshot) }
            return decodeResourceSnapshot(snapshot)
        }
    }

    func openTCP(host: String, port: UInt16) throws -> ATRTcpTunnel {
        try withRaw { raw in
            try withCStringValue(host) { hostPtr in
                var tunnel: OpaquePointer?
                try check(atr_client_open_tcp(raw, hostPtr, port, &tunnel))
                guard let tunnel else {
                    throw LibreATrustError.internalError("tcp tunnel is nil")
                }
                return ATRTcpTunnel(raw: tunnel)
            }
        }
    }

    func openUDP(host: String, port: UInt16) throws -> ATRUdpTunnel {
        try withRaw { raw in
            try withCStringValue(host) { hostPtr in
                var tunnel: OpaquePointer?
                try check(atr_client_open_udp(raw, hostPtr, port, &tunnel))
                guard let tunnel else {
                    throw LibreATrustError.internalError("udp tunnel is nil")
                }
                return ATRUdpTunnel(raw: tunnel)
            }
        }
    }

    func openL3() throws -> ATRL3Tunnel {
        try withRaw { raw in
            var tunnel: OpaquePointer?
            try check(atr_client_open_l3(raw, &tunnel))
            guard let tunnel else {
                throw LibreATrustError.internalError("l3 tunnel is nil")
            }
            return ATRL3Tunnel(raw: tunnel)
        }
    }

    private func withRaw<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        guard let raw else {
            throw LibreATrustError.invalidState("client is released")
        }
        return try body(raw)
    }
}

nonisolated final class ATRTcpTunnel {
    private var raw: OpaquePointer?

    init(raw: OpaquePointer) {
        self.raw = raw
    }

    deinit {
        if let raw {
            atr_tcp_tunnel_free(raw)
        }
    }

    func close() throws {
        try withRaw { raw in
            try check(atr_tcp_tunnel_close(raw))
        }
    }

    func read(maxLength: Int = 16 * 1024) throws -> Data {
        try withRaw { raw in
            var buffer = [UInt8](repeating: 0, count: maxLength)
            var outLen: Int = 0
            let status = buffer.withUnsafeMutableBufferPointer { ptr in
                atr_tcp_tunnel_read(raw, ptr.baseAddress, ptr.count, &outLen)
            }
            try check(status)
            return Data(buffer.prefix(outLen))
        }
    }

    func write(_ data: Data) throws -> Int {
        try withRaw { raw in
            try data.withUnsafeBytes { bytes in
                guard let baseAddress = bytes.bindMemory(to: UInt8.self).baseAddress else {
                    throw LibreATrustError.invalidArgument("write buffer is empty")
                }
                var outLen: Int = 0
                try check(atr_tcp_tunnel_write(raw, baseAddress, data.count, &outLen))
                return outLen
            }
        }
    }

    private func withRaw<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        guard let raw else {
            throw LibreATrustError.invalidState("tcp tunnel is released")
        }
        return try body(raw)
    }
}

nonisolated final class ATRUdpTunnel {
    private var raw: OpaquePointer?

    init(raw: OpaquePointer) {
        self.raw = raw
    }

    deinit {
        if let raw {
            atr_udp_tunnel_free(raw)
        }
    }

    func close() throws {
        try withRaw { raw in
            try check(atr_udp_tunnel_close(raw))
        }
    }

    func read(maxLength: Int = 64 * 1024) throws -> Data {
        try withRaw { raw in
            var buffer = [UInt8](repeating: 0, count: maxLength)
            var outLen: Int = 0
            let status = buffer.withUnsafeMutableBufferPointer { ptr in
                atr_udp_tunnel_read(raw, ptr.baseAddress, ptr.count, &outLen)
            }
            try check(status)
            return Data(buffer.prefix(outLen))
        }
    }

    func write(_ data: Data) throws -> Int {
        try withRaw { raw in
            try data.withUnsafeBytes { bytes in
                guard let baseAddress = bytes.bindMemory(to: UInt8.self).baseAddress else {
                    throw LibreATrustError.invalidArgument("write buffer is empty")
                }
                var outLen: Int = 0
                try check(atr_udp_tunnel_write(raw, baseAddress, data.count, &outLen))
                return outLen
            }
        }
    }

    private func withRaw<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        guard let raw else {
            throw LibreATrustError.invalidState("udp tunnel is released")
        }
        return try body(raw)
    }
}

nonisolated final class ATRL3Tunnel {
    private var raw: OpaquePointer?

    init(raw: OpaquePointer) {
        self.raw = raw
    }

    deinit {
        if let raw {
            atr_l3_tunnel_free(raw)
        }
    }

    func virtualIPs() throws -> [String] {
        try withRaw { raw in
            var list = atr_string_list_t(items: nil, len: 0)
            try check(atr_l3_tunnel_get_virtual_ips(raw, &list))
            defer { atr_string_list_free(&list) }
            return decodeStringList(list)
        }
    }

    func readPacket(maxLength: Int = 65_535) throws -> Data {
        try withRaw { raw in
            var buffer = [UInt8](repeating: 0, count: maxLength)
            var outLen: Int = 0
            let status = buffer.withUnsafeMutableBufferPointer { ptr in
                atr_l3_tunnel_read_packet(raw, ptr.baseAddress, ptr.count, &outLen)
            }
            try check(status)
            return Data(buffer.prefix(outLen))
        }
    }

    func writePacket(_ packet: Data) throws -> Int {
        try withRaw { raw in
            try packet.withUnsafeBytes { bytes in
                guard let baseAddress = bytes.bindMemory(to: UInt8.self).baseAddress else {
                    throw LibreATrustError.invalidArgument("packet is empty")
                }
                var outLen: Int = 0
                try check(atr_l3_tunnel_write_packet(raw, baseAddress, packet.count, &outLen))
                return outLen
            }
        }
    }

    private func withRaw<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        guard let raw else {
            throw LibreATrustError.invalidState("l3 tunnel is released")
        }
        return try body(raw)
    }
}

// MARK: - C Helpers

private nonisolated final class CStringOwner {
    let pointer: UnsafeMutablePointer<CChar>

    init(_ string: String) throws {
        guard let pointer = string.withCString({ strdup($0) }) else {
            throw LibreATrustError.internalError("failed to allocate c string")
        }
        self.pointer = pointer
    }

    deinit {
        free(pointer)
    }
}

private nonisolated struct CookieCInputBuffer {
    let host: CStringOwner
    let scheme: CStringOwner
    let name: CStringOwner
    let value: CStringOwner

    var input: atr_cookie_input_t {
        atr_cookie_input_t(
            host: host.pointer,
            scheme: scheme.pointer,
            name: name.pointer,
            value: value.pointer
        )
    }
}

private nonisolated func check(_ code: Int32) throws {
    guard code == 0 else {
        let message = lastErrorMessage()
        switch code {
        case 1: throw LibreATrustError.invalidArgument(message)
        case 2: throw LibreATrustError.parseFailed(message)
        case 3: throw LibreATrustError.networkFailed(message)
        case 4: throw LibreATrustError.unauthorized(message)
        case 5: throw LibreATrustError.challengeRequired(message)
        case 6: throw LibreATrustError.invalidState(message)
        case 7: throw LibreATrustError.cryptoFailed(message)
        case 8: throw LibreATrustError.notFound(message)
        case 9: throw LibreATrustError.unsupported(message)
        default: throw LibreATrustError.internalError(message.isEmpty ? "unknown libreatrust error" : message)
        }
    }
}

private nonisolated func lastErrorMessage() -> String {
    guard let message = atr_last_error_message() else {
        return ""
    }
    return String(cString: message)
}

private nonisolated func optionalCStringString(_ pointer: UnsafePointer<CChar>?) -> String? {
    guard let pointer else {
        return nil
    }
    return String(cString: pointer)
}

private nonisolated func withCStringValue<T>(_ string: String, _ body: (UnsafePointer<CChar>) throws -> T) rethrows -> T {
    try string.withCString { try body($0) }
}

private nonisolated func withOptionalCStringValue<T>(_ string: String?, _ body: (UnsafePointer<CChar>?) throws -> T) rethrows -> T {
    if let string {
        return try withCStringValue(string) { try body($0) }
    }
    return try body(nil)
}

private nonisolated func withClientConfiguration<T>(_ configuration: ATRClientConfiguration, _ body: (atr_client_config_t) throws -> T) throws -> T {
    try withCStringValue(configuration.serverHost) { serverHost in
        try withCStringValue(configuration.userAgent) { userAgent in
            let config = atr_client_config_t(
                server_host: serverHost,
                server_port: configuration.serverPort,
                user_agent: userAgent,
                connect_timeout_ms: configuration.connectTimeout,
                io_timeout_ms: configuration.ioTimeout,
                node_probe_timeout_ms: configuration.nodeProbeTimeout,
                allow_insecure_tls: configuration.allowInsecureTLS
            )
            return try body(config)
        }
    }
}

private nonisolated func withAuthConfiguration<T>(_ configuration: ATRAuthConfiguration, _ body: (atr_auth_config_t) throws -> T) throws -> T {
    try withCStringValue(configuration.serverHost) { serverHost in
        try withCStringValue(configuration.userAgent) { userAgent in
            try withCStringValue(configuration.clientType) { clientType in
                try withCStringValue(configuration.platform) { platform in
                    try withCStringValue(configuration.loginDomain) { loginDomain in
                        try withOptionalCStringValue(configuration.preferredAuthType) { preferredAuthType in
                            let config = atr_auth_config_t(
                                server_host: serverHost,
                                server_port: configuration.serverPort,
                                user_agent: userAgent,
                                client_type: clientType,
                                platform: platform,
                                login_domain: loginDomain,
                                preferred_auth_type: preferredAuthType,
                                io_timeout_ms: configuration.ioTimeout,
                                allow_insecure_tls: configuration.allowInsecureTLS
                            )
                            return try body(config)
                        }
                    }
                }
            }
        }
    }
}

private nonisolated func withSessionMaterialInput<T>(_ material: ATRSessionMaterial, _ body: (atr_session_material_input_t) throws -> T) throws -> T {
    let cookies = try material.cookies.map { cookie in
        try CookieCInputBuffer(
            host: CStringOwner(cookie.host),
            scheme: CStringOwner(cookie.scheme),
            name: CStringOwner(cookie.name),
            value: CStringOwner(cookie.value)
        )
    }

    return try withCStringValue(material.username) { username in
        try withCStringValue(material.sid) { sid in
            try withCStringValue(material.deviceID) { deviceID in
                try withCStringValue(material.connectionID) { connectionID in
                    try withCStringValue(material.signKeyHex) { signKeyHex in
                        var inputs = cookies.map { $0.input }
                        return try inputs.withUnsafeMutableBufferPointer { pointer in
                            let input = atr_session_material_input_t(
                                username: username,
                                sid: sid,
                                device_id: deviceID,
                                connection_id: connectionID,
                                sign_key_hex: signKeyHex,
                                cookies: atr_cookie_list_input_t(items: pointer.baseAddress, len: pointer.count)
                            )
                            return try body(input)
                        }
                    }
                }
            }
        }
    }
}

private nonisolated func decodeAuthMethods(_ list: atr_auth_method_list_t) -> [ATRAuthMethod] {
    guard let items = list.items, list.len > 0 else {
        return []
    }
    let buffer = UnsafeBufferPointer(start: items, count: list.len)
    return buffer.map { item in
        ATRAuthMethod(
            loginDomain: String(cString: item.login_domain),
            authType: String(cString: item.auth_type),
            authName: String(cString: item.auth_name),
            loginURL: String(cString: item.login_url)
        )
    }
}

private nonisolated func decodeSessionMaterial(_ material: atr_session_material_t) -> ATRSessionMaterial {
    ATRSessionMaterial(
        username: String(cString: material.username),
        sid: String(cString: material.sid),
        deviceID: String(cString: material.device_id),
        connectionID: String(cString: material.connection_id),
        signKeyHex: String(cString: material.sign_key_hex),
        cookies: decodeCookies(material.cookies)
    )
}

private nonisolated func decodeCookies(_ list: atr_cookie_list_t) -> [ATRCookie] {
    guard let items = list.items, list.len > 0 else {
        return []
    }
    let buffer = UnsafeBufferPointer(start: items, count: list.len)
    return buffer.map { item in
        ATRCookie(
            host: String(cString: item.host),
            scheme: String(cString: item.scheme),
            name: String(cString: item.name),
            value: String(cString: item.value)
        )
    }
}

private nonisolated func decodeChallenge(_ challenge: atr_auth_challenge_t) -> ATRAuthChallenge {
    switch challenge.kind {
    case ATR_AUTH_CHALLENGE_CAPTCHA:
        return .captcha(data(from: challenge.image))
    case ATR_AUTH_CHALLENGE_SMS_CODE:
        return .smsCode(authID: String(cString: challenge.auth_id))
    case ATR_AUTH_CHALLENGE_CALLBACK_URL:
        let kind: ATRCallbackKind
        switch challenge.callback_kind {
        case ATR_AUTH_CHALLENGE_CAPTCHA:
            kind = .captcha
        case ATR_AUTH_CHALLENGE_SMS_CODE:
            kind = .smsCode
        default:
            kind = .callbackURL
        }
        return .callbackURL(url: String(cString: challenge.auth_url), kind: kind)
    default:
        return .done(decodeSessionMaterial(challenge.session))
    }
}

private nonisolated func data(from blob: atr_blob_t) -> Data {
    guard let data = blob.data, blob.len > 0 else {
        return Data()
    }
    return Data(bytes: data, count: blob.len)
}

private nonisolated func decodeStringList(_ list: atr_string_list_t) -> [String] {
    guard let items = list.items, list.len > 0 else {
        return []
    }
    let buffer = UnsafeBufferPointer(start: items, count: list.len)
    return buffer.map { String(cString: $0!) }
}

private nonisolated func decodeResourceSnapshot(_ snapshot: atr_resource_snapshot_t) -> ATRResourceSnapshot {
    let ipResources = decodeIPResources(snapshot.ip_resources)
    let domainResources = decodeDomainResources(snapshot.domain_resources)
    let dnsResources = decodeDNSResources(snapshot.dns_resources)
    let nodeGroups = decodeNodeGroups(snapshot.node_groups)
    let excludedIPs = decodeStringList(snapshot.excluded_ips)

    return ATRResourceSnapshot(
        resourceBytes: data(from: snapshot.resource_bytes),
        dnsServer: optionalCStringString(snapshot.dns_server),
        majorNodeGroup: String(cString: snapshot.major_node_group),
        ipResources: ipResources,
        domainResources: domainResources,
        dnsResources: dnsResources,
        nodeGroups: nodeGroups,
        excludedIPs: excludedIPs
    )
}

private nonisolated func decodeIPResources(_ list: atr_ip_resource_list_t) -> [ATRIPResource] {
    guard let items = list.items, list.len > 0 else {
        return []
    }
    let buffer = UnsafeBufferPointer(start: items, count: list.len)
    return buffer.map { item in
        ATRIPResource(
            ipMin: String(cString: item.ip_min),
            ipMax: String(cString: item.ip_max),
            portMin: item.port_min,
            portMax: item.port_max,
            protocolName: String(cString: item.protocol),
            appID: String(cString: item.app_id),
            nodeGroupID: String(cString: item.node_group_id)
        )
    }
}

private nonisolated func decodeDomainResources(_ list: atr_domain_resource_list_t) -> [ATRDomainResource] {
    guard let items = list.items, list.len > 0 else {
        return []
    }
    let buffer = UnsafeBufferPointer(start: items, count: list.len)
    return buffer.map { item in
        ATRDomainResource(
            domain: String(cString: item.domain),
            portMin: item.port_min,
            portMax: item.port_max,
            protocolName: String(cString: item.protocol),
            appID: String(cString: item.app_id),
            nodeGroupID: String(cString: item.node_group_id)
        )
    }
}

private nonisolated func decodeDNSResources(_ list: atr_dns_resource_list_t) -> [ATRDNSResource] {
    guard let items = list.items, list.len > 0 else {
        return []
    }
    let buffer = UnsafeBufferPointer(start: items, count: list.len)
    return buffer.map { item in
        ATRDNSResource(
            domain: String(cString: item.domain),
            ip: String(cString: item.ip)
        )
    }
}

private nonisolated func decodeNodeGroups(_ list: atr_node_group_list_t) -> [ATRNodeGroup] {
    guard let items = list.items, list.len > 0 else {
        return []
    }
    let buffer = UnsafeBufferPointer(start: items, count: list.len)
    return buffer.map { item in
        ATRNodeGroup(
            groupID: String(cString: item.group_id),
            addresses: decodeStringList(item.addresses)
        )
    }
}

private nonisolated func makeEmptyChallenge() -> atr_auth_challenge_t {
    atr_auth_challenge_t(
        kind: ATR_AUTH_CHALLENGE_DONE,
        image: atr_blob_t(data: nil, len: 0),
        auth_id: nil,
        auth_url: nil,
        callback_kind: ATR_AUTH_CHALLENGE_DONE,
        session: makeEmptySessionMaterial()
    )
}

private nonisolated func makeEmptySessionMaterial() -> atr_session_material_t {
    atr_session_material_t(
        username: nil,
        sid: nil,
        device_id: nil,
        connection_id: nil,
        sign_key_hex: nil,
        cookies: atr_cookie_list_t(items: nil, len: 0)
    )
}

private nonisolated func makeEmptyResourceSnapshot() -> atr_resource_snapshot_t {
    atr_resource_snapshot_t(
        resource_bytes: atr_blob_t(data: nil, len: 0),
        dns_server: nil,
        major_node_group: nil,
        ip_resources: atr_ip_resource_list_t(items: nil, len: 0),
        domain_resources: atr_domain_resource_list_t(items: nil, len: 0),
        dns_resources: atr_dns_resource_list_t(items: nil, len: 0),
        node_groups: atr_node_group_list_t(items: nil, len: 0),
        excluded_ips: atr_string_list_t(items: nil, len: 0)
    )
}
