import Foundation

enum DownloadTransportEvent: Equatable {
    case started(id: UUID, taskIdentifier: Int)
    case progress(id: UUID, received: Int64, expected: Int64?)
    case paused(id: UUID, resumeData: Data?)
    case cancelled(id: UUID)
    case finished(id: UUID, temporaryURL: URL, suggestedFilename: String?)
    case failed(id: UUID, code: String, message: String, resumeData: Data?)
}

@MainActor
protocol DownloadTransport: AnyObject {
    var eventHandler: ((DownloadTransportEvent) -> Void)? { get set }
    func restore(
        records: [CyclopDownload],
        completion: @escaping @MainActor () -> Void
    )
    func start(id: UUID, url: URL, resumeData: Data?)
    func pause(id: UUID)
    func cancel(id: UUID)
}
