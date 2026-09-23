import Foundation
import Security

final class SessionVault {
    private let keychain: KeychainStore
    private let summaryURL: URL
    private let account = "session.material"
    private let deviceIDAccount = "session.device-id"

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

    func loadOrCreateDeviceID() throws -> String {
        if let data = try keychain.loadData(account: deviceIDAccount),
           let stored = String(data: data, encoding: .utf8),
           Self.isValidDeviceID(stored) {
            return stored
        }

        let deviceID = try Self.makeDeviceID()
        try keychain.saveData(Data(deviceID.utf8), account: deviceIDAccount)
        return deviceID
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

    private static func isValidDeviceID(_ value: String) -> Bool {
        guard value.count == 32 else {
            return false
        }
        let validCharacters = "0123456789abcdef"
        return value.allSatisfy { validCharacters.contains($0) }
    }

    private static func makeDeviceID() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw NSError(
                domain: NSOSStatusErrorDomain,
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: NulConnectLocalization.text("Could not generate device identifier")]
            )
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
