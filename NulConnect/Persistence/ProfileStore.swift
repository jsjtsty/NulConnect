import Foundation

final class ProfileStore {
    private let fileURL: URL

    init(baseDirectory: URL? = nil) throws {
        let root = try NulConnectStorageDirectory.rootDirectory(override: baseDirectory)
        self.fileURL = root.appendingPathComponent("profile.json", isDirectory: false)
    }

    func load() throws -> NulConnectProfile {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return .default
        }
        let data = try Data(contentsOf: fileURL)
        return try NulConnectJSON.decoder.decode(NulConnectProfile.self, from: data)
    }

    func save(_ profile: NulConnectProfile) throws {
        let data = try NulConnectJSON.encoder.encode(profile)
        try data.write(to: fileURL, options: [.atomic])
    }

    func delete() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return
        }
        try FileManager.default.removeItem(at: fileURL)
    }
}

