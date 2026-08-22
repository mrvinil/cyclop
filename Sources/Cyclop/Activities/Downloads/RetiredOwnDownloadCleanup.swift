import Foundation

/// Одноразово убирает технические следы удалённой очереди URL-загрузок.
/// Скачанные пользователем файлы находятся вне Application Support и здесь
/// намеренно никогда не затрагиваются.
@MainActor
final class RetiredOwnDownloadCleanup {
    typealias TaskCancellation = (@escaping @MainActor () -> Void) -> Void

    private static let migrationKey = "retiredOwnDownloadCleanupCompleted"
    private static let backgroundSessionIdentifier = "com.cyclop.app.downloads"

    private let applicationSupportDirectory: URL
    private let defaults: UserDefaults
    private let fileManager: FileManager
    private let cancelRetiredTasks: TaskCancellation

    init(
        applicationSupportDirectory: URL? = nil,
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default,
        cancelRetiredTasks: TaskCancellation? = nil
    ) {
        self.applicationSupportDirectory = applicationSupportDirectory
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.defaults = defaults
        self.fileManager = fileManager
        self.cancelRetiredTasks = cancelRetiredTasks ?? Self.cancelBackgroundTasks
    }

    func runIfNeeded(completion: @escaping @MainActor () -> Void = {}) {
        guard !defaults.bool(forKey: Self.migrationKey) else {
            completion()
            return
        }

        cancelRetiredTasks { [weak self] in
            guard let self else {
                completion()
                return
            }
            if self.removeTechnicalData() {
                self.defaults.set(true, forKey: Self.migrationKey)
            }
            completion()
        }
    }

    private func removeTechnicalData() -> Bool {
        let cyclopDirectory = applicationSupportDirectory.appendingPathComponent("Cyclop", isDirectory: true)
        let retiredURLs = [
            cyclopDirectory.appendingPathComponent("downloads.json"),
            cyclopDirectory.appendingPathComponent("DownloadFinalizations", isDirectory: true),
        ]
        do {
            for url in retiredURLs where fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
            return true
        } catch {
            return false
        }
    }

    private static func cancelBackgroundTasks(completion: @escaping @MainActor () -> Void) {
        let configuration = URLSessionConfiguration.background(
            withIdentifier: backgroundSessionIdentifier
        )
        let session = URLSession(configuration: configuration)
        session.getAllTasks { tasks in
            tasks.forEach { $0.cancel() }
            session.invalidateAndCancel()
            Task { @MainActor in completion() }
        }
    }
}
