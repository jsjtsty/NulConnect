import Foundation

nonisolated final class NulConnectSystemProxyManager: @unchecked Sendable {
    private let helperClient = NulConnectHelperClient()

    init(baseDirectory: URL? = nil) throws {
        _ = baseDirectory
    }

    func enable(
        endpoint: NulConnectProxyEndpoint,
        serverHost: String,
        helperActivityReporter: NulConnectHelperClient.ActivityReporter? = nil
    ) async throws -> Int {
        try await helperClient.ensureInstalledOrUpToDate(reporter: helperActivityReporter)
        return try await helperClient.setSystemProxy(endpoint: endpoint, serverHost: serverHost)
    }

    func restore() async throws {
        guard helperClient.isInstalled() else {
            throw NulConnectHelperClientError.helperNotInstalled
        }
        try await helperClient.restoreSystemProxy()
    }
}
