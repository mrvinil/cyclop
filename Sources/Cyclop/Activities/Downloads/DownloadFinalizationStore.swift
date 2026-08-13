import Foundation

struct DownloadFinalizationJournal: Codable, Equatable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let downloadID: UUID
    let destinationURL: URL
    let completedAt: Date

    init(
        downloadID: UUID,
        destinationURL: URL,
        completedAt: Date
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.downloadID = downloadID
        self.destinationURL = destinationURL
        self.completedAt = completedAt
    }
}

enum DownloadFinalizationRecovery: Equatable {
    case journal(DownloadFinalizationJournal, stagedURL: URL?)
    case stagedOnly(downloadID: UUID, stagedURL: URL)

    var downloadID: UUID {
        switch self {
        case let .journal(journal, _):
            return journal.downloadID
        case let .stagedOnly(downloadID, _):
            return downloadID
        }
    }
}

protocol DownloadFinalizationStoring {
    func stage(downloadID: UUID, temporaryURL: URL) throws -> URL
    func save(_ journal: DownloadFinalizationJournal) throws
    func recoveries() throws -> [DownloadFinalizationRecovery]
    func removeJournal(downloadID: UUID) throws
    func markAbandoned(downloadID: UUID) throws
    func abandonedDownloadIDs() throws -> Set<UUID>
    func abandon(downloadID: UUID) throws
}

enum DownloadFinalizationStoreError: Error, Equatable {
    case stagedFileAlreadyExists
    case invalidJournal
}

struct DownloadFinalizationStore: DownloadFinalizationStoring {
    let rootDirectory: URL
    private let fileManager: FileManager

    init(
        rootDirectory: URL,
        fileManager: FileManager = .default
    ) {
        self.rootDirectory = rootDirectory
        self.fileManager = fileManager
    }

    static func live(fileManager: FileManager = .default) -> Self {
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        return Self(
            rootDirectory: applicationSupport.appendingPathComponent(
                "Cyclop/DownloadFinalizations",
                isDirectory: true
            ),
            fileManager: fileManager
        )
    }

    func stage(downloadID: UUID, temporaryURL: URL) throws -> URL {
        try createRootDirectory()
        let destination = stagedURL(downloadID: downloadID)
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw DownloadFinalizationStoreError.stagedFileAlreadyExists
        }
        try fileManager.moveItem(at: temporaryURL, to: destination)
        return destination
    }

    func save(_ journal: DownloadFinalizationJournal) throws {
        guard isValid(journal) else {
            throw DownloadFinalizationStoreError.invalidJournal
        }
        try createRootDirectory()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        try encoder.encode(journal).write(
            to: journalURL(downloadID: journal.downloadID),
            options: .atomic
        )
    }

    func recoveries() throws -> [DownloadFinalizationRecovery] {
        let urls: [URL]
        do {
            urls = try fileManager.contentsOfDirectory(
                at: rootDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        } catch {
            let cocoaError = error as NSError
            guard cocoaError.domain == NSCocoaErrorDomain,
                  cocoaError.code == NSFileReadNoSuchFileError else {
                throw error
            }
            return []
        }

        let abandonedIDs = try Set(urls.compactMap { url -> UUID? in
            guard url.pathExtension == "abandoned" else { return nil }
            guard let id = downloadID(from: url, extension: "abandoned") else {
                throw DownloadFinalizationStoreError.invalidJournal
            }
            return id
        })
        let stagesByID = try urls
            .filter { $0.pathExtension == "stage" }
            .reduce(into: [UUID: URL]()) { result, url in
                guard let id = downloadID(from: url, extension: "stage"),
                      result[id] == nil else {
                    throw DownloadFinalizationStoreError.invalidJournal
                }
                guard !abandonedIDs.contains(id) else { return }
                result[id] = stagedURL(downloadID: id)
            }

        var referencedStageIDs: Set<UUID> = []
        var result: [DownloadFinalizationRecovery] = []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        for url in urls.filter({ $0.pathExtension == "json" }) {
            guard let fileID = downloadID(from: url, extension: "json") else {
                throw DownloadFinalizationStoreError.invalidJournal
            }
            guard !abandonedIDs.contains(fileID) else { continue }
            let journal: DownloadFinalizationJournal
            do {
                journal = try decoder.decode(
                    DownloadFinalizationJournal.self,
                    from: Data(contentsOf: url)
                )
            } catch {
                throw DownloadFinalizationStoreError.invalidJournal
            }
            guard journal.downloadID == fileID, isValid(journal) else {
                throw DownloadFinalizationStoreError.invalidJournal
            }
            referencedStageIDs.insert(fileID)
            result.append(.journal(journal, stagedURL: stagesByID[fileID]))
        }

        for (id, url) in stagesByID where !referencedStageIDs.contains(id) {
            result.append(.stagedOnly(downloadID: id, stagedURL: url))
        }
        return result.sorted { $0.downloadID.uuidString < $1.downloadID.uuidString }
    }

    func removeJournal(downloadID: UUID) throws {
        let url = journalURL(downloadID: downloadID)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    func markAbandoned(downloadID: UUID) throws {
        try createRootDirectory()
        try Data().write(to: abandonmentURL(downloadID: downloadID), options: .atomic)
    }

    func abandonedDownloadIDs() throws -> Set<UUID> {
        let urls: [URL]
        do {
            urls = try fileManager.contentsOfDirectory(
                at: rootDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        } catch {
            let cocoaError = error as NSError
            guard cocoaError.domain == NSCocoaErrorDomain,
                  cocoaError.code == NSFileReadNoSuchFileError else {
                throw error
            }
            return []
        }

        return try Set(urls.compactMap { url in
            guard url.pathExtension == "abandoned" else { return nil }
            guard let id = downloadID(from: url, extension: "abandoned") else {
                throw DownloadFinalizationStoreError.invalidJournal
            }
            return id
        })
    }

    func abandon(downloadID: UUID) throws {
        // Marker удаляется последним: после сбоя следующий запуск безопасно продолжит cleanup.
        try removeIfExists(stagedURL(downloadID: downloadID))
        try removeIfExists(journalURL(downloadID: downloadID))
        try removeIfExists(abandonmentURL(downloadID: downloadID))
    }

    private func createRootDirectory() throws {
        try fileManager.createDirectory(
            at: rootDirectory,
            withIntermediateDirectories: true
        )
    }

    private func stagedURL(downloadID: UUID) -> URL {
        rootDirectory.appendingPathComponent("\(downloadID.uuidString).stage")
    }

    private func journalURL(downloadID: UUID) -> URL {
        rootDirectory.appendingPathComponent("\(downloadID.uuidString).json")
    }

    private func abandonmentURL(downloadID: UUID) -> URL {
        rootDirectory.appendingPathComponent("\(downloadID.uuidString).abandoned")
    }

    private func removeIfExists(_ url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    private func downloadID(from url: URL, extension expectedExtension: String) -> UUID? {
        guard url.pathExtension == expectedExtension else { return nil }
        return UUID(uuidString: url.deletingPathExtension().lastPathComponent)
    }

    private func isValid(_ journal: DownloadFinalizationJournal) -> Bool {
        journal.schemaVersion == DownloadFinalizationJournal.currentSchemaVersion
            && journal.destinationURL.isFileURL
            && journal.destinationURL.path.hasPrefix("/")
            && journal.completedAt.timeIntervalSinceReferenceDate.isFinite
    }
}
