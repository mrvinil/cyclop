import Foundation
import XCTest
@testable import Cyclop

@MainActor
final class URLSessionDownloadTransportTests: XCTestCase {
    func testBackgroundIdentifierAndLiveConfigurationAreScopedToCyclopBundle() {
        let configuration = URLSessionDownloadTransport.makeLiveConfiguration()

        XCTAssertEqual(URLSessionDownloadTransport.backgroundIdentifier, "com.cyclop.app.downloads")
        XCTAssertEqual(configuration.identifier, "com.cyclop.app.downloads")
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertEqual(configuration.httpCookieAcceptPolicy, .never)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertNil(configuration.urlCache)
        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
    }

    func testTestConfigurationIsEphemeralAndDoesNotSharePrivateStores() {
        let configuration = URLSessionDownloadTransport.makeTestConfiguration()

        XCTAssertNil(configuration.identifier)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertEqual(configuration.httpCookieAcceptPolicy, .never)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertNil(configuration.urlCache)
        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
    }

    func testRequestDoesNotUseCookiesCacheOrCredentials() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/file"))
        let request = URLSessionDownloadTransport.makeRequest(url)

        XCTAssertEqual(request.url, url)
        XCTAssertFalse(request.httpShouldHandleCookies)
        XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
    }

    func testEphemeralRedirectPolicyAllowsWebSchemesStripsPrivateHeadersAndRejectsDowngrade() throws {
        let original = try XCTUnwrap(URL(string: "https://example.com/start"))
        var proposed = URLRequest(url: try XCTUnwrap(URL(string: "https://cdn.example.com/file")))
        proposed.setValue("Basic secret", forHTTPHeaderField: "Authorization")
        proposed.setValue("session=secret", forHTTPHeaderField: "Cookie")

        let accepted = URLSessionDownloadTransport.redirectRequest(
            from: original,
            to: proposed
        )

        XCTAssertEqual(accepted?.url, proposed.url)
        XCTAssertFalse(try XCTUnwrap(accepted).httpShouldHandleCookies)
        XCTAssertNil(accepted?.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(accepted?.value(forHTTPHeaderField: "Cookie"))

        let downgrade = URLRequest(url: try XCTUnwrap(URL(string: "http://cdn.example.com/file")))
        XCTAssertNil(URLSessionDownloadTransport.redirectRequest(from: original, to: downgrade))

        let localFile = URLRequest(url: URL(fileURLWithPath: "/tmp/file"))
        XCTAssertNil(URLSessionDownloadTransport.redirectRequest(from: original, to: localFile))

        let credentialURL = try XCTUnwrap(
            URL(string: "https://user:password@cdn.example.com/file")
        )
        XCTAssertNil(URLSessionDownloadTransport.redirectRequest(
            from: original,
            to: URLRequest(url: credentialURL)
        ))
    }

    func testRestoreMapsPersistedTaskReportsOrderedStateAndCompletesOnce() throws {
        let session = URLSession(configuration: .ephemeral)
        let id = UUID()
        let task = session.downloadTask(with: try XCTUnwrap(URL(string: "https://example.com/file")))
        task.taskDescription = id.uuidString
        let record = downloadRecord(id: id, taskIdentifier: task.taskIdentifier)
        var timeline: [String] = []
        let transport = URLSessionDownloadTransport(
            configuration: .ephemeral,
            allTasksProvider: { _, completion in
                completion([task])
                completion([task])
            }
        )
        transport.eventHandler = { event in
            switch event {
            case let .started(eventID, taskIdentifier):
                timeline.append("started:\(eventID):\(taskIdentifier)")
            case let .progress(eventID, received, expected):
                timeline.append("progress:\(eventID):\(received):\(expected.map(String.init) ?? "nil")")
            default:
                timeline.append("unexpected")
            }
        }

        transport.restore(records: [record]) {
            timeline.append("completion")
        }

        XCTAssertEqual(
            timeline,
            [
                "started:\(id):\(task.taskIdentifier)",
                "progress:\(id):0:nil",
                "completion"
            ]
        )
        XCTAssertEqual(task.state, .running)
        XCTAssertEqual(
            task.taskDescription,
            "cyclop-download:v1:\(id.uuidString):fresh"
        )
        task.cancel()
        session.invalidateAndCancel()
        transport.invalidate()
    }

    func testRestorePrefersPersistedIdentifierFailsMissingAndLogsBeforeCancellingOrphans() throws {
        let session = URLSession(configuration: .ephemeral)
        let duplicateID = UUID()
        let missingID = UUID()
        let first = session.downloadTask(with: try XCTUnwrap(URL(string: "https://example.com/one")))
        let preferred = session.downloadTask(with: try XCTUnwrap(URL(string: "https://example.com/two")))
        let orphan = session.downloadTask(with: try XCTUnwrap(URL(string: "https://example.com/orphan")))
        first.taskDescription = duplicateID.uuidString
        preferred.taskDescription = "cyclop-download:v1:\(duplicateID.uuidString):fresh"
        orphan.taskDescription = "cyclop-download:v1:\(UUID().uuidString):fresh"
        var timeline: [String] = []
        let transport = URLSessionDownloadTransport(
            configuration: .ephemeral,
            allTasksProvider: { _, completion in
                completion([first, preferred, orphan])
            },
            logger: { message in timeline.append("log:\(message)") }
        )
        transport.eventHandler = { event in
            switch event {
            case let .started(id, taskIdentifier):
                timeline.append("started:\(id):\(taskIdentifier)")
            case let .failed(id, code, message, resumeData):
                timeline.append("failed:\(id):\(code):\(message):\(resumeData == nil)")
            default:
                break
            }
        }

        transport.restore(
            records: [
                downloadRecord(id: duplicateID, taskIdentifier: preferred.taskIdentifier),
                downloadRecord(id: missingID, taskIdentifier: 99_999)
            ]
        ) {
            timeline.append("completion")
        }

        XCTAssertTrue(timeline.contains("started:\(duplicateID):\(preferred.taskIdentifier)"))
        XCTAssertTrue(timeline.contains("failed:\(missingID):task-lost:Фоновая задача не найдена:true"))
        let firstLog = try XCTUnwrap(timeline.firstIndex(where: { $0.hasPrefix("log:") }))
        let completion = try XCTUnwrap(timeline.firstIndex(of: "completion"))
        XCTAssertLessThan(firstLog, completion)
        XCTAssertEqual(first.state, .canceling)
        XCTAssertEqual(orphan.state, .canceling)
        XCTAssertEqual(preferred.state, .running)
        preferred.cancel()
        session.invalidateAndCancel()
        transport.invalidate()
    }

    func testStartWritesExactVersionedOriginForFreshAndResumeTasks() throws {
        DownloadStubURLProtocol.setPlan(.hold, forPath: "/descriptor-fresh")
        DownloadStubURLProtocol.setPlan(.hold, forPath: "/descriptor-resume")
        let configuration = URLSessionDownloadTransport.makeTestConfiguration()
        configuration.protocolClasses = [DownloadStubURLProtocol.self]
        var createdTasks: [URLSessionDownloadTask] = []
        let transport = URLSessionDownloadTransport(
            configuration: configuration,
            downloadTaskFactory: { session, url, _ in
                let task = session.downloadTask(
                    with: URLSessionDownloadTransport.makeRequest(url)
                )
                createdTasks.append(task)
                return task
            }
        )
        let freshID = UUID()
        let resumeID = UUID()

        transport.start(
            id: freshID,
            url: try XCTUnwrap(URL(string: "https://example.com/descriptor-fresh")),
            resumeData: nil
        )
        transport.start(
            id: resumeID,
            url: try XCTUnwrap(URL(string: "https://example.com/descriptor-resume")),
            resumeData: Data([1])
        )

        XCTAssertEqual(createdTasks.map(\.taskDescription), [
            "cyclop-download:v1:\(freshID.uuidString):fresh",
            "cyclop-download:v1:\(resumeID.uuidString):resume"
        ])
        createdTasks.forEach { $0.cancel() }
        transport.invalidate()
    }

    func testRestoredStructuredResumeGetsOneFallbackWithFallbackDescriptor() async throws {
        DownloadStubURLProtocol.setPlan(.hold, forPath: "/restored-resume")
        let restoredConfiguration = URLSessionDownloadTransport.makeTestConfiguration()
        restoredConfiguration.protocolClasses = [DownloadStubURLProtocol.self]
        let restoredSession = URLSession(configuration: restoredConfiguration)
        let id = UUID()
        DownloadStubURLProtocol.setPlan(.hold, forPath: "/\(id.uuidString).zip")
        let restoredTask = restoredSession.downloadTask(
            with: try XCTUnwrap(URL(string: "https://example.com/restored-resume"))
        )
        restoredTask.taskDescription = "cyclop-download:v1:\(id.uuidString):resume"

        let transportConfiguration = URLSessionDownloadTransport.makeTestConfiguration()
        transportConfiguration.protocolClasses = [DownloadStubURLProtocol.self]
        var fallbackTasks: [URLSessionDownloadTask] = []
        let transport = URLSessionDownloadTransport(
            configuration: transportConfiguration,
            downloadTaskFactory: { session, url, _ in
                let task = session.downloadTask(
                    with: URLSessionDownloadTransport.makeRequest(url)
                )
                fallbackTasks.append(task)
                return task
            },
            allTasksProvider: { _, completion in completion([restoredTask]) }
        )
        var events: [DownloadTransportEvent] = []
        transport.eventHandler = { events.append($0) }

        transport.restore(
            records: [downloadRecord(id: id, taskIdentifier: restoredTask.taskIdentifier)],
            completion: {}
        )
        transport.urlSession(
            restoredSession,
            task: restoredTask,
            didCompleteWithError: NSError(
                domain: NSURLErrorDomain,
                code: NSURLErrorCannotDecodeRawData
            )
        )
        await Task.yield()

        XCTAssertEqual(fallbackTasks.count, 1)
        XCTAssertEqual(
            fallbackTasks.first?.taskDescription,
            "cyclop-download:v1:\(id.uuidString):fallback"
        )
        XCTAssertFalse(events.contains { if case .failed = $0 { return true }; return false })
        restoredTask.cancel()
        fallbackTasks.forEach { $0.cancel() }
        restoredSession.invalidateAndCancel()
        transport.invalidate()
    }

    func testRestoredStructuredFallbackRejectsEarlyFailureWithoutSecondFallback() async throws {
        DownloadStubURLProtocol.setPlan(.hold, forPath: "/restored-fallback")
        let restoredConfiguration = URLSessionDownloadTransport.makeTestConfiguration()
        restoredConfiguration.protocolClasses = [DownloadStubURLProtocol.self]
        let restoredSession = URLSession(configuration: restoredConfiguration)
        let id = UUID()
        DownloadStubURLProtocol.setPlan(.hold, forPath: "/\(id.uuidString).zip")
        let restoredTask = restoredSession.downloadTask(
            with: try XCTUnwrap(URL(string: "https://example.com/restored-fallback"))
        )
        restoredTask.taskDescription = "cyclop-download:v1:\(id.uuidString):fallback"
        var createdTaskCount = 0
        let transportConfiguration = URLSessionDownloadTransport.makeTestConfiguration()
        transportConfiguration.protocolClasses = [DownloadStubURLProtocol.self]
        let transport = URLSessionDownloadTransport(
            configuration: transportConfiguration,
            downloadTaskFactory: { session, url, _ in
                createdTaskCount += 1
                return session.downloadTask(
                    with: URLSessionDownloadTransport.makeRequest(url)
                )
            },
            allTasksProvider: { _, completion in completion([restoredTask]) }
        )
        let terminal = expectation(description: "relaunch fallback terminal")
        var terminalEvent: DownloadTransportEvent?
        transport.eventHandler = { event in
            if event.isTerminal {
                terminalEvent = event
                terminal.fulfill()
            }
        }

        transport.restore(
            records: [downloadRecord(id: id, taskIdentifier: restoredTask.taskIdentifier)],
            completion: {}
        )
        transport.urlSession(
            restoredSession,
            task: restoredTask,
            didCompleteWithError: NSError(
                domain: NSURLErrorDomain,
                code: NSURLErrorCannotDecodeRawData
            )
        )
        await fulfillment(of: [terminal], timeout: 2)

        XCTAssertEqual(createdTaskCount, 0)
        XCTAssertEqual(terminalEvent, .failed(
            id: id,
            code: "cannot-resume",
            message: "Не удалось продолжить или начать загрузку заново",
            resumeData: nil
        ))
        restoredTask.cancel()
        restoredSession.invalidateAndCancel()
        transport.invalidate()
    }

    func testLegacyUUIDDescriptorInfersResumeOnlyFromUsablePersistedResumeData() async throws {
        DownloadStubURLProtocol.setPlan(.hold, forPath: "/legacy-resume")
        let restoredConfiguration = URLSessionDownloadTransport.makeTestConfiguration()
        restoredConfiguration.protocolClasses = [DownloadStubURLProtocol.self]
        let restoredSession = URLSession(configuration: restoredConfiguration)
        let id = UUID()
        let restoredTask = restoredSession.downloadTask(
            with: try XCTUnwrap(URL(string: "https://example.com/legacy-resume"))
        )
        restoredTask.taskDescription = id.uuidString
        var fallbackTasks: [URLSessionDownloadTask] = []
        let transport = URLSessionDownloadTransport(
            configuration: URLSessionDownloadTransport.makeTestConfiguration(),
            downloadTaskFactory: { session, url, _ in
                let task = session.downloadTask(
                    with: URLSessionDownloadTransport.makeRequest(url)
                )
                fallbackTasks.append(task)
                return task
            },
            allTasksProvider: { _, completion in completion([restoredTask]) }
        )

        transport.restore(
            records: [downloadRecord(
                id: id,
                taskIdentifier: restoredTask.taskIdentifier,
                resumeData: Data([9])
            )],
            completion: {}
        )
        XCTAssertEqual(
            restoredTask.taskDescription,
            "cyclop-download:v1:\(id.uuidString):resume"
        )
        transport.urlSession(
            restoredSession,
            task: restoredTask,
            didCompleteWithError: NSError(
                domain: NSURLErrorDomain,
                code: NSURLErrorCannotDecodeRawData
            )
        )
        await Task.yield()

        XCTAssertEqual(fallbackTasks.count, 1)
        XCTAssertEqual(
            fallbackTasks.first?.taskDescription,
            "cyclop-download:v1:\(id.uuidString):fallback"
        )
        restoredTask.cancel()
        fallbackTasks.forEach { $0.cancel() }
        restoredSession.invalidateAndCancel()
        transport.invalidate()
    }

    func testRepeatedRestoreForgetsPreviousDuplicateMappingBeforeOrphanCancellation() async throws {
        DownloadStubURLProtocol.setPlan(.hold, forPath: "/first")
        DownloadStubURLProtocol.setPlan(.hold, forPath: "/replacement")
        let configuration = URLSessionDownloadTransport.makeTestConfiguration()
        configuration.protocolClasses = [DownloadStubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let id = UUID()
        let first = session.downloadTask(with: try XCTUnwrap(URL(string: "https://example.com/first")))
        let replacement = session.downloadTask(with: try XCTUnwrap(URL(string: "https://example.com/replacement")))
        first.taskDescription = id.uuidString
        replacement.taskDescription = id.uuidString
        var batches: [[URLSessionTask]] = [[first], [first, replacement]]
        let transport = URLSessionDownloadTransport(
            configuration: .ephemeral,
            allTasksProvider: { _, completion in completion(batches.removeFirst()) }
        )
        var events: [DownloadTransportEvent] = []
        transport.eventHandler = { events.append($0) }

        transport.restore(
            records: [downloadRecord(id: id, taskIdentifier: first.taskIdentifier)],
            completion: {}
        )
        transport.restore(
            records: [downloadRecord(id: id, taskIdentifier: replacement.taskIdentifier)],
            completion: {}
        )
        events.removeAll()

        transport.urlSession(
            session,
            task: first,
            didCompleteWithError: NSError(
                domain: NSURLErrorDomain,
                code: NSURLErrorCancelled
            )
        )
        await Task.yield()

        XCTAssertTrue(events.isEmpty)
        XCTAssertNotEqual(first.state, .running)
        XCTAssertEqual(replacement.state, .running)
        replacement.cancel()
        session.invalidateAndCancel()
        transport.invalidate()
    }

    func testTaskLostRestoreRemovesStaleTaskSoCancelConfirmsImmediately() throws {
        DownloadStubURLProtocol.setPlan(.hold, forPath: "/stale-missing")
        let configuration = URLSessionDownloadTransport.makeTestConfiguration()
        configuration.protocolClasses = [DownloadStubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let id = UUID()
        let stale = session.downloadTask(
            with: try XCTUnwrap(URL(string: "https://example.com/stale-missing"))
        )
        stale.taskDescription = id.uuidString
        var batches: [[URLSessionTask]] = [[stale], []]
        let transport = URLSessionDownloadTransport(
            configuration: .ephemeral,
            allTasksProvider: { _, completion in completion(batches.removeFirst()) }
        )
        let record = downloadRecord(id: id, taskIdentifier: stale.taskIdentifier)
        var events: [DownloadTransportEvent] = []
        transport.eventHandler = { events.append($0) }

        transport.restore(records: [record], completion: {})
        transport.restore(records: [record], completion: {})
        events.removeAll()

        transport.cancel(id: id)

        XCTAssertEqual(events, [.cancelled(id: id)])
        stale.cancel()
        session.invalidateAndCancel()
        transport.invalidate()
    }

    func testDefaultAsynchronousRestoreCompletesOnMainActorExactlyOnce() async {
        let transport = URLSessionDownloadTransport(
            configuration: URLSessionDownloadTransport.makeTestConfiguration()
        )
        let restored = expectation(description: "restore")
        var completionCount = 0

        transport.restore(records: []) {
            XCTAssertTrue(Thread.isMainThread)
            completionCount += 1
            restored.fulfill()
        }
        await fulfillment(of: [restored], timeout: 2)

        XCTAssertEqual(completionCount, 1)
        transport.invalidate()
    }

    func testStaleOverlappingRestoreCompletesOnceWithoutPublishingOldEvents() {
        var providers: [@MainActor ([URLSessionTask]) -> Void] = []
        let transport = URLSessionDownloadTransport(
            configuration: URLSessionDownloadTransport.makeTestConfiguration(),
            allTasksProvider: { _, completion in providers.append(completion) }
        )
        var timeline: [String] = []
        transport.eventHandler = { _ in timeline.append("event") }

        transport.restore(records: [downloadRecord(id: UUID(), taskIdentifier: 1)]) {
            timeline.append("first")
        }
        transport.restore(records: []) {
            timeline.append("second")
        }
        XCTAssertEqual(providers.count, 2)

        providers[0]([])
        providers[0]([])
        providers[1]([])
        providers[1]([])

        XCTAssertEqual(timeline, ["first", "second"])
        transport.invalidate()
    }

    func testUnsupportedSchemeFailsWithoutCreatingSessionTask() throws {
        var taskCreationCount = 0
        let transport = URLSessionDownloadTransport(
            configuration: URLSessionDownloadTransport.makeTestConfiguration(),
            downloadTaskFactory: { session, url, _ in
                taskCreationCount += 1
                return session.downloadTask(with: url)
            }
        )
        let ids = [UUID(), UUID(), UUID()]
        var events: [DownloadTransportEvent] = []
        transport.eventHandler = { events.append($0) }

        transport.start(
            id: ids[0],
            url: try XCTUnwrap(URL(string: "ftp://example.com/file")),
            resumeData: nil
        )
        transport.start(
            id: ids[1],
            url: try XCTUnwrap(URL(string: "https://user:password@example.com/file")),
            resumeData: Data([1])
        )
        transport.start(
            id: ids[2],
            url: try XCTUnwrap(URL(string: "https:///missing-host")),
            resumeData: nil
        )

        XCTAssertEqual(taskCreationCount, 0)
        XCTAssertEqual(events, ids.map {
            .failed(
                id: $0,
                code: "invalid-url",
                message: "Ссылка для загрузки недействительна или содержит данные входа",
                resumeData: nil
            )
        })
        transport.invalidate()
    }

    func testUnknownAndOutOfOrderDelegateCallbacksAreNoOps() throws {
        let transport = makeProtocolTransport()
        let session = URLSession(configuration: .ephemeral)
        let task = session.downloadTask(
            with: try XCTUnwrap(URL(string: "https://example.net/unknown"))
        )
        var events: [DownloadTransportEvent] = []
        transport.eventHandler = { events.append($0) }

        transport.urlSession(
            session,
            downloadTask: task,
            didWriteData: 10,
            totalBytesWritten: 10,
            totalBytesExpectedToWrite: 100
        )
        transport.urlSession(
            session,
            downloadTask: task,
            didFinishDownloadingTo: URL(fileURLWithPath: "/tmp/unknown")
        )
        transport.urlSession(
            session,
            task: task,
            didCompleteWithError: NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        )

        XCTAssertTrue(events.isEmpty)
        task.cancel()
        session.invalidateAndCancel()
        transport.invalidate()
    }

    func testHTTP200KnownLengthHandsTemporaryFileToMainActorSynchronously() async throws {
        let body = Data("payload".utf8)
        DownloadStubURLProtocol.setPlan(
            .response(status: 200, headers: ["Content-Length": "\(body.count)"], body: body),
            forPath: "/known"
        )
        let transport = makeProtocolTransport()
        let id = UUID()
        let terminal = expectation(description: "finished")
        var events: [DownloadTransportEvent] = []
        var handedOffData: Data?
        transport.eventHandler = { event in
            events.append(event)
            if case let .finished(eventID, temporaryURL, suggestedFilename) = event {
                XCTAssertEqual(eventID, id)
                handedOffData = try? Data(contentsOf: temporaryURL)
                XCTAssertEqual(suggestedFilename, "known")
                terminal.fulfill()
            }
        }

        transport.start(
            id: id,
            url: try XCTUnwrap(URL(string: "https://example.com/known")),
            resumeData: nil
        )
        await fulfillment(of: [terminal], timeout: 2)

        XCTAssertEqual(handedOffData, body)
        XCTAssertEqual(events.first, .started(id: id, taskIdentifier: 1))
        XCTAssertTrue(events.contains(.progress(id: id, received: Int64(body.count), expected: Int64(body.count))))
        XCTAssertEqual(events.filter(\.isTerminal).count, 1)
        transport.invalidate()
    }

    func testHTTP200UnknownLengthReportsIndeterminateProgressAndFinishesOnce() async throws {
        let body = Data("unknown".utf8)
        DownloadStubURLProtocol.setPlan(
            .response(status: 200, headers: [:], body: body),
            forPath: "/unknown"
        )
        let transport = makeProtocolTransport()
        let id = UUID()
        let terminal = expectation(description: "finished")
        var events: [DownloadTransportEvent] = []
        transport.eventHandler = { event in
            events.append(event)
            if event.isTerminal { terminal.fulfill() }
        }

        transport.start(
            id: id,
            url: try XCTUnwrap(URL(string: "https://example.com/unknown")),
            resumeData: nil
        )
        await fulfillment(of: [terminal], timeout: 2)

        XCTAssertTrue(events.contains(.progress(id: id, received: Int64(body.count), expected: nil)))
        XCTAssertEqual(events.filter(\.isTerminal).count, 1)
        guard case .finished = try XCTUnwrap(events.last) else {
            return XCTFail("Ожидалось успешное завершение")
        }
        transport.invalidate()
    }

    func testHTTP404And500EachProduceOneStableFailureWithoutFinish() async throws {
        for status in [404, 500] {
            let path = "/status-\(status)"
            DownloadStubURLProtocol.setPlan(
                .response(status: status, headers: [:], body: Data("error".utf8)),
                forPath: path
            )
            let transport = makeProtocolTransport()
            let id = UUID()
            let terminal = expectation(description: "http-\(status)")
            var events: [DownloadTransportEvent] = []
            transport.eventHandler = { event in
                events.append(event)
                if event.isTerminal { terminal.fulfill() }
            }

            transport.start(
                id: id,
                url: try XCTUnwrap(URL(string: "https://example.com\(path)")),
                resumeData: nil
            )
            await fulfillment(of: [terminal], timeout: 2)

            XCTAssertEqual(events.filter(\.isTerminal).count, 1)
            XCTAssertFalse(events.contains { if case .finished = $0 { return true }; return false })
            XCTAssertTrue(events.contains(.failed(
                id: id,
                code: "http-\(status)",
                message: "Сервер вернул ошибку \(status)",
                resumeData: nil
            )))
            transport.invalidate()
        }
    }

    func testEphemeralHTTPSRedirectRunsThroughSanitizedDelegateAndFinishesOnce() async throws {
        DownloadStubURLProtocol.setPlan(
            .redirect(try XCTUnwrap(URL(string: "https://example.com/redirected"))),
            forPath: "/redirect"
        )
        DownloadStubURLProtocol.setPlan(
            .response(status: 200, headers: [:], body: Data("redirected".utf8)),
            forPath: "/redirected"
        )
        let transport = makeProtocolTransport()
        let id = UUID()
        let terminal = expectation(description: "redirect finished")
        var events: [DownloadTransportEvent] = []
        transport.eventHandler = { event in
            XCTAssertTrue(Thread.isMainThread)
            events.append(event)
            if event.isTerminal { terminal.fulfill() }
        }

        transport.start(
            id: id,
            url: try XCTUnwrap(URL(string: "https://example.com/redirect")),
            resumeData: nil
        )
        await fulfillment(of: [terminal], timeout: 2)

        XCTAssertEqual(events.filter(\.isTerminal).count, 1)
        guard case .finished = try XCTUnwrap(events.last) else {
            return XCTFail("Ожидалось завершение после HTTPS redirect")
        }
        transport.invalidate()
    }

    func testUnsafeFinalRedirectURLFailsExactlyOnceWithoutTemporaryFileHandoff() async throws {
        let unsafeFinalURLs = [
            try XCTUnwrap(URL(string: "http://example.com/downgraded")),
            try XCTUnwrap(URL(string: "https://user:password@example.com/private")),
            try XCTUnwrap(URL(string: "ftp://example.com/file")),
            try XCTUnwrap(URL(string: "https:///missing-host"))
        ]

        for (index, unsafeFinalURL) in unsafeFinalURLs.enumerated() {
            let path = "/unsafe-final-\(index)"
            DownloadStubURLProtocol.setPlan(
                .response(status: 200, headers: [:], body: Data("payload".utf8)),
                forPath: path
            )
            let configuration = URLSessionDownloadTransport.makeTestConfiguration()
            configuration.protocolClasses = [DownloadStubURLProtocol.self]
            let transport = URLSessionDownloadTransport(
                configuration: configuration,
                finalURLProvider: { _, _ in unsafeFinalURL }
            )
            let id = UUID()
            let terminal = expectation(description: "unsafe final URL \(index)")
            var events: [DownloadTransportEvent] = []
            transport.eventHandler = { event in
                events.append(event)
                if event.isTerminal { terminal.fulfill() }
            }

            transport.start(
                id: id,
                url: try XCTUnwrap(URL(string: "https://example.com\(path)")),
                resumeData: nil
            )
            await fulfillment(of: [terminal], timeout: 2)
            await Task.yield()

            XCTAssertEqual(events.filter(\.isTerminal), [.failed(
                id: id,
                code: "unsafe-redirect",
                message: "Загрузка отклонена из-за небезопасного перенаправления",
                resumeData: nil
            )])
            XCTAssertFalse(events.contains {
                if case .finished = $0 { return true }
                return false
            })
            transport.invalidate()
        }
    }

    func testNetworkInterruptionPreservesResumeDataWhenFoundationProvidesIt() async throws {
        let resumeData = Data([1, 2, 3, 4])
        DownloadStubURLProtocol.setPlan(
            .failure(NSError(
                domain: NSURLErrorDomain,
                code: NSURLErrorNetworkConnectionLost,
                userInfo: ["NSURLSessionDownloadTaskResumeData": resumeData]
            )),
            forPath: "/interrupted"
        )
        DownloadStubURLProtocol.setPlan(
            .failure(NSError(
                domain: NSURLErrorDomain,
                code: NSURLErrorTimedOut
            )),
            forPath: "/timeout"
        )
        let transport = makeProtocolTransport()
        let firstID = UUID()
        let secondID = UUID()
        let terminals = expectation(description: "network failures")
        terminals.expectedFulfillmentCount = 2
        var events: [DownloadTransportEvent] = []
        transport.eventHandler = { event in
            events.append(event)
            if event.isTerminal { terminals.fulfill() }
        }

        transport.start(
            id: firstID,
            url: try XCTUnwrap(URL(string: "https://example.com/interrupted")),
            resumeData: nil
        )
        transport.start(
            id: secondID,
            url: try XCTUnwrap(URL(string: "https://example.com/timeout")),
            resumeData: nil
        )
        await fulfillment(of: [terminals], timeout: 2)

        XCTAssertTrue(events.contains(.failed(
            id: firstID,
            code: "network",
            message: "Сетевое соединение прервано",
            resumeData: resumeData
        )))
        XCTAssertTrue(events.contains(.failed(
            id: secondID,
            code: "network",
            message: "Превышено время ожидания загрузки",
            resumeData: nil
        )))
        XCTAssertEqual(events.filter(\.isTerminal).count, 2)
        transport.invalidate()
    }

    func testResumeFallbackClassifierRejectsConfirmedNetworkSecurityAndRetainedResumeFailures() {
        let rejection = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorCannotDecodeRawData
        )
        XCTAssertTrue(URLSessionDownloadTransport.shouldFallbackFromResumeAttempt(
            error: rejection,
            hasResponse: false,
            hasResumeData: false,
            resumeConfirmed: false
        ))
        XCTAssertFalse(URLSessionDownloadTransport.shouldFallbackFromResumeAttempt(
            error: rejection,
            hasResponse: true,
            hasResumeData: false,
            resumeConfirmed: false
        ))
        XCTAssertFalse(URLSessionDownloadTransport.shouldFallbackFromResumeAttempt(
            error: rejection,
            hasResponse: false,
            hasResumeData: true,
            resumeConfirmed: false
        ))
        XCTAssertFalse(URLSessionDownloadTransport.shouldFallbackFromResumeAttempt(
            error: rejection,
            hasResponse: false,
            hasResumeData: false,
            resumeConfirmed: true
        ))

        let excludedCodes = [
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
        for code in excludedCodes {
            XCTAssertFalse(URLSessionDownloadTransport.shouldFallbackFromResumeAttempt(
                error: NSError(domain: NSURLErrorDomain, code: code),
                hasResponse: false,
                hasResumeData: false,
                resumeConfirmed: false
            ), "Код \(code) не должен запускать fresh fallback")
        }
    }

    func testRejectedResumeFallsBackToOneFreshTaskWithoutIntermediateFailure() async throws {
        let rejection = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotDecodeRawData)
        DownloadStubURLProtocol.setPlans([
            .failure(rejection),
            .response(status: 200, headers: [:], body: Data("fresh".utf8))
        ], forPath: "/resume-fallback")
        var createdTaskIdentifiers: [Int] = []
        let transport = makeProtocolTransport { session, url, _ in
            let task = session.downloadTask(with: URLSessionDownloadTransport.makeRequest(url))
            createdTaskIdentifiers.append(task.taskIdentifier)
            return task
        }
        let id = UUID()
        let terminal = expectation(description: "fresh finish")
        var events: [DownloadTransportEvent] = []
        transport.eventHandler = { event in
            events.append(event)
            if event.isTerminal { terminal.fulfill() }
        }

        transport.start(
            id: id,
            url: try XCTUnwrap(URL(string: "https://example.com/resume-fallback")),
            resumeData: Data([9])
        )
        await fulfillment(of: [terminal], timeout: 2)

        XCTAssertEqual(createdTaskIdentifiers.count, 2)
        XCTAssertEqual(events.filter { if case .failed = $0 { return true }; return false }.count, 0)
        XCTAssertEqual(events.filter(\.isTerminal).count, 1)
        XCTAssertEqual(events.first, .started(id: id, taskIdentifier: createdTaskIdentifiers[1]))
        transport.invalidate()
    }

    func testRejectedOpaqueResumeUsesPersistedRequestedURLForFreshFallback() async throws {
        let rejection = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotDecodeRawData)
        DownloadStubURLProtocol.setPlan(.failure(rejection), forPath: "/opaque-placeholder")
        DownloadStubURLProtocol.setPlan(
            .response(status: 200, headers: [:], body: Data("requested".utf8)),
            forPath: "/requested-after-resume"
        )
        let requestedURL = try XCTUnwrap(
            URL(string: "https://example.com/requested-after-resume")
        )
        var createdURLs: [URL] = []
        let transport = makeProtocolTransport { session, url, resumeData in
            let actualURL: URL
            if resumeData != nil {
                actualURL = URL(string: "https://example.com/opaque-placeholder")!
            } else {
                actualURL = url
            }
            createdURLs.append(actualURL)
            return session.downloadTask(
                with: URLSessionDownloadTransport.makeRequest(actualURL)
            )
        }
        let id = UUID()
        let terminal = expectation(description: "opaque resume fallback")
        var terminalEvent: DownloadTransportEvent?
        transport.eventHandler = { event in
            if event.isTerminal {
                terminalEvent = event
                terminal.fulfill()
            }
        }

        transport.start(id: id, url: requestedURL, resumeData: Data([5]))
        await fulfillment(of: [terminal], timeout: 2)

        XCTAssertEqual(createdURLs, [
            URL(string: "https://example.com/opaque-placeholder")!,
            requestedURL
        ])
        guard case .finished = terminalEvent else {
            return XCTFail("Fresh fallback должен использовать исходный requested URL")
        }
        transport.invalidate()
    }

    func testSecondResumeRejectionAfterFreshFallbackIsTerminalWithoutThirdTask() async throws {
        let rejection = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotDecodeRawData)
        DownloadStubURLProtocol.setPlans([.failure(rejection), .failure(rejection)], forPath: "/resume-twice")
        var createdTaskCount = 0
        let transport = makeProtocolTransport { session, url, _ in
            createdTaskCount += 1
            return session.downloadTask(with: URLSessionDownloadTransport.makeRequest(url))
        }
        let id = UUID()
        let terminal = expectation(description: "cannot resume")
        var terminalEvent: DownloadTransportEvent?
        transport.eventHandler = { event in
            if event.isTerminal {
                terminalEvent = event
                terminal.fulfill()
            }
        }

        transport.start(
            id: id,
            url: try XCTUnwrap(URL(string: "https://example.com/resume-twice")),
            resumeData: Data([8])
        )
        await fulfillment(of: [terminal], timeout: 2)

        XCTAssertEqual(createdTaskCount, 2)
        XCTAssertEqual(terminalEvent, .failed(
            id: id,
            code: "cannot-resume",
            message: "Не удалось продолжить или начать загрузку заново",
            resumeData: nil
        ))
        transport.invalidate()
    }

    func testResumeErrorContainingNonDataResumePayloadDoesNotStartFreshFallback() async throws {
        DownloadStubURLProtocol.setPlan(.hold, forPath: "/resume-payload-present")
        var createdTask: URLSessionDownloadTask?
        var createdTaskCount = 0
        let transport = makeProtocolTransport { session, url, _ in
            createdTaskCount += 1
            let task = session.downloadTask(with: URLSessionDownloadTransport.makeRequest(url))
            createdTask = task
            return task
        }
        let id = UUID()
        let terminal = expectation(description: "resume payload key is terminal")
        var terminalEvent: DownloadTransportEvent?
        transport.eventHandler = { event in
            if event.isTerminal {
                terminalEvent = event
                terminal.fulfill()
            }
        }
        transport.start(
            id: id,
            url: try XCTUnwrap(URL(string: "https://example.com/resume-payload-present")),
            resumeData: Data([3])
        )

        transport.urlSession(
            URLSession.shared,
            task: try XCTUnwrap(createdTask),
            didCompleteWithError: NSError(
                domain: NSURLErrorDomain,
                code: NSURLErrorCannotDecodeRawData,
                userInfo: ["NSURLSessionDownloadTaskResumeData": "повреждено"]
            )
        )
        await fulfillment(of: [terminal], timeout: 2)

        XCTAssertEqual(createdTaskCount, 1)
        XCTAssertEqual(terminalEvent, .failed(
            id: id,
            code: "network",
            message: "Не удалось скачать файл из-за ошибки сети",
            resumeData: nil
        ))
        transport.invalidate()
    }

    func testDidResumeConfirmationPreventsFreshFallback() async throws {
        DownloadStubURLProtocol.setPlans([.hold], forPath: "/confirmed-resume")
        var createdTask: URLSessionDownloadTask?
        var createdTaskCount = 0
        let transport = makeProtocolTransport { session, url, _ in
            createdTaskCount += 1
            let task = session.downloadTask(with: URLSessionDownloadTransport.makeRequest(url))
            createdTask = task
            return task
        }
        let id = UUID()
        let terminal = expectation(description: "confirmed resume failure")
        var events: [DownloadTransportEvent] = []
        transport.eventHandler = { event in
            events.append(event)
            if event.isTerminal { terminal.fulfill() }
        }
        transport.start(
            id: id,
            url: try XCTUnwrap(URL(string: "https://example.com/confirmed-resume")),
            resumeData: Data([7])
        )
        let task = try XCTUnwrap(createdTask)

        transport.urlSession(
            URLSession.shared,
            downloadTask: task,
            didResumeAtOffset: 25,
            expectedTotalBytes: 100
        )
        transport.urlSession(
            URLSession.shared,
            task: task,
            didCompleteWithError: NSError(
                domain: NSURLErrorDomain,
                code: NSURLErrorCannotDecodeRawData
            )
        )
        await fulfillment(of: [terminal], timeout: 2)

        XCTAssertEqual(createdTaskCount, 1)
        XCTAssertTrue(events.contains(.progress(id: id, received: 25, expected: 100)))
        XCTAssertTrue(events.contains(.failed(
            id: id,
            code: "network",
            message: "Не удалось скачать файл из-за ошибки сети",
            resumeData: nil
        )))
        transport.invalidate()
    }

    func testProgressConfirmationPreventsFreshFallback() async throws {
        DownloadStubURLProtocol.setPlans([.hold], forPath: "/progress-confirmed-resume")
        var createdTask: URLSessionDownloadTask?
        var createdTaskCount = 0
        let transport = makeProtocolTransport { session, url, _ in
            createdTaskCount += 1
            let task = session.downloadTask(with: URLSessionDownloadTransport.makeRequest(url))
            createdTask = task
            return task
        }
        let id = UUID()
        let terminal = expectation(description: "progress-confirmed failure")
        var events: [DownloadTransportEvent] = []
        transport.eventHandler = { event in
            events.append(event)
            if event.isTerminal { terminal.fulfill() }
        }
        transport.start(
            id: id,
            url: try XCTUnwrap(URL(string: "https://example.com/progress-confirmed-resume")),
            resumeData: Data([6])
        )
        let task = try XCTUnwrap(createdTask)

        transport.urlSession(
            URLSession.shared,
            downloadTask: task,
            didWriteData: 10,
            totalBytesWritten: 10,
            totalBytesExpectedToWrite: 100
        )
        transport.urlSession(
            URLSession.shared,
            task: task,
            didCompleteWithError: NSError(
                domain: NSURLErrorDomain,
                code: NSURLErrorCannotDecodeRawData
            )
        )
        await fulfillment(of: [terminal], timeout: 2)

        XCTAssertEqual(createdTaskCount, 1)
        XCTAssertTrue(events.contains(.progress(id: id, received: 10, expected: 100)))
        XCTAssertTrue(events.contains(.failed(
            id: id,
            code: "network",
            message: "Не удалось скачать файл из-за ошибки сети",
            resumeData: nil
        )))
        transport.invalidate()
    }

    func testPauseProducesOnePausedEventAndSuppressesCancelledCompletionFailure() async throws {
        DownloadStubURLProtocol.setPlans([.hold], forPath: "/pause")
        let resumeData = Data([4, 3, 2, 1])
        let transport = makeProtocolTransport(
            pauseOperation: { task, completion in
                task.cancel()
                completion(resumeData)
            }
        )
        let id = UUID()
        let paused = expectation(description: "paused")
        var events: [DownloadTransportEvent] = []
        transport.eventHandler = { event in
            events.append(event)
            if case .paused = event { paused.fulfill() }
        }
        transport.start(
            id: id,
            url: try XCTUnwrap(URL(string: "https://example.com/pause")),
            resumeData: nil
        )

        transport.pause(id: id)
        await fulfillment(of: [paused], timeout: 2)

        XCTAssertEqual(
            events.filter { if case .paused = $0 { return true }; return false },
            [.paused(id: id, resumeData: resumeData)]
        )
        XCTAssertFalse(events.contains { if case .failed = $0 { return true }; return false })
        XCTAssertFalse(events.contains { if case .cancelled = $0 { return true }; return false })
        transport.invalidate()
    }

    func testCancelWinsWhenFinishArrivesBeforeCancellationAcknowledgement() async throws {
        DownloadStubURLProtocol.setPlan(.hold, forPath: "/cancel-finish-race")
        let configuration = URLSessionDownloadTransport.makeTestConfiguration()
        configuration.protocolClasses = [DownloadStubURLProtocol.self]
        var createdTask: URLSessionDownloadTask?
        let transport = URLSessionDownloadTransport(
            configuration: configuration,
            downloadTaskFactory: { session, url, _ in
                let task = session.downloadTask(
                    with: URLSessionDownloadTransport.makeRequest(url)
                )
                createdTask = task
                return task
            },
            cancelOperation: { _ in }
        )
        let id = UUID()
        var events: [DownloadTransportEvent] = []
        transport.eventHandler = { events.append($0) }
        transport.start(
            id: id,
            url: try XCTUnwrap(URL(string: "https://example.com/cancel-finish-race")),
            resumeData: nil
        )
        let task = try XCTUnwrap(createdTask)

        transport.cancel(id: id)
        transport.urlSession(
            URLSession.shared,
            downloadTask: task,
            didFinishDownloadingTo: URL(fileURLWithPath: "/tmp/cancel-finish-race")
        )
        transport.urlSession(
            URLSession.shared,
            task: task,
            didCompleteWithError: NSError(
                domain: NSURLErrorDomain,
                code: NSURLErrorCancelled
            )
        )
        await Task.yield()

        XCTAssertEqual(events.filter(\.isLifecycleOutcome), [.cancelled(id: id)])
        task.cancel()
        transport.invalidate()
    }

    func testFinishBeforePauseCompletionPublishesOnlyFinishedAndLatePauseCleansUp() async throws {
        DownloadStubURLProtocol.setPlan(.hold, forPath: "/finish-before-pause")
        let responseURL = try XCTUnwrap(URL(string: "https://example.com/finish-before-pause"))
        let response = try XCTUnwrap(HTTPURLResponse(
            url: responseURL,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Disposition": "attachment; filename=file.zip"]
        ))
        let configuration = URLSessionDownloadTransport.makeTestConfiguration()
        configuration.protocolClasses = [DownloadStubURLProtocol.self]
        var createdTask: URLSessionDownloadTask?
        var pauseCompletion: (@Sendable (Data?) -> Void)?
        let transport = URLSessionDownloadTransport(
            configuration: configuration,
            downloadTaskFactory: { session, url, _ in
                let task = session.downloadTask(
                    with: URLSessionDownloadTransport.makeRequest(url)
                )
                createdTask = task
                return task
            },
            pauseOperation: { _, completion in pauseCompletion = completion },
            responseProvider: { _ in response }
        )
        let id = UUID()
        var events: [DownloadTransportEvent] = []
        transport.eventHandler = { events.append($0) }
        transport.start(id: id, url: responseURL, resumeData: nil)
        let task = try XCTUnwrap(createdTask)

        transport.pause(id: id)
        transport.urlSession(
            URLSession.shared,
            downloadTask: task,
            didFinishDownloadingTo: URL(fileURLWithPath: "/tmp/finish-before-pause")
        )
        pauseCompletion?(Data([4]))
        await Task.yield()
        transport.urlSession(URLSession.shared, task: task, didCompleteWithError: nil)
        await Task.yield()

        XCTAssertEqual(events.filter(\.isLifecycleOutcome), [
            .finished(
                id: id,
                temporaryURL: URL(fileURLWithPath: "/tmp/finish-before-pause"),
                suggestedFilename: "file.zip"
            )
        ])
        task.cancel()
        transport.invalidate()
    }

    func testPauseCompletionBeforeFinishPublishesOnlyPausedAndIgnoresLateFile() async throws {
        DownloadStubURLProtocol.setPlan(.hold, forPath: "/pause-before-finish")
        let responseURL = try XCTUnwrap(URL(string: "https://example.com/pause-before-finish"))
        let response = try XCTUnwrap(HTTPURLResponse(
            url: responseURL,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        ))
        let configuration = URLSessionDownloadTransport.makeTestConfiguration()
        configuration.protocolClasses = [DownloadStubURLProtocol.self]
        var createdTask: URLSessionDownloadTask?
        var pauseCompletion: (@Sendable (Data?) -> Void)?
        let transport = URLSessionDownloadTransport(
            configuration: configuration,
            downloadTaskFactory: { session, url, _ in
                let task = session.downloadTask(
                    with: URLSessionDownloadTransport.makeRequest(url)
                )
                createdTask = task
                return task
            },
            pauseOperation: { _, completion in pauseCompletion = completion },
            responseProvider: { _ in response }
        )
        let id = UUID()
        var events: [DownloadTransportEvent] = []
        transport.eventHandler = { events.append($0) }
        transport.start(id: id, url: responseURL, resumeData: nil)
        let task = try XCTUnwrap(createdTask)

        transport.pause(id: id)
        pauseCompletion?(Data([7]))
        await Task.yield()
        transport.urlSession(
            URLSession.shared,
            downloadTask: task,
            didFinishDownloadingTo: URL(fileURLWithPath: "/tmp/pause-before-finish")
        )
        transport.urlSession(URLSession.shared, task: task, didCompleteWithError: nil)
        await Task.yield()

        XCTAssertEqual(events.filter(\.isLifecycleOutcome), [
            .paused(id: id, resumeData: Data([7]))
        ])
        task.cancel()
        transport.invalidate()
    }

    func testCancelMappedTaskPublishesOneCancelledInsteadOfNetworkFailure() async throws {
        DownloadStubURLProtocol.setPlans([.hold], forPath: "/cancel")
        let transport = makeProtocolTransport()
        let id = UUID()
        let cancelled = expectation(description: "cancelled")
        var events: [DownloadTransportEvent] = []
        transport.eventHandler = { event in
            events.append(event)
            if case .cancelled = event { cancelled.fulfill() }
        }
        transport.start(
            id: id,
            url: try XCTUnwrap(URL(string: "https://example.com/cancel")),
            resumeData: nil
        )

        transport.cancel(id: id)
        await fulfillment(of: [cancelled], timeout: 2)

        XCTAssertEqual(events.filter { if case .cancelled = $0 { return true }; return false }, [.cancelled(id: id)])
        XCTAssertFalse(events.contains { if case .failed = $0 { return true }; return false })
        transport.invalidate()
    }

    func testCancelWithoutMappedTaskConfirmsSynchronouslyExactlyOncePerCall() {
        let transport = makeProtocolTransport()
        let id = UUID()
        var events: [DownloadTransportEvent] = []
        transport.eventHandler = { events.append($0) }

        transport.cancel(id: id)

        XCTAssertEqual(events, [.cancelled(id: id)])
        transport.invalidate()
    }

    func testEphemeralRedirectDelegateUsesSanitizedPolicyAndRejectsDowngrade() throws {
        let transport = makeProtocolTransport()
        let task = URLSession.shared.dataTask(
            with: try XCTUnwrap(URL(string: "https://example.com/original"))
        )
        let redirectResponse = HTTPURLResponse(
            url: try XCTUnwrap(URL(string: "https://example.com/original")),
            statusCode: 302,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        var proposed = URLRequest(
            url: try XCTUnwrap(URL(string: "https://cdn.example.com/target"))
        )
        proposed.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
        proposed.setValue("private=1", forHTTPHeaderField: "Cookie")
        var accepted: URLRequest?

        transport.urlSession(
            URLSession.shared,
            task: task,
            willPerformHTTPRedirection: redirectResponse,
            newRequest: proposed,
            completionHandler: { accepted = $0 }
        )

        XCTAssertEqual(accepted?.url, proposed.url)
        XCTAssertNil(accepted?.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(accepted?.value(forHTTPHeaderField: "Cookie"))

        let downgrade = URLRequest(
            url: try XCTUnwrap(URL(string: "http://cdn.example.com/target"))
        )
        transport.urlSession(
            URLSession.shared,
            task: task,
            willPerformHTTPRedirection: redirectResponse,
            newRequest: downgrade,
            completionHandler: { accepted = $0 }
        )
        XCTAssertNil(accepted)
        task.cancel()
        transport.invalidate()
    }

    func testAuthenticationPolicyUsesSystemTrustButRejectsStoredCredentials() {
        XCTAssertEqual(
            URLSessionDownloadTransport.authenticationDisposition(
                for: NSURLAuthenticationMethodServerTrust
            ),
            .performDefaultHandling
        )
        for method in [
            NSURLAuthenticationMethodHTTPBasic,
            NSURLAuthenticationMethodHTTPDigest,
            NSURLAuthenticationMethodDefault,
            NSURLAuthenticationMethodClientCertificate,
            NSURLAuthenticationMethodNTLM,
            NSURLAuthenticationMethodNegotiate
        ] {
            XCTAssertEqual(
                URLSessionDownloadTransport.authenticationDisposition(for: method),
                .rejectProtectionSpace
            )
        }
    }

    func testSessionAuthenticationChallengeAlsoRejectsCredentialLookup() {
        let transport = URLSessionDownloadTransport(
            configuration: URLSessionDownloadTransport.makeTestConfiguration()
        )
        let protectionSpace = URLProtectionSpace(
            host: "example.com",
            port: 443,
            protocol: "https",
            realm: nil,
            authenticationMethod: NSURLAuthenticationMethodHTTPBasic
        )
        let challenge = URLAuthenticationChallenge(
            protectionSpace: protectionSpace,
            proposedCredential: URLCredential(
                user: "stored",
                password: "secret",
                persistence: .forSession
            ),
            previousFailureCount: 0,
            failureResponse: nil,
            error: nil,
            sender: AuthenticationChallengeSenderStub()
        )
        var result: (URLSession.AuthChallengeDisposition, URLCredential?)?

        transport.urlSession(URLSession.shared, didReceive: challenge) {
            result = ($0, $1)
        }

        XCTAssertEqual(result?.0, .rejectProtectionSpace)
        XCTAssertNil(result?.1)
        transport.invalidate()
    }

    func testBackgroundCompletionHandlerReplacementAndDeliveryAreMainActorOneShot() {
        let transport = makeProtocolTransport()
        var timeline: [String] = []
        transport.setBackgroundEventsCompletionHandler {
            timeline.append("old")
        }
        transport.setBackgroundEventsCompletionHandler {
            XCTAssertTrue(Thread.isMainThread)
            timeline.append("new")
        }

        transport.urlSessionDidFinishEvents(forBackgroundURLSession: URLSession.shared)
        transport.urlSessionDidFinishEvents(forBackgroundURLSession: URLSession.shared)

        XCTAssertEqual(timeline, ["new"])
        transport.invalidate()
    }

    private func makeProtocolTransport(
        taskFactory: URLSessionDownloadTransport.DownloadTaskFactory? = nil,
        pauseOperation: URLSessionDownloadTransport.PauseOperation? = nil
    ) -> URLSessionDownloadTransport {
        let configuration = URLSessionDownloadTransport.makeTestConfiguration()
        configuration.protocolClasses = [DownloadStubURLProtocol.self]
        if let taskFactory, let pauseOperation {
            return URLSessionDownloadTransport(
                configuration: configuration,
                downloadTaskFactory: taskFactory,
                pauseOperation: pauseOperation
            )
        }
        if let taskFactory {
            return URLSessionDownloadTransport(
                configuration: configuration,
                downloadTaskFactory: taskFactory
            )
        }
        if let pauseOperation {
            return URLSessionDownloadTransport(
                configuration: configuration,
                pauseOperation: pauseOperation
            )
        }
        return URLSessionDownloadTransport(configuration: configuration)
    }
}

private final class AuthenticationChallengeSenderStub: NSObject,
    URLAuthenticationChallengeSender {
    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
    func cancel(_ challenge: URLAuthenticationChallenge) {}
    func performDefaultHandling(for challenge: URLAuthenticationChallenge) {}
    func rejectProtectionSpaceAndContinue(with challenge: URLAuthenticationChallenge) {}
}

private extension DownloadTransportEvent {
    var isTerminal: Bool {
        switch self {
        case .cancelled, .finished, .failed:
            return true
        case .started, .progress, .paused:
            return false
        }
    }

    var isLifecycleOutcome: Bool {
        switch self {
        case .paused, .cancelled, .finished, .failed:
            return true
        case .started, .progress:
            return false
        }
    }
}

private final class DownloadStubURLProtocol: URLProtocol {
    enum Plan {
        case response(status: Int, headers: [String: String], body: Data)
        case failure(Error)
        case redirect(URL)
        case hold
    }

    private static let lock = NSLock()
    private static var plansByPath: [String: [Plan]] = [:]

    static func setPlan(_ plan: Plan, forPath path: String) {
        setPlans([plan], forPath: path)
    }

    static func setPlans(_ plans: [Plan], forPath path: String) {
        lock.lock()
        plansByPath[path] = plans
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "example.com"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let path = request.url?.path ?? ""
        Self.lock.lock()
        var plans = Self.plansByPath[path] ?? []
        let plan = plans.isEmpty ? nil : plans.removeFirst()
        Self.plansByPath[path] = plans
        Self.lock.unlock()

        guard let plan else {
            client?.urlProtocol(
                self,
                didFailWithError: NSError(
                    domain: NSURLErrorDomain,
                    code: NSURLErrorResourceUnavailable
                )
            )
            return
        }

        switch plan {
        case let .response(status, headers, body):
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        case let .failure(error):
            client?.urlProtocol(self, didFailWithError: error)
        case let .redirect(target):
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 302,
                httpVersion: "HTTP/1.1",
                headerFields: ["Location": target.absoluteString]
            )!
            client?.urlProtocol(
                self,
                wasRedirectedTo: URLSessionDownloadTransport.makeRequest(target),
                redirectResponse: response
            )
        case .hold:
            break
        }
    }

    override func stopLoading() {}
}

private func downloadRecord(
    id: UUID,
    taskIdentifier: Int?,
    resumeData: Data? = nil
) -> CyclopDownload {
    CyclopDownload(
        id: id,
        remoteURL: URL(string: "https://example.com/\(id.uuidString).zip")!,
        phase: .downloading,
        displayName: "file.zip",
        destinationURL: nil,
        taskIdentifier: taskIdentifier,
        resumeData: resumeData,
        bytesReceived: 0,
        totalBytes: nil,
        createdAt: Date(timeIntervalSince1970: 1_000),
        completedAt: nil,
        failure: nil
    )
}
