import Foundation

@MainActor
final class URLSessionDownloadTransport: NSObject, DownloadTransport,
    URLSessionDownloadDelegate, URLSessionTaskDelegate {
    typealias SessionFactory = @MainActor (
        URLSessionConfiguration,
        URLSessionDelegate,
        OperationQueue
    ) -> URLSession
    typealias AllTasksProvider = @MainActor (
        URLSession,
        @escaping @MainActor ([URLSessionTask]) -> Void
    ) -> Void
    typealias DownloadTaskFactory = @MainActor (
        URLSession,
        URL,
        Data?
    ) -> URLSessionDownloadTask
    typealias PauseOperation = @MainActor (
        URLSessionDownloadTask,
        @escaping @Sendable (Data?) -> Void
    ) -> Void
    typealias CancelOperation = @MainActor (URLSessionDownloadTask) -> Void
    typealias ResponseProvider = @MainActor (
        URLSessionDownloadTask
    ) -> HTTPURLResponse?
    typealias FinalURLProvider = @MainActor (
        URLSessionDownloadTask,
        HTTPURLResponse?
    ) -> URL?

    private enum TaskOrigin: String {
        case fresh
        case resume
        case fallback
    }

    private struct TaskDescriptor {
        static let prefix = "cyclop-download"
        static let version = "v1"

        let id: UUID
        let origin: TaskOrigin?

        init?(description: String?) {
            guard let description else { return nil }
            if let id = UUID(uuidString: description) {
                self.id = id
                origin = nil
                return
            }

            let parts = description.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 4,
                  parts[0] == Substring(Self.prefix),
                  parts[1] == Substring(Self.version),
                  let id = UUID(uuidString: String(parts[2])),
                  let origin = TaskOrigin(rawValue: String(parts[3])) else {
                return nil
            }
            self.id = id
            self.origin = origin
        }

        static func encoded(id: UUID, origin: TaskOrigin) -> String {
            "\(prefix):\(version):\(id.uuidString):\(origin.rawValue)"
        }

        func resolvedOrigin(record: CyclopDownload) -> TaskOrigin {
            if let origin { return origin }
            return record.resumeData.map { !$0.isEmpty } == true ? .resume : .fresh
        }
    }

    static let backgroundIdentifier = "com.cyclop.app.downloads"

    var eventHandler: ((DownloadTransportEvent) -> Void)?

    private let allTasksProvider: AllTasksProvider
    private let logger: (String) -> Void
    private let downloadTaskFactory: DownloadTaskFactory
    private let pauseOperation: PauseOperation
    private let cancelOperation: CancelOperation
    private let responseProvider: ResponseProvider
    private let finalURLProvider: FinalURLProvider
    private let sessionConfiguration: URLSessionConfiguration
    private let sessionFactory: SessionFactory
    private let delegateQueue: OperationQueue
    private lazy var session: URLSession = sessionFactory(
        sessionConfiguration,
        self,
        delegateQueue
    )
    private var currentRestoreToken: UUID?
    private var pendingRestoreTokens: Set<UUID> = []
    private var idByTaskIdentifier: [Int: UUID] = [:]
    private var taskByID: [UUID: URLSessionDownloadTask] = [:]
    private var remoteURLByID: [UUID: URL] = [:]
    private var startedTaskIdentifiers: Set<Int> = []
    private var terminalTaskIdentifiers: Set<Int> = []
    private var resumeAttemptTaskIdentifiers: Set<Int> = []
    private var resumeConfirmedTaskIdentifiers: Set<Int> = []
    private var fallbackUsedIDs: Set<UUID> = []
    private var intentionallyCancelledTaskIdentifiers: Set<Int> = []
    private var intentionallyPausedTaskIdentifiers: Set<Int> = []
    private var backgroundEventsCompletionHandler: (() -> Void)?

    convenience override init() {
        self.init(configuration: Self.makeLiveConfiguration())
    }

    init(
        configuration: URLSessionConfiguration,
        sessionFactory: @escaping SessionFactory = {
            URLSession(configuration: $0, delegate: $1, delegateQueue: $2)
        },
        downloadTaskFactory: @escaping DownloadTaskFactory = { session, url, resumeData in
            if let resumeData, !resumeData.isEmpty {
                return session.downloadTask(withResumeData: resumeData)
            }
            return session.downloadTask(with: URLSessionDownloadTransport.makeRequest(url))
        },
        pauseOperation: @escaping PauseOperation = { task, completion in
            task.cancel(byProducingResumeData: completion)
        },
        cancelOperation: @escaping CancelOperation = { task in
            task.cancel()
        },
        responseProvider: @escaping ResponseProvider = { task in
            task.response as? HTTPURLResponse
        },
        finalURLProvider: @escaping FinalURLProvider = { task, response in
            response?.url ?? task.currentRequest?.url
        },
        allTasksProvider: @escaping AllTasksProvider = { session, completion in
            session.getAllTasks { tasks in
                Task { @MainActor in
                    completion(tasks)
                }
            }
        },
        logger: @escaping (String) -> Void = { message in
            NSLog("Cyclop: %@", message)
        }
    ) {
        self.allTasksProvider = allTasksProvider
        self.logger = logger
        self.downloadTaskFactory = downloadTaskFactory
        self.pauseOperation = pauseOperation
        self.cancelOperation = cancelOperation
        self.responseProvider = responseProvider
        self.finalURLProvider = finalURLProvider
        sessionConfiguration = configuration
        self.sessionFactory = sessionFactory
        delegateQueue = OperationQueue()
        delegateQueue.name = "com.cyclop.app.downloads.delegate"
        delegateQueue.maxConcurrentOperationCount = 1
        super.init()
    }

    static func makeLiveConfiguration() -> URLSessionConfiguration {
        secured(
            URLSessionConfiguration.background(withIdentifier: backgroundIdentifier)
        )
    }

    static func makeTestConfiguration() -> URLSessionConfiguration {
        secured(.ephemeral)
    }

    nonisolated static func makeRequest(_ url: URL) -> URLRequest {
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData
        )
        request.httpShouldHandleCookies = false
        request.setValue(nil, forHTTPHeaderField: "Authorization")
        request.setValue(nil, forHTTPHeaderField: "Cookie")
        return request
    }

    nonisolated static func redirectRequest(
        from originalURL: URL,
        to proposedRequest: URLRequest
    ) -> URLRequest? {
        // Background URLSession follows redirects without calling the delegate.
        // This policy is defense-in-depth for ephemeral/in-process sessions only.
        guard let targetURL = proposedRequest.url,
              let sourceScheme = originalURL.scheme?.lowercased(),
              ["http", "https"].contains(sourceScheme),
              isAllowedDownloadURL(targetURL),
              let targetScheme = targetURL.scheme?.lowercased(),
              !(sourceScheme == "https" && targetScheme == "http") else {
            return nil
        }
        return makeRequest(targetURL)
    }

    nonisolated static func isAllowedDownloadURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = url.host,
              !host.isEmpty,
              url.user == nil,
              url.password == nil else {
            return false
        }
        return true
    }

    nonisolated static func isSafeFinalURL(
        _ finalURL: URL,
        requestedURL: URL
    ) -> Bool {
        guard isAllowedDownloadURL(requestedURL),
              isAllowedDownloadURL(finalURL),
              let requestedScheme = requestedURL.scheme?.lowercased(),
              let finalScheme = finalURL.scheme?.lowercased(),
              !(requestedScheme == "https" && finalScheme == "http") else {
            return false
        }
        return true
    }

    nonisolated static func authenticationDisposition(
        for authenticationMethod: String
    ) -> URLSession.AuthChallengeDisposition {
        authenticationMethod == NSURLAuthenticationMethodServerTrust
            ? .performDefaultHandling
            : .rejectProtectionSpace
    }

    static func shouldFallbackFromResumeAttempt(
        error: NSError,
        hasResponse: Bool,
        hasResumeData: Bool,
        resumeConfirmed: Bool
    ) -> Bool {
        guard error.domain == NSURLErrorDomain,
              !hasResponse,
              !hasResumeData,
              !resumeConfirmed else {
            return false
        }
        let excludedCodes: Set<Int> = [
            NSURLErrorCancelled,
            NSURLErrorTimedOut,
            NSURLErrorCannotFindHost,
            NSURLErrorCannotConnectToHost,
            NSURLErrorNetworkConnectionLost,
            NSURLErrorDNSLookupFailed,
            NSURLErrorNotConnectedToInternet,
            NSURLErrorInternationalRoamingOff,
            NSURLErrorCallIsActive,
            NSURLErrorDataNotAllowed,
            NSURLErrorRequestBodyStreamExhausted,
            NSURLErrorUserAuthenticationRequired,
            NSURLErrorUserCancelledAuthentication,
            NSURLErrorSecureConnectionFailed,
            NSURLErrorServerCertificateHasBadDate,
            NSURLErrorServerCertificateUntrusted,
            NSURLErrorServerCertificateHasUnknownRoot,
            NSURLErrorServerCertificateNotYetValid,
            NSURLErrorClientCertificateRejected,
            NSURLErrorClientCertificateRequired,
            NSURLErrorAppTransportSecurityRequiresSecureConnection,
            NSURLErrorBackgroundSessionRequiresSharedContainer,
            NSURLErrorBackgroundSessionInUseByAnotherProcess,
            NSURLErrorBackgroundSessionWasDisconnected
        ]
        return !excludedCodes.contains(error.code)
    }

    func restore(
        records: [CyclopDownload],
        completion: @escaping @MainActor () -> Void
    ) {
        let token = UUID()
        currentRestoreToken = token
        pendingRestoreTokens.insert(token)
        allTasksProvider(session) { [weak self] tasks in
            self?.completeRestore(
                token: token,
                records: records,
                tasks: tasks,
                completion: completion
            )
        }
    }

    func start(id: UUID, url: URL, resumeData: Data?) {
        let hasResumeData = resumeData.map { !$0.isEmpty } ?? false
        startTask(
            id: id,
            url: url,
            resumeData: hasResumeData ? resumeData : nil,
            origin: hasResumeData ? .resume : .fresh
        )
    }

    private func startTask(
        id: UUID,
        url: URL,
        resumeData: Data?,
        origin: TaskOrigin
    ) {
        guard Self.isAllowedDownloadURL(url) else {
            eventHandler?(.failed(
                id: id,
                code: "invalid-url",
                message: "Ссылка для загрузки недействительна или содержит данные входа",
                resumeData: nil
            ))
            return
        }

        remoteURLByID[id] = url
        let task = downloadTaskFactory(session, url, resumeData)
        switch origin {
        case .resume:
            resumeAttemptTaskIdentifiers.insert(task.taskIdentifier)
        case .fallback:
            fallbackUsedIDs.insert(id)
        case .fresh:
            break
        }
        map(task, to: id, origin: origin)
        if origin != .resume {
            emitStartedIfNeeded(task: task, id: id)
        }
        task.resume()
    }

    func pause(id: UUID) {
        guard let task = taskByID[id],
              !terminalTaskIdentifiers.contains(task.taskIdentifier),
              !intentionallyPausedTaskIdentifiers.contains(task.taskIdentifier),
              !intentionallyCancelledTaskIdentifiers.contains(task.taskIdentifier) else {
            return
        }
        let taskIdentifier = task.taskIdentifier
        intentionallyPausedTaskIdentifiers.insert(taskIdentifier)
        pauseOperation(task) { [weak self] resumeData in
            self?.performOnMainActorAndWait { transport in
                transport.completePause(
                    id: id,
                    taskIdentifier: taskIdentifier,
                    resumeData: resumeData
                )
            }
        }
    }

    func cancel(id: UUID) {
        guard let task = taskByID[id],
              !terminalTaskIdentifiers.contains(task.taskIdentifier) else {
            eventHandler?(.cancelled(id: id))
            return
        }
        intentionallyPausedTaskIdentifiers.remove(task.taskIdentifier)
        intentionallyCancelledTaskIdentifiers.insert(task.taskIdentifier)
        cancelOperation(task)
    }

    func invalidate() {
        session.invalidateAndCancel()
    }

    func setBackgroundEventsCompletionHandler(_ handler: @escaping () -> Void) {
        backgroundEventsCompletionHandler = handler
    }

    private func completeRestore(
        token: UUID,
        records: [CyclopDownload],
        tasks: [URLSessionTask],
        completion: @escaping @MainActor () -> Void
    ) {
        guard pendingRestoreTokens.remove(token) != nil else { return }
        guard currentRestoreToken == token else {
            completion()
            return
        }
        currentRestoreToken = nil

        let downloadTasks = tasks.compactMap { $0 as? URLSessionDownloadTask }
        resetMappingsForAuthoritativeRestore()
        var usedTaskIdentifiers: Set<Int> = []
        let orderedRecords = records.sorted {
            if $0.createdAt != $1.createdAt {
                return $0.createdAt < $1.createdAt
            }
            return $0.id.uuidString < $1.id.uuidString
        }

        for record in orderedRecords {
            let candidates = downloadTasks
                .filter {
                    TaskDescriptor(description: $0.taskDescription)?.id == record.id
                }
                .sorted { $0.taskIdentifier < $1.taskIdentifier }
            let selected = record.taskIdentifier.flatMap { persistedIdentifier in
                candidates.first { $0.taskIdentifier == persistedIdentifier }
            } ?? candidates.first

            guard let selected else {
                eventHandler?(.failed(
                    id: record.id,
                    code: "task-lost",
                    message: "Фоновая задача не найдена",
                    resumeData: nil
                ))
                continue
            }

            usedTaskIdentifiers.insert(selected.taskIdentifier)
            remoteURLByID[record.id] = record.remoteURL
            let descriptor = TaskDescriptor(description: selected.taskDescription)
            let origin = descriptor?.resolvedOrigin(record: record) ?? .fresh
            switch origin {
            case .resume:
                resumeAttemptTaskIdentifiers.insert(selected.taskIdentifier)
            case .fallback:
                fallbackUsedIDs.insert(record.id)
            case .fresh:
                break
            }
            map(selected, to: record.id, origin: origin)
            emitStartedIfNeeded(task: selected, id: record.id)
            eventHandler?(.progress(
                id: record.id,
                received: max(0, selected.countOfBytesReceived),
                expected: positiveExpectedBytes(selected.countOfBytesExpectedToReceive)
            ))
            if selected.state == .suspended {
                selected.resume()
            }
        }

        for orphan in downloadTasks
            .filter({ !usedTaskIdentifiers.contains($0.taskIdentifier) })
            .sorted(by: { $0.taskIdentifier < $1.taskIdentifier }) {
            logger("Отменена несвязанная фоновая задача \(orphan.taskIdentifier)")
            orphan.cancel()
        }
        completion()
    }

    private func resetMappingsForAuthoritativeRestore() {
        idByTaskIdentifier.removeAll()
        taskByID.removeAll()
        remoteURLByID.removeAll()
        startedTaskIdentifiers.removeAll()
        terminalTaskIdentifiers.removeAll()
        resumeAttemptTaskIdentifiers.removeAll()
        resumeConfirmedTaskIdentifiers.removeAll()
        fallbackUsedIDs.removeAll()
        intentionallyCancelledTaskIdentifiers.removeAll()
        intentionallyPausedTaskIdentifiers.removeAll()
    }

    private func map(
        _ task: URLSessionDownloadTask,
        to id: UUID,
        origin: TaskOrigin
    ) {
        idByTaskIdentifier[task.taskIdentifier] = id
        taskByID[id] = task
        task.taskDescription = TaskDescriptor.encoded(id: id, origin: origin)
    }

    private func positiveExpectedBytes(_ value: Int64) -> Int64? {
        value > 0 ? value : nil
    }

    private func emitStartedIfNeeded(task: URLSessionDownloadTask, id: UUID) {
        guard !startedTaskIdentifiers.contains(task.taskIdentifier) else { return }
        startedTaskIdentifiers.insert(task.taskIdentifier)
        eventHandler?(.started(id: id, taskIdentifier: task.taskIdentifier))
    }

    private func handleProgress(
        task: URLSessionDownloadTask,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let id = idByTaskIdentifier[task.taskIdentifier],
              !terminalTaskIdentifiers.contains(task.taskIdentifier) else {
            return
        }
        if resumeAttemptTaskIdentifiers.contains(task.taskIdentifier) {
            resumeConfirmedTaskIdentifiers.insert(task.taskIdentifier)
        }
        emitStartedIfNeeded(task: task, id: id)
        eventHandler?(.progress(
            id: id,
            received: max(0, totalBytesWritten),
            expected: positiveExpectedBytes(totalBytesExpectedToWrite)
        ))
    }

    private func completePause(
        id: UUID,
        taskIdentifier: Int,
        resumeData: Data?
    ) {
        guard idByTaskIdentifier[taskIdentifier] == id else { return }
        guard !terminalTaskIdentifiers.contains(taskIdentifier) else {
            cleanup(taskIdentifier: taskIdentifier, id: id)
            return
        }
        if intentionallyCancelledTaskIdentifiers.contains(taskIdentifier) {
            terminalTaskIdentifiers.insert(taskIdentifier)
            eventHandler?(.cancelled(id: id))
            cleanup(taskIdentifier: taskIdentifier, id: id)
            return
        }
        guard intentionallyPausedTaskIdentifiers.contains(taskIdentifier) else { return }
        terminalTaskIdentifiers.insert(taskIdentifier)
        eventHandler?(.paused(id: id, resumeData: resumeData))
        cleanup(taskIdentifier: taskIdentifier, id: id)
    }

    private func handleFinished(task: URLSessionDownloadTask, location: URL) {
        guard let id = idByTaskIdentifier[task.taskIdentifier],
              !terminalTaskIdentifiers.contains(task.taskIdentifier) else {
            return
        }
        if intentionallyCancelledTaskIdentifiers.contains(task.taskIdentifier) {
            terminalTaskIdentifiers.insert(task.taskIdentifier)
            eventHandler?(.cancelled(id: id))
            cleanup(taskIdentifier: task.taskIdentifier, id: id)
            return
        }
        emitStartedIfNeeded(task: task, id: id)
        terminalTaskIdentifiers.insert(task.taskIdentifier)

        let response = responseProvider(task)
        let finalURL = finalURLProvider(task, response)
        let requestedURL = remoteURLByID[id] ?? task.originalRequest?.url
        guard let finalURL,
              let requestedURL,
              Self.isSafeFinalURL(finalURL, requestedURL: requestedURL) else {
            eventHandler?(.failed(
                id: id,
                code: "unsafe-redirect",
                message: "Загрузка отклонена из-за небезопасного перенаправления",
                resumeData: nil
            ))
            return
        }
        guard let statusCode = response?.statusCode,
              (200 ... 299).contains(statusCode) else {
            let statusCode = response?.statusCode ?? 0
            eventHandler?(.failed(
                id: id,
                code: "http-\(statusCode)",
                message: "Сервер вернул ошибку \(statusCode)",
                resumeData: nil
            ))
            return
        }
        eventHandler?(.finished(
            id: id,
            temporaryURL: location,
            suggestedFilename: response?.suggestedFilename
        ))
    }

    private func handleCompletion(task: URLSessionTask, error: Error?) {
        guard let id = idByTaskIdentifier[task.taskIdentifier] else { return }

        if terminalTaskIdentifiers.contains(task.taskIdentifier) {
            cleanup(taskIdentifier: task.taskIdentifier, id: id)
            return
        }
        if intentionallyPausedTaskIdentifiers.contains(task.taskIdentifier) {
            return
        }
        if intentionallyCancelledTaskIdentifiers.contains(task.taskIdentifier) {
            terminalTaskIdentifiers.insert(task.taskIdentifier)
            eventHandler?(.cancelled(id: id))
            cleanup(taskIdentifier: task.taskIdentifier, id: id)
            return
        }

        if let error {
            let nsError = error as NSError
            let resumeDataPayload = nsError.userInfo["NSURLSessionDownloadTaskResumeData"]
            let retainedResumeData = resumeDataPayload as? Data
            let resumeWasRejected = Self.shouldFallbackFromResumeAttempt(
                error: nsError,
                hasResponse: task.response != nil,
                hasResumeData: resumeDataPayload != nil,
                resumeConfirmed: resumeConfirmedTaskIdentifiers.contains(task.taskIdentifier)
            )
            if resumeWasRejected,
               resumeAttemptTaskIdentifiers.contains(task.taskIdentifier),
               !fallbackUsedIDs.contains(id),
               let url = remoteURLByID[id]
                    ?? task.originalRequest?.url
                    ?? task.currentRequest?.url {
                cleanup(taskIdentifier: task.taskIdentifier, id: id)
                startTask(id: id, url: url, resumeData: nil, origin: .fallback)
                return
            }

            terminalTaskIdentifiers.insert(task.taskIdentifier)
            let exhaustedResumeFallback = resumeWasRejected && fallbackUsedIDs.contains(id)
            eventHandler?(.failed(
                id: id,
                code: exhaustedResumeFallback ? "cannot-resume" : "network",
                message: networkMessage(
                    for: nsError,
                    exhaustedResumeFallback: exhaustedResumeFallback
                ),
                resumeData: retainedResumeData
            ))
            cleanup(taskIdentifier: task.taskIdentifier, id: id)
            return
        }

        terminalTaskIdentifiers.insert(task.taskIdentifier)
        eventHandler?(.failed(
            id: id,
            code: "transport-incomplete",
            message: "Загрузка завершилась без файла",
            resumeData: nil
        ))
        cleanup(taskIdentifier: task.taskIdentifier, id: id)
    }

    private func networkMessage(
        for error: NSError,
        exhaustedResumeFallback: Bool = false
    ) -> String {
        if exhaustedResumeFallback {
            return "Не удалось продолжить или начать загрузку заново"
        }
        switch error.code {
        case NSURLErrorTimedOut:
            return "Превышено время ожидания загрузки"
        case NSURLErrorNetworkConnectionLost:
            return "Сетевое соединение прервано"
        default:
            return "Не удалось скачать файл из-за ошибки сети"
        }
    }

    private func cleanup(taskIdentifier: Int, id: UUID) {
        idByTaskIdentifier.removeValue(forKey: taskIdentifier)
        if taskByID[id]?.taskIdentifier == taskIdentifier {
            taskByID.removeValue(forKey: id)
            remoteURLByID.removeValue(forKey: id)
        }
        startedTaskIdentifiers.remove(taskIdentifier)
        terminalTaskIdentifiers.remove(taskIdentifier)
        resumeAttemptTaskIdentifiers.remove(taskIdentifier)
        resumeConfirmedTaskIdentifiers.remove(taskIdentifier)
        intentionallyCancelledTaskIdentifiers.remove(taskIdentifier)
        intentionallyPausedTaskIdentifiers.remove(taskIdentifier)
        fallbackUsedIDs.remove(id)
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        Task { @MainActor [weak self] in
            self?.handleProgress(
                task: downloadTask,
                totalBytesWritten: totalBytesWritten,
                totalBytesExpectedToWrite: totalBytesExpectedToWrite
            )
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // Foundation does not invoke this callback for background session tasks.
        let sourceURL = task.currentRequest?.url
            ?? task.originalRequest?.url
            ?? response.url
        completionHandler(
            sourceURL.flatMap { Self.redirectRequest(from: $0, to: request) }
        )
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (
            URLSession.AuthChallengeDisposition,
            URLCredential?
        ) -> Void
    ) {
        completionHandler(
            Self.authenticationDisposition(
                for: challenge.protectionSpace.authenticationMethod
            ),
            nil
        )
    }

    nonisolated func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (
            URLSession.AuthChallengeDisposition,
            URLCredential?
        ) -> Void
    ) {
        completionHandler(
            Self.authenticationDisposition(
                for: challenge.protectionSpace.authenticationMethod
            ),
            nil
        )
    }

    nonisolated func urlSessionDidFinishEvents(
        forBackgroundURLSession session: URLSession
    ) {
        performOnMainActorAndWait { transport in
            let handler = transport.backgroundEventsCompletionHandler
            transport.backgroundEventsCompletionHandler = nil
            handler?()
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didResumeAtOffset fileOffset: Int64,
        expectedTotalBytes: Int64
    ) {
        Task { @MainActor [weak self] in
            self?.handleResumeConfirmation(
                task: downloadTask,
                fileOffset: fileOffset,
                expectedTotalBytes: expectedTotalBytes
            )
        }
    }

    private func handleResumeConfirmation(
        task: URLSessionDownloadTask,
        fileOffset: Int64,
        expectedTotalBytes: Int64
    ) {
        guard let id = idByTaskIdentifier[task.taskIdentifier],
              !terminalTaskIdentifiers.contains(task.taskIdentifier) else {
            return
        }
        resumeConfirmedTaskIdentifiers.insert(task.taskIdentifier)
        emitStartedIfNeeded(task: task, id: id)
        eventHandler?(.progress(
            id: id,
            received: max(0, fileOffset),
            expected: positiveExpectedBytes(expectedTotalBytes)
        ))
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        performOnMainActorAndWait { transport in
            transport.handleFinished(task: downloadTask, location: location)
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        Task { @MainActor [weak self] in
            self?.handleCompletion(task: task, error: error)
        }
    }

    private nonisolated func performOnMainActorAndWait(
        _ action: @escaping @MainActor (URLSessionDownloadTransport) -> Void
    ) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { [weak self] in
                guard let self else { return }
                action(self)
            }
        } else {
            DispatchQueue.main.sync { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    action(self)
                }
            }
        }
    }

    private static func secured(
        _ configuration: URLSessionConfiguration
    ) -> URLSessionConfiguration {
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return configuration
    }
}
