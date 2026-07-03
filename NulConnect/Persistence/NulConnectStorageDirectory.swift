import Foundation

nonisolated enum NulConnectStorageDirectory {
    static func rootDirectory(override: URL? = nil) throws -> URL {
        let directory: URL
        if let override {
            directory = override
        } else {
            directory = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ).appendingPathComponent("NulConnect", isDirectory: true)
        }

        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: nil
        )
        return directory
    }
}
