#if NULCONNECT_ENABLE_TUN
import Foundation

enum NulConnectTunnelConstants {
    static let appGroupIdentifier = "group.com.nulstudio.NulConnect"
    static let providerBundleIdentifier = "com.nulstudio.NulConnect.TunnelExtension"
    static let launchConfigurationFilename = "tunnel-launch-configuration.json"
}

struct NulConnectTunnelLaunchConfiguration: Codable, Sendable {
    var profile: NulConnectProfile
    var session: ATRSessionMaterial
    var resource: ATRResourceSnapshot
    var savedAt: Date

    init(
        profile: NulConnectProfile,
        session: ATRSessionMaterial,
        resource: ATRResourceSnapshot,
        savedAt: Date = .now
    ) {
        self.profile = profile
        self.session = session
        self.resource = resource
        self.savedAt = savedAt
    }
}

enum NulConnectTunnelSharedStoreError: LocalizedError {
    case appGroupUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .appGroupUnavailable(let identifier):
            return "无法访问 App Group: \(identifier)"
        }
    }
}

enum NulConnectTunnelSharedStore {
    static func containerURL() throws -> URL {
        guard let url = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: NulConnectTunnelConstants.appGroupIdentifier
        ) else {
            throw NulConnectTunnelSharedStoreError.appGroupUnavailable(NulConnectTunnelConstants.appGroupIdentifier)
        }
        return url
    }

    static func configurationURL() throws -> URL {
        try containerURL().appendingPathComponent(
            NulConnectTunnelConstants.launchConfigurationFilename,
            isDirectory: false
        )
    }

    static func save(_ configuration: NulConnectTunnelLaunchConfiguration) throws {
        let url = try configurationURL()
        let data = try NulConnectJSON.encoder.encode(configuration)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
    }

    static func load() throws -> NulConnectTunnelLaunchConfiguration {
        let data = try Data(contentsOf: try configurationURL())
        return try NulConnectJSON.decoder.decode(NulConnectTunnelLaunchConfiguration.self, from: data)
    }
}
#endif
