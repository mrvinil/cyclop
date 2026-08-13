import Foundation

enum DownloadRecordValidationError: Error, Equatable {
    case invalidRecord
}

enum DownloadRecordValidator {
    static func validate(_ records: [CyclopDownload]) throws {
        guard Set(records.map(\.id)).count == records.count,
              records.allSatisfy(isValid) else {
            throw DownloadRecordValidationError.invalidRecord
        }
    }

    private static func isValid(_ record: CyclopDownload) -> Bool {
        guard let scheme = record.remoteURL.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              record.remoteURL.host?.isEmpty == false,
              record.remoteURL.user == nil,
              record.remoteURL.password == nil,
              record.destinationURL.map(isAbsoluteFileURL) ?? true,
              record.bytesReceived >= 0,
              record.totalBytes.map({ $0 >= 0 }) ?? true,
              !record.displayName.isEmpty,
              isFinite(record.createdAt),
              record.completedAt.map(isFinite) ?? true,
              record.failedAt.map(isFinite) ?? true else {
            return false
        }

        switch record.phase {
        case .queued, .downloading, .paused, .cancelled:
            return record.completedAt == nil
                && record.failure == nil
        case .completed:
            return record.completedAt != nil
                && record.taskIdentifier == nil
                && record.resumeData == nil
                && record.failure == nil
                && record.failedAt == nil
        case .failed:
            return record.failure.map {
                    !$0.code.isEmpty && !$0.message.isEmpty
                } == true
        }
    }

    private static func isAbsoluteFileURL(_ url: URL) -> Bool {
        url.isFileURL && url.path.hasPrefix("/")
    }

    private static func isFinite(_ date: Date) -> Bool {
        date.timeIntervalSinceReferenceDate.isFinite
    }
}
