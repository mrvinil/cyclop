import Foundation

protocol TimerPersisting {
    func load() throws -> [CyclopTimer]
    func save(_ timers: [CyclopTimer]) throws
}

struct JSONTimerPersistence: TimerPersisting {
    let fileURL: URL

    static func live(fileManager: FileManager = .default) -> Self {
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        return Self(
            fileURL: applicationSupport.appendingPathComponent("Cyclop/timers.json")
        )
    }

    func load() throws -> [CyclopTimer] {
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
        return try decoder.decode([CyclopTimer].self, from: data)
    }

    func save(_ timers: [CyclopTimer]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        try encoder.encode(timers).write(to: fileURL, options: .atomic)
    }
}
