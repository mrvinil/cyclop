import Foundation

enum DownloadPhase: String, Codable, Equatable {
    case queued, downloading, paused, completed, failed, cancelled
}

struct DownloadFailure: Codable, Equatable {
    let code: String
    let message: String
}

struct CyclopDownload: Identifiable, Codable, Equatable {
    let id: UUID
    let remoteURL: URL
    var phase: DownloadPhase
    var displayName: String
    var destinationURL: URL?
    var taskIdentifier: Int?
    var resumeData: Data?
    var bytesReceived: Int64
    var totalBytes: Int64?
    let createdAt: Date
    var completedAt: Date?
    var failure: DownloadFailure?

    var progress: Double? {
        if phase == .completed {
            return 1
        }
        guard let totalBytes, totalBytes > 0 else { return nil }
        return min(1, max(0, Double(bytesReceived) / Double(totalBytes)))
    }
}
