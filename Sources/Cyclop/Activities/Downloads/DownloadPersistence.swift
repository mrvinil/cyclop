import Foundation

protocol DownloadPersisting {
    func load() throws -> [CyclopDownload]
    func save(_ downloads: [CyclopDownload]) throws
}

struct JSONDownloadPersistence: DownloadPersisting {
    let fileURL: URL

    static func live(fileManager: FileManager = .default) -> Self {
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        return Self(
            fileURL: applicationSupport.appendingPathComponent("Cyclop/downloads.json")
        )
    }

    func load() throws -> [CyclopDownload] {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            let cocoaError = error as NSError
            guard cocoaError.domain == NSCocoaErrorDomain,
                  cocoaError.code == NSFileReadNoSuchFileError else {
                throw error
            }
            return []
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode([CyclopDownload].self, from: data)
    }

    func save(_ downloads: [CyclopDownload]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        try encoder.encode(downloads).write(to: fileURL, options: .atomic)
    }
}
