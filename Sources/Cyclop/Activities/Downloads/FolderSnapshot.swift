import Foundation

struct FolderFileSnapshot: Equatable {
    let url: URL
    let fileResourceIdentifier: AnyHashable?
    let size: Int64
    let modifiedAt: Date
}

protocol FolderSnapshotProviding {
    func snapshots(in folder: URL) throws -> [FolderFileSnapshot]
}

struct FileManagerFolderSnapshotProvider: FolderSnapshotProviding {
    private static let resourceKeys: Set<URLResourceKey> = [
        .isRegularFileKey,
        .isHiddenKey,
        .isSymbolicLinkKey,
        .fileSizeKey,
        .contentModificationDateKey,
        .fileResourceIdentifierKey
    ]

    private let fileManager: FileManager
    private let resourceValues: (URL, Set<URLResourceKey>) throws -> URLResourceValues

    init(
        fileManager: FileManager = .default,
        resourceValues: @escaping (URL, Set<URLResourceKey>) throws -> URLResourceValues = {
            try $0.resourceValues(forKeys: $1)
        }
    ) {
        self.fileManager = fileManager
        self.resourceValues = resourceValues
    }

    func snapshots(in folder: URL) throws -> [FolderFileSnapshot] {
        let urls = try fileManager.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: Array(Self.resourceKeys),
            options: []
        )

        return urls.compactMap { url in
            guard let values = try? resourceValues(url, Self.resourceKeys) else {
                return nil
            }
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  values.isHidden != true,
                  let size = values.fileSize,
                  let modifiedAt = values.contentModificationDate else {
                return nil
            }

            return FolderFileSnapshot(
                url: url,
                fileResourceIdentifier: values.fileResourceIdentifier as? AnyHashable,
                size: Int64(size),
                modifiedAt: modifiedAt
            )
        }
        .sorted { $0.url.path < $1.url.path }
    }

    static func isEligibleFileName(_ name: String) -> Bool {
        guard !name.hasPrefix(".") else { return false }
        return !isTemporaryFileName(name)
    }

    static func isTemporaryFileName(_ name: String) -> Bool {
        let lowercaseName = name.lowercased()
        return [".crdownload", ".download", ".part", ".partial", ".tmp"]
            .contains { lowercaseName.hasSuffix($0) }
    }
}
