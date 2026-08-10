# Ядро системы активностей — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Создать тестируемое доменное ядро активностей, которое объединяет источники, выбирает главную активность, дедуплицирует события внимания и управляет состояниями острова без изменения видимого поведения Cyclop.

**Architecture:** Новая папка `Sources/Cyclop/Activities` содержит неизменяемые модели, типизированные настройки, coordinator, attention policy и presentation model. Существующие сервисы пока не подключаются; все решения проверяются fake-источниками и fake-clock через XCTest.

**Tech Stack:** Swift 6 toolchain, Swift language mode 5, Combine, Foundation, AppKit, XCTest, Swift Package Manager.

## Global Constraints

- Минимальная версия — macOS 15.
- Внешние зависимости не добавляются.
- Все пользовательские строки в последующих планах добавляются одновременно на русском и английском.
- Новые разрешения системы не запрашиваются.
- Сохраняется один постоянный `NSPanel`; frame окна не анимируется.
- Без активностей не добавляется ни одного повторяющегося таймера.
- `Scripts/version` и `docs/releases/*` не изменяются.
- Каждый production-шаг начинается с падающего теста и заканчивается проходящим тестом и отдельным коммитом.

---

## Карта файлов

- `Package.swift` — подключает `CyclopTests`.
- `Sources/Cyclop/Activities/ActivityModels.swift` — идентификаторы, состояния, действия, snapshot и display state.
- `Sources/Cyclop/Activities/ActivitySource.swift` — контракт источника и health state.
- `Sources/Cyclop/Activities/ActivityTime.swift` — clock, cancellable и scheduler.
- `Sources/Cyclop/Activities/ActivitySettings.swift` — типизированные UserDefaults-настройки.
- `Sources/Cyclop/Activities/ActivityRanking.swift` — чистая сортировка и три indicator slots.
- `Sources/Cyclop/Activities/ActivityAttention.swift` — attention events, policy и ledger.
- `Sources/Cyclop/Activities/ActivityCoordinator.swift` — объединение publisher-ов и маршрутизация действий.
- `Sources/Cyclop/Activities/NotchPresentationModel.swift` — `idle/compact/attention/expanded` и временная навигация.
- `Sources/Cyclop/Notch/NotchLayoutMetrics.swift` — чистые формулы физической и синтетической чёлки.
- `Tests/CyclopTests/Activities/*` — unit tests ядра.
- `Tests/CyclopTests/Support/ActivityTestDoubles.swift` — fake-clock, manual scheduler и fake-source.

### Task 1: Подключить XCTest и общие test doubles

**Files:**
- Modify: `Package.swift:5-17`
- Create: `Sources/Cyclop/Activities/ActivityTime.swift`
- Create: `Tests/CyclopTests/Support/ActivityTestDoubles.swift`
- Create: `Tests/CyclopTests/Activities/ActivityTimeTests.swift`

**Interfaces:**
- Produces: `ActivityClock.now`, `ActivityScheduling.schedule(at:_:)`, `ActivityCancellation.cancel()`, `SystemActivityScheduler`.

- [ ] **Step 1: Добавить падающий smoke test**

```swift
import XCTest
@testable import Cyclop

final class ActivityTimeTests: XCTestCase {
    func testMutableClockAdvancesDeterministically() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let clock = MutableActivityClock(now: start)
        clock.advance(by: 15)
        XCTAssertEqual(clock.now, start.addingTimeInterval(15))
    }
}
```

- [ ] **Step 2: Подключить test target и убедиться, что тест падает на отсутствующем типе**

```swift
.testTarget(
    name: "CyclopTests",
    dependencies: ["Cyclop"],
    path: "Tests/CyclopTests"
)
```

Run: `swift test --filter ActivityTimeTests`

Expected: FAIL с `cannot find 'MutableActivityClock' in scope`.

- [ ] **Step 3: Добавить production-интерфейсы времени**

```swift
import Foundation

protocol ActivityClock: AnyObject {
    var now: Date { get }
}

final class SystemActivityClock: ActivityClock {
    var now: Date { Date() }
}

@MainActor
protocol ActivityCancellation: AnyObject {
    func cancel()
}

@MainActor
protocol ActivityScheduling: AnyObject {
    @discardableResult
    func schedule(at date: Date, _ action: @escaping @MainActor () -> Void) -> ActivityCancellation
}
```

Live-реализация `SystemActivityScheduler` использует one-shot `Foundation.Timer` с абсолютным `Date` в `RunLoop.main` mode `.common`. Cancel идемпотентен, action очищается до вызова и выполняется не более одного раза; просроченный deadline обрабатывается на ближайшем проходе main run loop.

- [ ] **Step 4: Добавить test doubles**

```swift
final class MutableActivityClock: ActivityClock {
    var now: Date
    init(now: Date) { self.now = now }
    func advance(by interval: TimeInterval) { now.addTimeInterval(interval) }
}

final class ManualActivityScheduler: ActivityScheduling {
    struct Entry {
        let date: Date
        let action: @MainActor () -> Void
        let cancellation: TestCancellation
    }
    private(set) var entries: [Entry] = []
    var activeEntries: [Entry] { entries.filter { !$0.cancellation.isCancelled } }
    @discardableResult
    func schedule(at date: Date, _ action: @escaping @MainActor () -> Void) -> ActivityCancellation {
        let cancellation = TestCancellation()
        entries.append(Entry(date: date, action: action, cancellation: cancellation))
        return cancellation
    }
}

final class TestCancellation: ActivityCancellation {
    private(set) var isCancelled = false
    func cancel() { isCancelled = true }
}
```

- [ ] **Step 5: Запустить тест**

Run: `swift test --filter ActivityTimeTests`

Expected: PASS.

- [ ] **Step 6: Закоммитить test harness**

```bash
git add Package.swift Sources/Cyclop/Activities/ActivityTime.swift Tests/CyclopTests
git commit -m "test: add activity test harness"
```

### Task 2: Определить единую модель активности и контракт источника

**Files:**
- Create: `Sources/Cyclop/Activities/ActivityModels.swift`
- Create: `Sources/Cyclop/Activities/ActivitySource.swift`
- Create: `Tests/CyclopTests/Activities/ActivityModelsTests.swift`
- Modify: `Tests/CyclopTests/Support/ActivityTestDoubles.swift`

**Interfaces:**
- Produces: `ActivityID`, `ActivityKind`, `ActivityPhase`, `ActivityAction`, `ActivitySnapshot`, `ActivitySourceState`, `ActivitySource`.

- [ ] **Step 1: Написать тест равенства snapshot и набора действий**

```swift
func testSnapshotIdentityDoesNotDependOnDisplayText() {
    let id = ActivityID(source: "timer", local: "abc")
    let first = ActivitySnapshot(id: id, sourceID: "timers", kind: .timer, phase: .active,
        title: "Помодоро", subtitle: "", progress: nil, deadline: Date(timeIntervalSince1970: 100),
        occurredAt: nil, availableActions: [.pause, .cancel], containsSensitiveText: true)
    var second = first
    second.title = "Таймер"
    XCTAssertEqual(first.id, second.id)
    XCTAssertEqual(first.availableActions, [.pause, .cancel])
}
```

- [ ] **Step 2: Запустить тест и увидеть отсутствующие модели**

Run: `swift test --filter ActivityModelsTests`

Expected: FAIL с `cannot find 'ActivityID' in scope`.

- [ ] **Step 3: Реализовать модели с точными case names**

```swift
struct ActivityID: Hashable, Codable, Comparable, Sendable {
    let source: String
    let local: String
    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.source, lhs.local) < (rhs.source, rhs.local)
    }
}

enum ActivityKind: String, Codable, CaseIterable, Sendable { case media, meeting, timer, download }
enum ActivityPhase: String, Codable, Sendable { case ambient, active, attention, completed, failed, paused }
enum ActivityAction: String, Codable, Hashable, CaseIterable, Sendable {
    case play, pause, previous, next, join, resume, cancel, dismiss, retry, restart, open, reveal
}

struct ActivitySnapshot: Identifiable, Equatable, Sendable {
    let id: ActivityID
    let sourceID: String
    let kind: ActivityKind
    var phase: ActivityPhase
    var title: String
    var subtitle: String
    var progress: Double?
    var deadline: Date?
    var occurredAt: Date?
    var availableActions: Set<ActivityAction>
    var containsSensitiveText: Bool
}
```

- [ ] **Step 4: Реализовать source state и protocol**

```swift
import Combine

enum ActivitySourceHealth: Equatable { case available; case unavailable(message: String) }
struct ActivitySourceState: Equatable {
    var snapshots: [ActivitySnapshot]
    var health: ActivitySourceHealth
}

@MainActor
protocol ActivitySource: AnyObject {
    var sourceID: String { get }
    var statePublisher: AnyPublisher<ActivitySourceState, Never> { get }
    func perform(_ action: ActivityAction, activityID: ActivityID)
}
```

- [ ] **Step 5: Добавить `FakeActivitySource` и запустить тесты**

```swift
@MainActor
final class FakeActivitySource: ActivitySource {
    let sourceID: String
    let subject = CurrentValueSubject<ActivitySourceState, Never>(.init(snapshots: [], health: .available))
    private(set) var performed: [(ActivityAction, ActivityID)] = []
    var statePublisher: AnyPublisher<ActivitySourceState, Never> { subject.eraseToAnyPublisher() }
    init(sourceID: String) { self.sourceID = sourceID }
    func perform(_ action: ActivityAction, activityID: ActivityID) { performed.append((action, activityID)) }
}
```

Run: `swift test --filter ActivityModelsTests`

Expected: PASS.

- [ ] **Step 6: Закоммитить доменную модель**

```bash
git add Sources/Cyclop/Activities Tests/CyclopTests
git commit -m "feat: add activity domain model"
```

### Task 3: Добавить типизированные настройки

**Files:**
- Create: `Sources/Cyclop/Activities/ActivitySettings.swift`
- Create: `Tests/CyclopTests/Activities/ActivitySettingsTests.swift`

**Interfaces:**
- Produces: `ActivitySettings`, `MediaAnimationMode`, published properties с ключами из спецификации.

- [ ] **Step 1: Написать тест defaults**

```swift
@MainActor
func testDefaultsMatchSpecification() {
    let defaults = UserDefaults(suiteName: #function)!
    defaults.removePersistentDomain(forName: #function)
    let settings = ActivitySettings(defaults: defaults, homeDirectory: URL(fileURLWithPath: "/Users/test"))
    XCTAssertTrue(settings.isEnabled)
    XCTAssertEqual(settings.meetingLeadMinutes, 15)
    XCTAssertEqual(settings.mediaAnimationMode, .slow)
    XCTAssertEqual(settings.downloadsFolder.path, "/Users/test/Downloads")
}
```

- [ ] **Step 2: Запустить тест до реализации**

Run: `swift test --filter ActivitySettingsTests`

Expected: FAIL с `cannot find 'ActivitySettings' in scope`.

- [ ] **Step 3: Реализовать settings API**

```swift
enum MediaAnimationMode: String, CaseIterable, Codable { case `static`, slow, fluid }

@MainActor
final class ActivitySettings: ObservableObject {
    @Published var isEnabled: Bool
    @Published var mediaEnabled: Bool
    @Published var meetingsEnabled: Bool
    @Published var timersEnabled: Bool
    @Published var downloadsEnabled: Bool
    @Published var meetingLeadMinutes: Int
    @Published var timerSoundEnabled: Bool
    @Published var mediaAnimationMode: MediaAnimationMode
    @Published var downloadsFolder: URL

    init(defaults: UserDefaults = .standard, homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser)
}
```

В `init` прочитать точные ключи `activities.enabled`, `activities.media.enabled`, `activities.meetings.enabled`, `activities.timers.enabled`, `activities.downloads.enabled`, `activities.meetingLeadMinutes`, `activities.timerSoundEnabled`, `activities.mediaAnimationMode`, `activities.downloadsFolder`. После инициализации подписать published properties на запись через `dropFirst()`.

- [ ] **Step 4: Добавить тест сохранения и допустимых meeting lead values**

```swift
settings.meetingLeadMinutes = 30
settings.mediaAnimationMode = .fluid
let restored = ActivitySettings(defaults: defaults, homeDirectory: home)
XCTAssertEqual(restored.meetingLeadMinutes, 30)
XCTAssertEqual(restored.mediaAnimationMode, .fluid)
```

Некорректное значение порога должно восстанавливаться как `15`, допустимы только `[5, 10, 15, 30]`.

- [ ] **Step 5: Запустить tests и закоммитить**

Run: `swift test --filter ActivitySettingsTests`

Expected: PASS.

```bash
git add Sources/Cyclop/Activities/ActivitySettings.swift Tests/CyclopTests/Activities/ActivitySettingsTests.swift
git commit -m "feat: add activity settings model"
```

### Task 4: Реализовать ranking и indicator slots

**Files:**
- Create: `Sources/Cyclop/Activities/ActivityRanking.swift`
- Create: `Tests/CyclopTests/Activities/ActivityRankingTests.swift`

**Interfaces:**
- Consumes: `ActivitySnapshot`, `ActivitySettings`.
- Produces: `ActivityIndicator`, `ActivityIndicatorSet`, `ActivityRanking.sorted(_:)`, `ActivityRanking.indicators(afterPrimary:)`.

- [ ] **Step 1: Написать table-driven тест полного порядка**

```swift
func testPriorityOrderMatchesSpecification() {
    let snapshots = [media(), completedDownload(), activeDownload(), activeTimer(), failedDownload(), meeting(), completedTimer()]
    XCTAssertEqual(ActivityRanking.sorted(snapshots).map(\.id.local), [
        "completed-timer", "meeting", "failed-download", "active-timer", "active-download", "media", "completed-download"
    ])
}
```

- [ ] **Step 2: Написать тест трёх visual slots**

```swift
func testFourSecondaryActivitiesUseTwoIndicatorsAndOverflowSlot() {
    let result = ActivityRanking.indicators(afterPrimary: [timer("1"), timer("2"), download("3"), media("4")])
    XCTAssertEqual(result.items.map(\.activityID.local), ["1", "2"])
    XCTAssertEqual(result.hiddenCount, 2)
}
```

- [ ] **Step 3: Запустить тесты до реализации**

Run: `swift test --filter ActivityRankingTests`

Expected: FAIL с отсутствующим `ActivityRanking`.

- [ ] **Step 4: Реализовать rank tuple и deterministic tie-break**

```swift
struct ActivityIndicator: Equatable {
    let activityID: ActivityID
    let kind: ActivityKind
    let phase: ActivityPhase
}

struct ActivityIndicatorSet: Equatable {
    let items: [ActivityIndicator]
    let hiddenCount: Int
}

enum ActivityRanking {
    static func rank(_ snapshot: ActivitySnapshot) -> Int {
        switch (snapshot.kind, snapshot.phase) {
        case (.timer, .completed): return 700
        case (.meeting, _): return 600
        case (.download, .failed): return 500
        case (.timer, .active): return 400
        case (.download, .active): return 300
        case (.media, _): return 200
        case (.download, .completed): return 100
        default: return 0
        }
    }
}
```

Сортировать по rank descending, затем deadline ascending (`nil` после дат), occurredAt descending, id ascending. В compact list допускается только paused media на время grace period источника; paused timer/download и rank `0` не попадают в compact list.

- [ ] **Step 5: Реализовать ровно три indicator slots**

Если secondary count `0...3`, вернуть все. Если count `>=4`, вернуть первые два и `hiddenCount = count - 2`.

- [ ] **Step 6: Запустить tests и закоммитить**

Run: `swift test --filter ActivityRankingTests`

Expected: PASS.

```bash
git add Sources/Cyclop/Activities/ActivityRanking.swift Tests/CyclopTests/Activities/ActivityRankingTests.swift
git commit -m "feat: rank activity snapshots"
```

### Task 5: Реализовать attention policy и persisted ledger

**Files:**
- Create: `Sources/Cyclop/Activities/ActivityAttention.swift`
- Create: `Tests/CyclopTests/Activities/ActivityAttentionTests.swift`

**Interfaces:**
- Produces: `AttentionEvent`, `ActivityAttentionPolicy.events(previous:current:now:)`, `ActivityAttentionLedger.claim(_:)`.

- [ ] **Step 1: Написать тест длительностей**

```swift
func testAttentionDurations() {
    XCTAssertEqual(AttentionEvent.Kind.meetingThreshold.duration, 5)
    XCTAssertEqual(AttentionEvent.Kind.timerCompleted.duration, 10)
    XCTAssertEqual(AttentionEvent.Kind.downloadFailed.duration, 8)
    XCTAssertEqual(AttentionEvent.Kind.downloadCompleted.duration, 5)
}
```

- [ ] **Step 2: Написать тест стабильного ID и дедупликации 24 часа**

```swift
let defaults = UserDefaults(suiteName: #function)!
let clock = MutableActivityClock(now: Date(timeIntervalSince1970: 1_000))
let ledger = ActivityAttentionLedger(defaults: defaults, clock: clock)
let event = AttentionEvent(id: "meeting:42:threshold:1000", activityID: meetingID, kind: .meetingThreshold, occurredAt: clock.now)
XCTAssertTrue(ledger.claim(event))
XCTAssertFalse(ledger.claim(event))
clock.advance(by: 86_401)
XCTAssertTrue(ledger.claim(event))
```

- [ ] **Step 3: Запустить тест до реализации**

Run: `swift test --filter ActivityAttentionTests`

Expected: FAIL с отсутствующим `AttentionEvent`.

- [ ] **Step 4: Реализовать event kinds и ledger**

```swift
struct AttentionEvent: Equatable, Identifiable {
    enum Kind { case meetingThreshold, meetingOneMinute, meetingStarted, timerCompleted, downloadFailed, downloadCompleted }
    let id: String
    let activityID: ActivityID
    let kind: Kind
    let occurredAt: Date
    var duration: TimeInterval { kind.duration }
}
```

Ledger хранит `[String: TimeInterval]` под ключом `activities.attentionLedger`, перед каждой записью удаляет timestamps старше `clock.now - 86_400` и возвращает `false` для уже существующего ID.

- [ ] **Step 5: Реализовать pure transition policy**

Policy сравнивает previous/current snapshots и создаёт события только для новых переходов в completed/failed и для meeting milestone snapshots, переданных `MeetingActivitySource` с детерминированным `occurredAt`.

- [ ] **Step 6: Запустить tests и закоммитить**

Run: `swift test --filter ActivityAttentionTests`

Expected: PASS.

```bash
git add Sources/Cyclop/Activities/ActivityAttention.swift Tests/CyclopTests/Activities/ActivityAttentionTests.swift
git commit -m "feat: add activity attention policy"
```

### Task 6: Объединить источники в ActivityCoordinator

**Files:**
- Create: `Sources/Cyclop/Activities/ActivityCoordinator.swift`
- Create: `Tests/CyclopTests/Activities/ActivityCoordinatorTests.swift`

**Interfaces:**
- Consumes: `[ActivitySource]`, `ActivitySettings`, `ActivityAttentionLedger`, `ActivityClock`.
- Produces: `@Published private(set) var displayState: ActivityDisplayState`, `perform(_:activityID:)`, `settleAttention(_:)`, `markViewed(_:)`.

- [ ] **Step 1: Написать тест объединения и маршрутизации**

```swift
@MainActor
func testCoordinatorMergesAndRoutesBySourceID() {
    let timers = FakeActivitySource(sourceID: "timers")
    let media = FakeActivitySource(sourceID: "media")
    let coordinator = makeCoordinator([timers, media])
    timers.subject.send(.init(snapshots: [completedTimer()], health: .available))
    media.subject.send(.init(snapshots: [playingMedia()], health: .available))
    XCTAssertEqual(coordinator.displayState.primary?.kind, .timer)
    coordinator.perform(.dismiss, activityID: completedTimer().id)
    XCTAssertEqual(timers.performed.last?.0, .dismiss)
}
```

- [ ] **Step 2: Написать тест visibility settings**

При `mediaEnabled = false` media остаётся в `allActivities`, но отсутствует в `primary` и indicators. `isEnabled = false` очищает compact presentation целиком, не вызывая action и не меняя source state.

- [ ] **Step 3: Написать тест демоции завершённого события**

```swift
@MainActor
func testSettledCompletedTimerBecomesIndicatorInsteadOfPermanentPrimary() {
    let source = FakeActivitySource(sourceID: "fixtures")
    let coordinator = makeCoordinator([source])
    source.subject.send(.init(snapshots: [completedTimer(), playingMedia()], health: .available))
    let event = try XCTUnwrap(coordinator.displayState.attention)
    XCTAssertEqual(coordinator.displayState.primary?.id, completedTimer().id)
    coordinator.settleAttention(event)
    XCTAssertEqual(coordinator.displayState.primary?.id, playingMedia().id)
    XCTAssertTrue(coordinator.displayState.indicators.contains { $0.activityID == completedTimer().id })
}
```

Повторить для failed download. `markViewed(downloadID)` скрывает failed/completed download из compact primary/indicators, но оставляет raw card в `allActivities`. Completed timer после просмотра не скрывается: он остаётся indicator до dismiss/restart.

- [ ] **Step 4: Запустить тест до реализации**

Run: `swift test --filter ActivityCoordinatorTests`

Expected: FAIL с отсутствующим coordinator.

- [ ] **Step 5: Реализовать coordinator subscriptions**

Хранить `[String: ActivitySourceState]`, подписаться на каждый publisher, на каждом update собирать `allActivities`, отфильтрованный compact list, primary, indicator slots, diagnostics и новое claimed attention event.

```swift
struct ActivityDisplayState: Equatable {
    var allActivities: [ActivitySnapshot]
    var primary: ActivitySnapshot?
    var indicators: [ActivityIndicator]
    var hiddenIndicatorCount: Int
    var attention: AttentionEvent?
    var diagnostics: [String: ActivitySourceHealth]
}
```

Ключ `diagnostics` — это `ActivitySource.sourceID`; так вкладка активностей сможет показать ошибку конкретного источника, не угадывая её по порядку массива.

Coordinator хранит `settledAttentionIDs` и `viewedDownloadIDs` только в памяти. При `settleAttention` completed timer/failed download исключается из кандидатов на primary, но принудительно остаётся среди indicators. При `markViewed` только download failed/completed исключается и из compact indicators. Когда source удалил ID или изменил его phase обратно на active/queued, оба множества очищаются для этого ID.

Если `ActivityAttentionLedger.claim(event)` вернул `false` после relaunch, coordinator сразу считает timer-completed/download-failed event settled: уже показанное событие не становится permanent primary, но unresolved indicator сохраняется. Meeting events не демотируют саму meeting activity после attention — она остаётся обычным кандидатом по priority.

- [ ] **Step 6: Запустить tests и закоммитить**

Run: `swift test --filter ActivityCoordinatorTests`

Expected: PASS.

```bash
git add Sources/Cyclop/Activities/ActivityCoordinator.swift Tests/CyclopTests/Activities/ActivityCoordinatorTests.swift
git commit -m "feat: coordinate activity sources"
```

### Task 7: Реализовать NotchPresentationModel

**Files:**
- Create: `Sources/Cyclop/Activities/NotchPresentationModel.swift`
- Create: `Tests/CyclopTests/Activities/NotchPresentationModelTests.swift`

**Interfaces:**
- Consumes: `ActivityDisplayState`, `ActivityClock`, `ActivityScheduling`, `onAttentionExpired` callback.
- Produces: `@Published state: NotchPresentationState`, `automaticTabRequest`, `userSelectedTab`, `openFromPointer`, `closeFromPointer`.

- [ ] **Step 1: Написать тест compact → attention → compact**

```swift
@MainActor
func testAttentionReturnsToCompactAfterDuration() {
    let harness = PresentationHarness()
    harness.model.receive(display: state(primary: media(), attention: timerCompletedEvent()))
    XCTAssertEqual(harness.model.state.mode, .attention)
    harness.fireScheduledAction()
    XCTAssertEqual(harness.model.state.mode, .compact)
}
```

- [ ] **Step 2: Написать тест временной вкладки**

```swift
harness.model.recordUserTab("calendar")
harness.model.openFromPointer(overActiveIsland: true)
XCTAssertEqual(harness.model.requestedTab, "activities")
harness.model.closeFromPointer()
harness.model.openFromPointer(overActiveIsland: false)
XCTAssertEqual(harness.model.requestedTab, "calendar")
```

- [ ] **Step 3: Написать тест generation token**

Получить первый scheduled closure, затем подать более новое attention event. Вызов старого closure не должен закрывать новое attention state.

- [ ] **Step 4: Реализовать exact state enum**

```swift
enum NotchPresentationMode: Equatable { case idle, compact, attention, expanded }
struct NotchPresentationState: Equatable {
    var mode: NotchPresentationMode
    var display: ActivityDisplayState
}
```

Model хранит `lastUserTab: String`, `requestedTab: String?`, generation counter и одну cancellation. `openFromPointer` выставляет `.expanded`; `closeFromPointer` возвращает актуальные `.compact` или `.idle`.

При актуальном attention timeout model сначала вызывает `onAttentionExpired(event)`, чтобы composition передал его в `ActivityCoordinator.settleAttention`, затем возвращается к compact/idle по уже пересчитанному display state. Callback устаревшего generation ничего не делает.

- [ ] **Step 5: Запустить tests и закоммитить**

Run: `swift test --filter NotchPresentationModelTests`

Expected: PASS.

```bash
git add Sources/Cyclop/Activities/NotchPresentationModel.swift Tests/CyclopTests/Activities/NotchPresentationModelTests.swift
git commit -m "feat: model notch presentation states"
```

### Task 8: Вынести чистую геометрию presentation states

**Files:**
- Create: `Sources/Cyclop/Notch/NotchLayoutMetrics.swift`
- Modify: `Sources/Cyclop/Notch/NotchGeometry.swift:3-182`
- Create: `Tests/CyclopTests/Notch/NotchLayoutMetricsTests.swift`

**Interfaces:**
- Consumes: `NotchPresentationMode`.
- Produces: `NotchLayoutMetrics.visibleSize(for:)`, `contentRect(for:)`, `screenRect(for:)`, `hoverRect(for:)`.

- [ ] **Step 1: Написать physical geometry tests**

```swift
func testPhysicalCompactAndAttentionSizes() {
    let metrics = NotchLayoutMetrics(screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        notchSize: CGSize(width: 179, height: 32), notchCenterX: 756, isPhysical: true)
    XCTAssertEqual(metrics.visibleSize(for: .compact), CGSize(width: 315, height: 32))
    XCTAssertEqual(metrics.visibleSize(for: .attention), CGSize(width: 339, height: 60))
}
```

- [ ] **Step 2: Написать synthetic geometry tests**

```swift
let metrics = NotchLayoutMetrics(screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
    notchSize: CGSize(width: 180, height: 24), notchCenterX: 720, isPhysical: false)
XCTAssertEqual(metrics.visibleSize(for: .compact), CGSize(width: 260, height: 40))
XCTAssertEqual(metrics.visibleSize(for: .attention), CGSize(width: 320, height: 56))
XCTAssertTrue(metrics.hoverRect(for: .compact).width <= 272)
```

- [ ] **Step 3: Запустить tests до реализации**

Run: `swift test --filter NotchLayoutMetricsTests`

Expected: FAIL с отсутствующим `NotchLayoutMetrics`.

- [ ] **Step 4: Реализовать formulas**

Physical compact width: `clamp(notchSize.width + 136, 260, 340)`, height `notchSize.height`. Physical attention width: `clamp(notchSize.width + 160, 300, 360)`, height `notchSize.height + 28`. Synthetic sizes фиксированы спецификацией. Expanded всегда `620 × 208`; idle использует текущий collapsed target.

- [ ] **Step 5: Сделать NotchGeometry адаптером от NSScreen**

Сохранить существующие public properties и делегировать pure formulas в `metrics`, чтобы видимое поведение до UI-интеграции не изменилось.

- [ ] **Step 6: Запустить foundation suite и bundle compile**

Run: `swift test --filter 'Activity|NotchLayoutMetrics'`

Expected: PASS.

Run: `swift build`

Expected: PASS.

- [ ] **Step 7: Закоммитить геометрию**

```bash
git add Sources/Cyclop/Notch Tests/CyclopTests/Notch
git commit -m "refactor: extract notch layout metrics"
```

## Foundation checkpoint

Run: `swift test`

Expected: все foundation tests PASS, видимое поведение приложения не изменилось.

Run: `git status --short`

Expected: только `?? .superpowers/`; этот локальный visual-companion artifact не добавлять в git.
