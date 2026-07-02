import Foundation

final class ResourceSnapshotStore {
    private let fileURL: URL

    init(baseDirectory: URL? = nil) throws {
        let root = try NulConnectStorageDirectory.rootDirectory(override: baseDirectory)
        self.fileURL = root.appendingPathComponent("resource-snapshot.json", isDirectory: false)
    }

    func load() throws -> ATRResourceSnapshot? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }
        let data = try Data(contentsOf: fileURL)
        return try NulConnectJSON.decoder.decode(ATRResourceSnapshot.self, from: data)
    }

    func save(_ snapshot: ATRResourceSnapshot) throws {
        let data = try NulConnectJSON.encoder.encode(snapshot)
        try data.write(to: fileURL, options: [.atomic])
    }

    func delete() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return
        }
        try FileManager.default.removeItem(at: fileURL)
    }
}

