#if NULCONNECT_ENABLE_TUN
import Foundation
import NetworkExtension

@MainActor
final class NulConnectTunnelManager {
    private let localizedDescription = "NulConnect"

    func loadStatus() async -> NEVPNStatus {
        do {
            guard let manager = try await loadManager(createIfNeeded: false) else {
                return .disconnected
            }
            return manager.connection.status
        } catch {
            return .invalid
        }
    }

    func start(configuration: NulConnectTunnelLaunchConfiguration) async throws {
        try NulConnectTunnelSharedStore.save(configuration)
        let manager = try await loadManager(createIfNeeded: true)!
        try await manager.loadFromPreferences()

        guard let protocolConfiguration = manager.protocolConfiguration as? NETunnelProviderProtocol else {
            throw NulConnectTunnelManagerError.invalidProtocolConfiguration
        }

        protocolConfiguration.providerConfiguration = [
            "configurationFile": NulConnectTunnelConstants.launchConfigurationFilename
        ]
        protocolConfiguration.serverAddress = configuration.profile.serverHost
        manager.localizedDescription = localizedDescription
        manager.isEnabled = true

        try await manager.saveToPreferences()
        try await manager.loadFromPreferences()
        try manager.connection.startVPNTunnel()
    }

    func stop() async {
        do {
            guard let manager = try await loadManager(createIfNeeded: false) else {
                return
            }
            manager.connection.stopVPNTunnel()
        } catch {
            return
        }
    }

    private func loadManager(createIfNeeded: Bool) async throws -> NETunnelProviderManager? {
        let managers = try await NETunnelProviderManager.loadAllFromPreferences()
        if let existing = managers.first(where: {
            ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == NulConnectTunnelConstants.providerBundleIdentifier
        }) {
            return existing
        }

        guard createIfNeeded else {
            return nil
        }

        let manager = NETunnelProviderManager()
        let protocolConfiguration = NETunnelProviderProtocol()
        protocolConfiguration.providerBundleIdentifier = NulConnectTunnelConstants.providerBundleIdentifier
        protocolConfiguration.serverAddress = localizedDescription
        manager.protocolConfiguration = protocolConfiguration
        manager.localizedDescription = localizedDescription
        manager.isEnabled = true
        return manager
    }
}

enum NulConnectTunnelManagerError: LocalizedError {
    case invalidProtocolConfiguration

    var errorDescription: String? {
        switch self {
        case .invalidProtocolConfiguration:
            return "TUN 配置不是 NETunnelProviderProtocol"
        }
    }
}
#endif
