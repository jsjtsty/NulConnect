import Foundation

nonisolated struct NulConnectSystemProxySnapshot: Codable, Sendable {
    nonisolated struct Service: Codable, Sendable {
        var name: String
        var webProxy: ProxySetting
        var secureWebProxy: ProxySetting
        var socksProxy: ProxySetting
        var proxyAutoDiscoveryEnabled: Bool
        var autoProxyURL: AutoProxyURL?
        var bypassDomains: [String]
    }

    nonisolated struct ProxySetting: Codable, Sendable {
        var enabled: Bool
        var server: String?
        var port: UInt16?
        var authenticated: Bool
        var username: String?
    }

    nonisolated struct AutoProxyURL: Codable, Sendable {
        var enabled: Bool
        var url: String?
    }

    var savedAt: Date
    var services: [Service]
}

nonisolated enum NulConnectSystemProxyManagerError: LocalizedError {
    case networkSetupUnavailable
    case noNetworkServices
    case privilegedExecutionFailed(String)
    case snapshotDecodingFailed(String)

    var errorDescription: String? {
        switch self {
        case .networkSetupUnavailable:
            return "系统代理工具不可用"
        case .noNetworkServices:
            return "没有可配置的网络服务"
        case .privilegedExecutionFailed(let message):
            return "系统代理需要管理员权限: \(message)"
        case .snapshotDecodingFailed(let message):
            return "系统代理快照解析失败: \(message)"
        }
    }
}

nonisolated final class NulConnectSystemProxyManager: @unchecked Sendable {
    private let snapshotURL: URL
    private let helperClient = NulConnectHelperClient()

    init(baseDirectory: URL? = nil) throws {
        let root = try NulConnectStorageDirectory.rootDirectory(override: baseDirectory)
        self.snapshotURL = root.appendingPathComponent("system-proxy-snapshot.json", isDirectory: false)
    }

    func hasSnapshot() -> Bool {
        FileManager.default.fileExists(atPath: snapshotURL.path)
    }

    func enable(
        endpoint: NulConnectProxyEndpoint,
        serverHost: String,
        helperActivityReporter: NulConnectHelperClient.ActivityReporter? = nil
    ) async throws -> Int {
        print("[NulConnect][SystemProxy] enable: endpoint=\(endpoint.host):\(endpoint.port), server=\(serverHost)")
        let helperRequiresInstallOrUpgrade = try helperClient.requiresInstallOrUpgrade()
        do {
            try await helperClient.ensureInstalledOrUpToDate(reporter: helperActivityReporter)
            let count = try await helperClient.setSystemProxy(endpoint: endpoint, serverHost: serverHost)
            print("[NulConnect][SystemProxy] enable via helper: success, services=\(count)")
            return count
        } catch {
            print("[NulConnect][SystemProxy] enable via helper: FAILED - \(error.localizedDescription)")
            if helperRequiresInstallOrUpgrade {
                throw error
            }
            if helperClient.isInstalled() {
                throw error
            }
            print("[NulConnect][SystemProxy] falling back to legacy runner")
        }

        let snapshotURL = self.snapshotURL
        return try await Task.detached(priority: .utility) {
            let count = try Self.enableSync(endpoint: endpoint, serverHost: serverHost, snapshotURL: snapshotURL)
            print("[NulConnect][SystemProxy] enable via legacy: success, services=\(count)")
            return count
        }.value
    }

    func restore() async throws {
        print("[NulConnect][SystemProxy] restore: starting")
        if helperClient.isInstalled() {
            do {
                try await helperClient.restoreSystemProxy()
                print("[NulConnect][SystemProxy] restore via helper: success")
                return
            } catch {
                print("[NulConnect][SystemProxy] restore via helper: FAILED - \(error.localizedDescription)")
                throw error
            }
        }

        let snapshotURL = self.snapshotURL
        try await Task.detached(priority: .utility) {
            try Self.restoreSync(snapshotURL: snapshotURL)
            print("[NulConnect][SystemProxy] restore via legacy: success")
        }.value
    }

    private nonisolated static func enableSync(endpoint: NulConnectProxyEndpoint, serverHost: String, snapshotURL: URL) throws -> Int {
        let services = try listNetworkServices()
        guard !services.isEmpty else {
            throw NulConnectSystemProxyManagerError.noNetworkServices
        }

        let currentSnapshot = NulConnectSystemProxySnapshot(
            savedAt: .now,
            services: try services.map { serviceName in
                try makeServiceSnapshot(for: serviceName)
            }
        )
        try saveSnapshotIfNeeded(currentSnapshot, to: snapshotURL)

        let exceptions = mergedExceptions(serverHost: serverHost, snapshot: currentSnapshot)
        let commands = currentSnapshot.services.flatMap { service in
            enableCommands(for: service.name, endpoint: endpoint, exceptions: exceptions)
        }
        try runPrivilegedCommands(commands, name: "system-proxy-enable")
        return currentSnapshot.services.count
    }

    private nonisolated static func restoreSync(snapshotURL: URL) throws {
        guard FileManager.default.fileExists(atPath: snapshotURL.path) else {
            return
        }

        let data = try Data(contentsOf: snapshotURL)
        let snapshot: NulConnectSystemProxySnapshot
        do {
            snapshot = try makeProxySnapshotDecoder().decode(NulConnectSystemProxySnapshot.self, from: data)
        } catch {
            throw NulConnectSystemProxyManagerError.snapshotDecodingFailed(error.localizedDescription)
        }

        let existingServices = Set((try? listNetworkServices()) ?? [])
        let commands = snapshot.services
            .filter { existingServices.contains($0.name) }
            .flatMap { restoreCommands(for: $0) }

        if !commands.isEmpty {
            try runPrivilegedCommands(commands, name: "system-proxy-restore")
        }
        try FileManager.default.removeItem(at: snapshotURL)
    }

    private nonisolated static func saveSnapshotIfNeeded(_ snapshot: NulConnectSystemProxySnapshot, to url: URL) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else {
            return
        }
        let data = try makeProxySnapshotEncoder().encode(snapshot)
        try data.write(to: url, options: [.atomic])
    }

    private nonisolated static func makeServiceSnapshot(for serviceName: String) throws -> NulConnectSystemProxySnapshot.Service {
        let webProxy = try readProxySetting(command: ["-getwebproxy", serviceName])
        let secureWebProxy = try readProxySetting(command: ["-getsecurewebproxy", serviceName])
        let socksProxy = try readProxySetting(command: ["-getsocksfirewallproxy", serviceName])
        let proxyAutoDiscoveryEnabled = try readBool(command: ["-getproxyautodiscovery", serviceName], keyCandidates: ["Proxy Auto Discovery", "Proxy Auto Discover"])
        let autoProxyURL = try readAutoProxyURL(command: ["-getautoproxyurl", serviceName])
        let bypassDomains = try readBypassDomains(command: ["-getproxybypassdomains", serviceName])

        return NulConnectSystemProxySnapshot.Service(
            name: serviceName,
            webProxy: webProxy,
            secureWebProxy: secureWebProxy,
            socksProxy: socksProxy,
            proxyAutoDiscoveryEnabled: proxyAutoDiscoveryEnabled,
            autoProxyURL: autoProxyURL,
            bypassDomains: bypassDomains
        )
    }

    private nonisolated static func enableCommands(for serviceName: String, endpoint: NulConnectProxyEndpoint, exceptions: [String]) -> [String] {
        var commands: [String] = [
            networkSetupCommand("-setwebproxy", serviceName, endpoint.host, String(endpoint.port), "off"),
            networkSetupCommand("-setwebproxystate", serviceName, "on"),
            networkSetupCommand("-setsecurewebproxy", serviceName, endpoint.host, String(endpoint.port), "off"),
            networkSetupCommand("-setsecurewebproxystate", serviceName, "on"),
            networkSetupCommand("-setsocksfirewallproxy", serviceName, endpoint.host, String(endpoint.port), "off"),
            networkSetupCommand("-setsocksfirewallproxystate", serviceName, "on"),
            networkSetupCommand("-setproxyautodiscovery", serviceName, "off"),
            networkSetupCommand("-setautoproxystate", serviceName, "off")
        ]

        commands.append(networkSetupCommand("-setproxybypassdomains", [serviceName] + exceptions))
        return commands
    }

    private nonisolated static func restoreCommands(for service: NulConnectSystemProxySnapshot.Service) -> [String] {
        var commands: [String] = []

        commands.append(contentsOf: proxyCommands(for: service.name, setting: service.webProxy, setState: "-setwebproxystate", setProxy: "-setwebproxy"))
        commands.append(contentsOf: proxyCommands(for: service.name, setting: service.secureWebProxy, setState: "-setsecurewebproxystate", setProxy: "-setsecurewebproxy"))
        commands.append(contentsOf: proxyCommands(for: service.name, setting: service.socksProxy, setState: "-setsocksfirewallproxystate", setProxy: "-setsocksfirewallproxy"))

        commands.append(networkSetupCommand("-setproxyautodiscovery", service.name, service.proxyAutoDiscoveryEnabled ? "on" : "off"))

        if let autoProxyURL = service.autoProxyURL, let url = autoProxyURL.url, !url.isEmpty {
            commands.append(networkSetupCommand("-setautoproxyurl", service.name, url))
            commands.append(networkSetupCommand("-setautoproxystate", service.name, autoProxyURL.enabled ? "on" : "off"))
        } else {
            commands.append(networkSetupCommand("-setautoproxystate", service.name, "off"))
        }

        commands.append(networkSetupCommand("-setproxybypassdomains", [service.name] + bypassDomainArguments(service.bypassDomains)))
        return commands
    }

    private nonisolated static func proxyCommands(for serviceName: String, setting: NulConnectSystemProxySnapshot.ProxySetting, setState: String, setProxy: String) -> [String] {
        guard setting.enabled, let server = setting.server, !server.isEmpty, let port = setting.port, port > 0 else {
            return [networkSetupCommand(setState, serviceName, "off")]
        }

        let commands = [
            networkSetupCommand(setProxy, serviceName, server, String(port), "off"),
            networkSetupCommand(setState, serviceName, "on")
        ]
        return commands
    }

    private nonisolated static func bypassDomainArguments(_ domains: [String]) -> [String] {
        if domains.isEmpty {
            return ["Empty"]
        }
        return domains
    }

    private nonisolated static func mergedExceptions(serverHost: String, snapshot: NulConnectSystemProxySnapshot) -> [String] {
        var exceptions = Set([
            "localhost",
            "127.0.0.1",
            "::1",
            "*.local",
            "169.254/16"
        ])

        let trimmedHost = serverHost.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedHost.isEmpty {
            exceptions.insert(trimmedHost)
        }

        for service in snapshot.services {
            for domain in service.bypassDomains {
                let trimmed = domain.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    exceptions.insert(trimmed)
                }
            }
        }

        return exceptions.sorted()
    }

    private nonisolated static func listNetworkServices() throws -> [String] {
        let output = try runNetworkSetup(arguments: ["-listallnetworkservices"])
        return output.split(separator: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                return nil
            }
            if trimmed.hasPrefix("An asterisk") {
                return nil
            }
            if trimmed.hasPrefix("*") {
                return String(trimmed.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return trimmed
        }
    }

    private nonisolated static func readProxySetting(command: [String]) throws -> NulConnectSystemProxySnapshot.ProxySetting {
        let output = try runNetworkSetup(arguments: command)
        let values = parseKeyValueOutput(output)
        let enabled = boolValue(values["Enabled"])
        let server = normalizedString(values["Server"])
        let port = UInt16(values["Port"] ?? "")
        let authenticated = boolValue(values["Authenticated Proxy Enabled"]) || boolValue(values["Authenticated"])
        let username = normalizedString(values["Username"])
        return NulConnectSystemProxySnapshot.ProxySetting(
            enabled: enabled,
            server: server,
            port: port,
            authenticated: authenticated,
            username: username
        )
    }

    private nonisolated static func readBool(command: [String], keyCandidates: [String]) throws -> Bool {
        let output = try runNetworkSetup(arguments: command)
        let values = parseKeyValueOutput(output)
        for key in keyCandidates {
            if let value = values[key] {
                return boolValue(value)
            }
        }
        return output.lowercased().contains("yes")
    }

    private nonisolated static func readAutoProxyURL(command: [String]) throws -> NulConnectSystemProxySnapshot.AutoProxyURL? {
        let output = try runNetworkSetup(arguments: command)
        let values = parseKeyValueOutput(output)
        let enabled = boolValue(values["Enabled"])
        let url = normalizedString(values["URL"])
        return NulConnectSystemProxySnapshot.AutoProxyURL(enabled: enabled, url: url)
    }

    private nonisolated static func readBypassDomains(command: [String]) throws -> [String] {
        let output = try runNetworkSetup(arguments: command)
        let lines = output.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        return lines.compactMap { line in
            guard !line.isEmpty else {
                return nil
            }
            if line.lowercased().contains("there aren") || line.lowercased().contains("bypass domain") {
                return nil
            }
            return line
        }
    }

    private nonisolated static func parseKeyValueOutput(_ output: String) -> [String: String] {
        output.split(separator: "\n").reduce(into: [:]) { result, rawLine in
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let separator = line.firstIndex(of: ":") else {
                return
            }
            let key = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            result[key] = value
        }
    }

    private nonisolated static func boolValue(_ value: String?) -> Bool {
        guard let value else {
            return false
        }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "yes" || normalized == "on" || normalized == "1" || normalized == "true"
    }

    private nonisolated static func normalizedString(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "(null)" else {
            return nil
        }
        return trimmed
    }

    private nonisolated static func networkSetupCommand(_ command: String, _ arguments: String...) -> String {
        networkSetupCommand(command, arguments)
    }

    private nonisolated static func networkSetupCommand(_ command: String, _ arguments: [String]) -> String {
        ([networkSetupPath, command] + arguments.map(shellQuote)).joined(separator: " ")
    }

    private nonisolated static func runNetworkSetup(arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: networkSetupPath)
        process.arguments = arguments

        let pipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = pipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            throw NulConnectSystemProxyManagerError.networkSetupUnavailable
        }
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(decoding: data, as: UTF8.self)
        let errorOutput = String(decoding: errorData, as: UTF8.self)

        guard process.terminationStatus == 0 else {
            let message = errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            throw NulConnectSystemProxyManagerError.privilegedExecutionFailed(message.isEmpty ? "networksetup failed" : message)
        }

        return output
    }

    private nonisolated static func runPrivilegedCommands(_ commands: [String], name: String) throws {
        guard !commands.isEmpty else {
            return
        }
        do {
            try NulConnectPrivilegedExecutor.runShellScript(
                commands.joined(separator: "\n"),
                name: name
            )
        } catch {
            throw NulConnectSystemProxyManagerError.privilegedExecutionFailed(
                error.localizedDescription
            )
        }
    }

    private nonisolated static func shellQuote(_ string: String) -> String {
        NulConnectPrivilegedExecutor.shellQuote(string)
    }

    private nonisolated static var networkSetupPath: String {
        "/usr/sbin/networksetup"
    }
}

private nonisolated func makeProxySnapshotEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return encoder
}

private nonisolated func makeProxySnapshotDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
}
