# Гибридные загрузки — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:test-driven-development for each task and superpowers:systematic-debugging for URLSession integration failures. Execute after the activity foundation.

**Goal:** Добавить собственный загрузчик Cyclop для HTTP/HTTPS URL и ненавязчивые события о завершении внешних загрузок в выбранной папке.

**Architecture:** `DownloadManager` владеет очередью и persisted metadata, но работает через внедряемый transport. Live transport использует background `URLSession`; manager ограничивает concurrency тремя задачами. `DownloadsFolderWatcher` — отдельный event-driven source: он публикует только подтверждённое завершение внешнего файла и дедуплицируется с собственным загрузчиком.

**Tech Stack:** Swift, Foundation/URLSession, DispatchSource, Combine, UniformTypeIdentifiers, XCTest.

## Ограничения и модель угроз

- Принимать только абсолютные `http`/`https` URL.
- Не поддерживать cookies, авторизацию, DRM, browser sessions и обход ограничений сайтов.
- Одновременно скачивать максимум три файла; остальные остаются в очереди.
- Разрешить pause/resume/cancel/retry; resume data считается оптимизацией, а не гарантией сервера.
- Сохранять в настраиваемую папку, по умолчанию `~/Downloads`.
- Не перезаписывать существующие файлы; добавлять ` (2)`, ` (3)` и так далее.
- Не показывать внешний прогресс: watcher знает только факт завершения.
- Игнорировать `.crdownload`, `.download`, `.part`, `.partial`, `.tmp` и скрытые файлы.
- Не читать содержимое загруженных файлов и не выполнять их.
- Ошибки собственных загрузок остаются карточками с retry; завершение — attention 5 секунд; ошибка — 8 секунд.

---

### Task 1: Определить persisted download model

**Files:**
- Create: `Sources/Cyclop/Activities/Downloads/CyclopDownload.swift`
- Create: `Sources/Cyclop/Activities/Downloads/DownloadPersistence.swift`
- Create: `Tests/CyclopTests/Activities/Downloads/DownloadPersistenceTests.swift`

**Interfaces:**
- Produces: `CyclopDownload`, `DownloadPhase`, `DownloadPersisting`, `JSONDownloadPersistence`.

- [ ] **Step 1: Написать round-trip test**

```swift
func testRoundTripPreservesQueueTaskAndResumeData() throws {
    let record = CyclopDownload(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        remoteURL: URL(string: "https://example.com/archive.zip")!,
        phase: .paused,
        displayName: "archive.zip",
        destinationURL: nil,
        taskIdentifier: nil,
        resumeData: Data([1, 2, 3]),
        bytesReceived: 512,
        totalBytes: 1_024,
        createdAt: Date(timeIntervalSince1970: 100),
        completedAt: nil,
        failure: nil
    )
    let persistence = JSONDownloadPersistence(fileURL: temporaryFile("downloads.json"))
    try persistence.save([record])
    XCTAssertEqual(try persistence.load(), [record])
}
```

- [ ] **Step 2: Запустить test до реализации**

Run: `swift test --filter DownloadPersistenceTests`

Expected: FAIL с отсутствующим `CyclopDownload`.

- [ ] **Step 3: Реализовать model**

```swift
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
        guard let totalBytes, totalBytes > 0 else { return nil }
        return min(1, max(0, Double(bytesReceived) / Double(totalBytes)))
    }
}
```

- [ ] **Step 4: Реализовать атомарный JSON store**

```swift
protocol DownloadPersisting {
    func load() throws -> [CyclopDownload]
    func save(_ downloads: [CyclopDownload]) throws
}

struct JSONDownloadPersistence: DownloadPersisting {
    let fileURL: URL
    static func live(fileManager: FileManager = .default) -> Self
    func load() throws -> [CyclopDownload]
    func save(_ downloads: [CyclopDownload]) throws
}
```

Live URL: `~/Library/Application Support/Cyclop/downloads.json`. Поведение missing/invalid file совпадает с timer persistence: missing→`[]`, invalid→throw; write — `.atomic`.

- [ ] **Step 5: Запустить tests и закоммитить**

Run: `swift test --filter DownloadPersistenceTests`

Expected: PASS.

```bash
git add Sources/Cyclop/Activities/Downloads Tests/CyclopTests/Activities/Downloads
git commit -m "feat: persist Cyclop downloads"
```

### Task 2: Валидировать URL и безопасно выбирать имя назначения

**Files:**
- Create: `Sources/Cyclop/Activities/Downloads/DownloadRequest.swift`
- Create: `Sources/Cyclop/Activities/Downloads/DownloadNaming.swift`
- Create: `Tests/CyclopTests/Activities/Downloads/DownloadRequestTests.swift`
- Create: `Tests/CyclopTests/Activities/Downloads/DownloadNamingTests.swift`

**Interfaces:**
- Produces: `DownloadRequestParser.parse(_:)`, `DownloadNaming.destination(...)`.

- [ ] **Step 1: Написать parser matrix**

```swift
func testAcceptsOnlyAbsoluteHTTPAndHTTPS() throws {
    XCTAssertEqual(try DownloadRequestParser.parse("https://example.com/a.zip").scheme, "https")
    XCTAssertEqual(try DownloadRequestParser.parse("http://example.com/a.zip").scheme, "http")
    for value in ["file:///tmp/a", "ftp://example.com/a", "example.com/a", "javascript:alert(1)"] {
        XCTAssertThrowsError(try DownloadRequestParser.parse(value))
    }
}
```

- [ ] **Step 2: Написать naming tests**

```swift
func testSanitizesTraversalAndAvoidsOverwrite() throws {
    let folder = makeDirectory(files: ["archive.zip", "archive (2).zip"])
    let result = DownloadNaming.destination(
        folder: folder,
        responseFilename: "../../archive.zip",
        remoteURL: URL(string: "https://example.com/fallback")!,
        fileExists: FileManager.default.fileExists(atPath:)
    )
    XCTAssertEqual(result.lastPathComponent, "archive (3).zip")
    XCTAssertEqual(result.deletingLastPathComponent(), folder)
}
```

- [ ] **Step 3: Реализовать parser и sanitization**

```swift
enum DownloadRequestError: Error, Equatable { case empty, unsupportedScheme, missingHost }

enum DownloadRequestParser {
    static func parse(_ raw: String) throws -> URL
}

enum DownloadNaming {
    static func destination(
        folder: URL,
        responseFilename: String?,
        remoteURL: URL,
        fileExists: (String) -> Bool
    ) -> URL
}
```

Trim whitespace; scheme сравнивать case-insensitive; требовать host. Для имени брать `suggestedFilename`, затем lastPathComponent URL, затем `download`. Оставлять только последний path component, заменять `/`, `:`, NUL и control characters на `_`, ограничивать имя 240 UTF-8 bytes без потери extension.

- [ ] **Step 4: Проверить edge cases**

Tests: query-only URL, percent-encoding, имя `.`, пустое имя, dotfile, Unicode/кириллица, collisions без extension, папка отсутствует. Создание папки относится к manager, naming остаётся pure.

- [ ] **Step 5: Запустить tests и закоммитить**

Run: `swift test --filter 'DownloadRequest|DownloadNaming'`

Expected: PASS.

```bash
git add Sources/Cyclop/Activities/Downloads Tests/CyclopTests/Activities/Downloads
git commit -m "feat: validate download requests and filenames"
```

### Task 3: Реализовать очередь и lifecycle через fake transport

**Files:**
- Create: `Sources/Cyclop/Activities/Downloads/DownloadTransport.swift`
- Create: `Sources/Cyclop/Activities/Downloads/DownloadManager.swift`
- Create: `Tests/CyclopTests/Activities/Downloads/DownloadManagerTests.swift`
- Modify: `Tests/CyclopTests/Support/ActivityTestDoubles.swift`

**Interfaces:**
- Consumes: `DownloadPersisting`, `ActivityClock`, `ActivitySettings.downloadsFolder`.
- Produces: `DownloadTransport`, `DownloadManager.enqueue/pause/resume/cancel/retry`.

- [ ] **Step 1: Определить transport contract и fake**

```swift
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
    func restore(records: [CyclopDownload])
    func start(id: UUID, url: URL, resumeData: Data?)
    func pause(id: UUID)
    func cancel(id: UUID)
}
```

Fake хранит вызовы и позволяет test вручную отправить event.

- [ ] **Step 2: Написать concurrency test**

```swift
@MainActor
func testStartsThreeAndQueuesTheRest() throws {
    let transport = FakeDownloadTransport()
    let manager = makeManager(transport: transport, maxConcurrent: 3)
    try manager.start()
    for index in 0..<5 {
        _ = try manager.enqueue("https://example.com/\(index).zip")
    }
    XCTAssertEqual(transport.startedIDs.count, 3)
    XCTAssertEqual(manager.downloads.filter { $0.phase == .queued }.count, 2)
    transport.send(.finished(id: transport.startedIDs[0], temporaryURL: temporaryFile(), suggestedFilename: "0.zip"))
    XCTAssertEqual(transport.startedIDs.count, 4)
}
```

- [ ] **Step 3: Написать action matrix tests**

Проверить downloading→pause/cancel; paused→resume/cancel; failed→retry/cancel; completed→dismiss/open/reveal; queued→cancel. Transport подтверждает отмену отдельным `.cancelled(id:)`; только после этого manager удаляет запись. Retry очищает failure/progress/task ID и возвращает в queue.

- [ ] **Step 4: Реализовать manager API**

```swift
@MainActor
final class DownloadManager: ObservableObject {
    @Published private(set) var downloads: [CyclopDownload] = []
    @Published private(set) var health: ActivitySourceHealth = .available
    var ownCompletionPublisher: AnyPublisher<OwnDownloadCompletion, Never> { get }

    func start() throws
    func stop()
    @discardableResult func enqueue(_ rawURL: String) throws -> UUID
    func pause(_ id: UUID)
    func resume(_ id: UUID)
    func cancel(_ id: UUID)
    func retry(_ id: UUID)
    func dismiss(_ id: UUID)
    func open(_ id: UUID)
    func reveal(_ id: UUID)
}
```

Manager сериализует все state transitions на `@MainActor`, сохраняет после meaningful event и вызывает `drainQueue()`. Частые progress events публикуются UI, но persistence throttled не чаще раза в 2 секунды и обязательно flush на pause/fail/finish/stop.

Успешный finish после persisted move публикует `OwnDownloadCompletion(fileURL:occurredAt:)`. Это событие подключается к watcher в Task 5 и подавляет двойное own/external attention.

- [ ] **Step 5: Реализовать finish move**

При `.finished` создать destination folder, вычислить уникальный path, синхронно переместить temporary URL. Только успешный move переводит запись в `.completed`, ставит `destinationURL`, `completedAt = clock.now`, `progress = 1`. Ошибка mkdir/move переводит в `.failed` с кодом `destination-write` и оставляет retry.

- [ ] **Step 6: Покрыть recovery**

На start: load persisted records; `.queued` остаются queued; `.downloading` передаются `transport.restore`; `.paused`, `.failed`, `.completed` не стартуют автоматически. Если transport не находит persisted background task, запись становится `.failed(code: "task-lost")`, а не зависает в progress.

- [ ] **Step 7: Запустить tests и закоммитить**

Run: `swift test --filter DownloadManagerTests`

Expected: PASS.

```bash
git add Sources/Cyclop/Activities/Downloads Tests/CyclopTests/Activities/Downloads
git commit -m "feat: manage queued Cyclop downloads"
```

### Task 4: Подключить background URLSession transport

**Files:**
- Create: `Sources/Cyclop/Activities/Downloads/URLSessionDownloadTransport.swift`
- Create: `Tests/CyclopTests/Activities/Downloads/URLSessionDownloadTransportTests.swift`
- Integration target (изменяется в UI plan Task 8): `Sources/Cyclop/App/AppDelegate.swift`

**Interfaces:**
- Produces: live `URLSessionDownloadTransport`, background identifier `com.cyclop.app.downloads`, совпадающий с `CFBundleIdentifier` из `Scripts/bundle.sh`.

- [ ] **Step 1: Написать request configuration test**

```swift
func testRequestDoesNotUseCookiesOrCacheCredentials() {
    let request = URLSessionDownloadTransport.makeRequest(URL(string: "https://example.com/file")!)
    XCTAssertEqual(request.httpShouldHandleCookies, false)
    XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
    XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
}
```

- [ ] **Step 2: Написать URLProtocol integration tests для HTTP outcomes**

Проверить 200 + known length, 200 + unknown length, redirect HTTPS→HTTPS, 404, 500, network interruption с/без resumeData. Тестовый session factory использует ephemeral configuration; live factory — background configuration.

- [ ] **Step 3: Реализовать task mapping**

```swift
final class URLSessionDownloadTransport: NSObject, DownloadTransport,
    URLSessionDownloadDelegate, URLSessionTaskDelegate {
    static let backgroundIdentifier = "com.cyclop.app.downloads"
    var eventHandler: ((DownloadTransportEvent) -> Void)?
    private var idByTaskIdentifier: [Int: UUID] = [:]
    private var taskByID: [UUID: URLSessionDownloadTask] = [:]
}
```

Записывать download UUID в `task.taskDescription`, чтобы восстановить mapping через `getAllTasks`. `restore(records:)` сопоставляет taskDescription, публикует current progress, сообщает `task-lost` для отсутствующих records и отменяет orphan tasks только после диагностического лога.

- [ ] **Step 4: Реализовать delegate events**

`didWriteData`→progress. `didFinishDownloadingTo` должен передать temporary URL manager синхронно на main actor и дождаться завершения move до возврата delegate, иначе system удалит temporary file. `didCompleteWithError` не публикует второй failure после успешного finish. Проверять `HTTPURLResponse.statusCode` в `200...299`; иначе failure code `http-<status>`.

- [ ] **Step 5: Реализовать pause/resume/cancel**

Pause вызывает `cancel(byProducingResumeData:)`; resume создаёт task из resumeData, если данные приняты session, иначе новый request с нуля. Cancel не сохраняет resumeData и после `didCompleteWithError` для намеренно отменённой task публикует `.cancelled(id:)`, а не failure. Network failures сохраняют доступные resumeData.

- [ ] **Step 6: Проверить background completion hook contract**

Добавить API:

```swift
func setBackgroundEventsCompletionHandler(_ handler: @escaping () -> Void)
func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession)
```

Фактический вызов из `AppDelegate.application(_:handleEventsForBackgroundURLSession:completionHandler:)` выполняется в UI integration plan после создания единственного live transport.

- [ ] **Step 7: Запустить tests и закоммитить**

Run: `swift test --filter URLSessionDownloadTransportTests`

Expected: PASS.

```bash
git add Sources/Cyclop/Activities/Downloads/URLSessionDownloadTransport.swift Tests/CyclopTests/Activities/Downloads
git commit -m "feat: download with background URLSession"
```

### Task 5: Отслеживать завершённые внешние загрузки

**Files:**
- Create: `Sources/Cyclop/Activities/Downloads/DownloadsFolderWatcher.swift`
- Create: `Sources/Cyclop/Activities/Downloads/FolderSnapshot.swift`
- Create: `Tests/CyclopTests/Activities/Downloads/DownloadsFolderWatcherTests.swift`

**Interfaces:**
- Consumes: configured folder, file snapshot provider, `ActivityScheduling`, `DownloadManager.ownCompletionPublisher`.
- Produces: `ExternalDownloadCompletion` events без progress.

- [ ] **Step 1: Написать baseline и temp suffix tests**

```swift
@MainActor
func testInitialFilesAndTemporarySuffixesDoNotEmit() {
    let provider = MutableFolderSnapshotProvider([
        file("old.zip", size: 100), file("movie.crdownload", size: 200)
    ])
    let watcher = makeWatcher(provider: provider)
    watcher.start()
    provider.files.append(file("new.part", size: 50))
    watcher.folderDidChange()
    XCTAssertTrue(watcher.completions.isEmpty)
}
```

- [ ] **Step 2: Написать stability test**

Новый обычный файл не публикуется на первом scan. После 1.5 секунды и второго scan с теми же size/modification date публикуется ровно один раз. Если size меняется — stability wait начинается заново.

- [ ] **Step 3: Определить snapshots и provider**

```swift
struct FolderFileSnapshot: Equatable {
    let url: URL
    let fileResourceIdentifier: AnyHashable?
    let size: Int64
    let modifiedAt: Date
}

struct ExternalDownloadCompletion: Identifiable, Equatable {
    let id: String
    let fileURL: URL
    let occurredAt: Date
}

protocol FolderSnapshotProviding {
    func snapshots(in folder: URL) throws -> [FolderFileSnapshot]
}
```

Production provider запрашивает `.isRegularFileKey`, `.isHiddenKey`, `.fileSizeKey`, `.contentModificationDateKey`, `.fileResourceIdentifierKey`; symlink и directory игнорируются.

- [ ] **Step 4: Реализовать event-driven watcher**

Live watcher открывает folder descriptor `O_EVTONLY`, создаёт `DispatchSource.makeFileSystemObjectSource` для `.write/.rename/.extend/.attrib`, debounce-ит burst через scheduler на 300 мс, затем делает scan. Если папка заменена/переименована, пересоздаёт descriptor и baseline. При stop отменяет source и закрывает fd.

- [ ] **Step 5: Реализовать own-download suppression**

```swift
func suppressOwnCompletion(fileURL: URL, at date: Date)
```

Canonical standardized/resolved path хранится 10 секунд. Совпавший watcher result удаляется без external event. Это исключает двойной attention, когда own manager переместил файл в ту же watched folder.

Watcher принимает `AnyPublisher<OwnDownloadCompletion, Never>` при инициализации, удерживает подписку и для каждого события вызывает `suppressOwnCompletion`. В live composition manager создаётся раньше watcher и передаёт ему `ownCompletionPublisher`; checkpoint обязан покрыть это wiring end-to-end.

- [ ] **Step 6: Покрыть ошибки папки**

Missing/unreadable folder публикует health `unavailable("Папка загрузок недоступна")`, не делает polling. После изменения setting watcher должен остановить старый descriptor, начать новый baseline и восстановить health.

- [ ] **Step 7: Запустить tests и закоммитить**

Run: `swift test --filter DownloadsFolderWatcherTests`

Expected: PASS.

```bash
git add Sources/Cyclop/Activities/Downloads Tests/CyclopTests/Activities/Downloads
git commit -m "feat: detect completed external downloads"
```

### Task 6: Адаптировать own и external downloads к ActivitySource

**Files:**
- Create: `Sources/Cyclop/Activities/Downloads/DownloadActivitySources.swift`
- Create: `Tests/CyclopTests/Activities/Downloads/DownloadActivitySourcesTests.swift`

**Interfaces:**
- Produces: source IDs `downloads.own` и `downloads.external`.

- [ ] **Step 1: Написать own mapping test**

Queued/downloading/paused/failed/completed records становятся snapshots. Progress `nil` при неизвестной длине. Failed actions: retry/cancel; completed: open/reveal/dismiss; downloading: pause/cancel; paused: resume/cancel.

- [ ] **Step 2: Написать external mapping test**

Completion становится `.download/.completed` с title=filename, `occurredAt`, actions open/reveal/dismiss и без progress. `dismiss` удаляет transient event из watcher.

- [ ] **Step 3: Реализовать adapters**

```swift
@MainActor final class OwnDownloadActivitySource: ActivitySource { let sourceID = "downloads.own" }
@MainActor final class ExternalDownloadActivitySource: ActivitySource { let sourceID = "downloads.external" }
```

`ActivityID.source` должен совпадать с source ID; local ID — UUID для own и stable resourceID/path+timestamp hash для external. Не хранить URL в title/subtitle.

- [ ] **Step 4: Запустить download suite и build**

Run: `swift test --filter Download`

Expected: PASS.

Run: `swift build`

Expected: PASS.

- [ ] **Step 5: Закоммитить adapters**

```bash
git add Sources/Cyclop/Activities/Downloads Tests/CyclopTests/Activities/Downloads
git commit -m "feat: expose downloads as activities"
```

## Downloads checkpoint

Run: `swift test --filter 'Download|ActivityCoordinator|ActivityAttention'`

Expected: очередь не превышает 3; own completion не дублируется watcher; external source никогда не показывает выдуманный progress; recovery не оставляет вечных `.downloading` records.
