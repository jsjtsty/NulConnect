import Foundation

final class SessionVault {
    private let keychain: KeychainStore
    private let summaryURL: URL
    private let account = "session.material"

    init(baseDirectory: URL? = nil, keychainService: String = "com.nulstudio.NulConnect") throws {
        let root = try NulConnectStorageDirectory.rootDirectory(override: baseDirectory)
        self.summaryURL = root.appendingPathComponent("session-summary.json", isDirectory: false)
        self.keychain = KeychainStore(service: keychainService)
    }

    func save(_ material: ATRSessionMaterial) throws {
        let data = try NulConnectJSON.encoder.encode(material)
        try keychain.saveData(data, account: account)
        try saveSummary(.init(material: material))
    }

    func load() throws -> ATRSessionMaterial? {
        guard let data = try keychain.loadData(account: account) else {
            return nil
        }
        return try NulConnectJSON.decoder.decode(ATRSessionMaterial.self, from: data)
    }

    func loadSummary() throws -> NulConnectSessionSummary? {
        guard FileManager.default.fileExists(atPath: summaryURL.path) else {
            return nil
        }
        let data = try Data(contentsOf: summaryURL)
        return try NulConnectJSON.decoder.decode(NulConnectSessionSummary.self, from: data)
    }

    func clear() throws {
        try keychain.delete(account: account)
        if FileManager.default.fileExists(atPath: summaryURL.path) {
            try FileManager.default.removeItem(at: summaryURL)
        }
    }

    private func saveSummary(_ summary: NulConnectSessionSummary) throws {
        let data = try NulConnectJSON.encoder.encode(summary)
        try data.write(to: summaryURL, options: [.atomic])
    }
}

