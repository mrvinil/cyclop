# Таймеры Cyclop — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:test-driven-development while implementing every task. Execute after `2026-08-10-activity-foundation.md`.

**Goal:** Реализовать несколько собственных надёжных таймеров Cyclop с созданием, паузой, продолжением, отменой, восстановлением после перезапуска/сна и однократным звуковым сигналом завершения.

**Architecture:** `TimerStore` — единственный владелец состояния и единственного deadline-scheduler. Оставшееся время выводится из wall-clock deadline, а не из числа тиков. JSON persistence и sound player внедряются протоколами. `TimerActivitySource` только адаптирует таймеры к общему activity contract.

**Tech Stack:** Swift, Foundation, Combine, AppKit/NSSound, XCTest.

## Ограничения

- Не использовать notification permission, приватные API и отдельный helper process.
- Пресеты: 5, 10, 25, 45 и 60 минут; custom duration — часы/минуты/секунды.
- Разрешить несколько одновременных таймеров.
- Не держать повторяющийся тик, когда countdown UI не виден.
- `timers.json` хранить атомарно в `~/Library/Application Support/Cyclop/`.
- После завершения сигнал проигрывается один раз, attention длится 10 секунд, затем остаётся indicator до dismiss.
- Все ошибки и подписи UI добавляются в UI-плане на русском и английском.

---

### Task 1: Определить timer model и JSON persistence

**Files:**
- Create: `Sources/Cyclop/Activities/Timers/CyclopTimer.swift`
- Create: `Sources/Cyclop/Activities/Timers/TimerPersistence.swift`
- Create: `Tests/CyclopTests/Activities/Timers/TimerPersistenceTests.swift`

**Interfaces:**
- Produces: `CyclopTimer`, `TimerPhase`, `TimerPersisting`, `JSONTimerPersistence`.

- [ ] **Step 1: Написать round-trip test**

```swift
final class TimerPersistenceTests: XCTestCase {
    func testRoundTripPreservesPausedAndCompletedState() throws {
        let file = temporaryDirectory.appendingPathComponent("timers.json")
        let persistence = JSONTimerPersistence(fileURL: file)
        let timers = [
            CyclopTimer(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                name: "Фокус", originalDuration: 1_500, phase: .paused,
                endsAt: nil, pausedRemaining: 420, completedAt: nil,
                completionSoundPlayed: false),
            CyclopTimer(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
                name: "Чай", originalDuration: 300, phase: .completed,
                endsAt: nil, pausedRemaining: 0, completedAt: Date(timeIntervalSince1970: 200),
                completionSoundPlayed: true)
        ]
        try persistence.save(timers)
        XCTAssertEqual(try persistence.load(), timers)
    }
}
```

- [ ] **Step 2: Запустить test до реализации**

Run: `swift test --filter TimerPersistenceTests`

Expected: FAIL с отсутствующими `CyclopTimer` и `JSONTimerPersistence`.

- [ ] **Step 3: Реализовать codable model**

```swift
enum TimerPhase: String, Codable, Equatable { case running, paused, completed, cancelled }

struct CyclopTimer: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    let originalDuration: TimeInterval
    var phase: TimerPhase
    var endsAt: Date?
    var pausedRemaining: TimeInterval?
    var completedAt: Date?
    var completionSoundPlayed: Bool

    func remaining(at now: Date) -> TimeInterval {
        switch phase {
        case .running: return max(0, endsAt?.timeIntervalSince(now) ?? 0)
        case .paused: return max(0, pausedRemaining ?? 0)
        case .completed, .cancelled: return 0
        }
    }
}
```

- [ ] **Step 4: Реализовать атомарное persistence**

```swift
protocol TimerPersisting {
    func load() throws -> [CyclopTimer]
    func save(_ timers: [CyclopTimer]) throws
}

struct JSONTimerPersistence: TimerPersisting {
    let fileURL: URL

    static func live(fileManager: FileManager = .default) -> Self {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return Self(fileURL: base.appendingPathComponent("Cyclop/timers.json"))
    }

    func save(_ timers: [CyclopTimer]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        try encoder.encode(timers).write(to: fileURL, options: .atomic)
    }
}
```

`load()` возвращает `[]`, только если файла ещё нет; invalid JSON обязан бросить ошибку. Декодер использует `.millisecondsSince1970`.

- [ ] **Step 5: Добавить tests отсутствующего и повреждённого файла**

```swift
XCTAssertEqual(try JSONTimerPersistence(fileURL: missing).load(), [])
try Data("not-json".utf8).write(to: broken)
XCTAssertThrowsError(try JSONTimerPersistence(fileURL: broken).load())
```

- [ ] **Step 6: Запустить tests и закоммитить**

Run: `swift test --filter TimerPersistenceTests`

Expected: PASS.

```bash
git add Sources/Cyclop/Activities/Timers Tests/CyclopTests/Activities/Timers
git commit -m "feat: persist Cyclop timers"
```

### Task 2: Реализовать lifecycle таймеров через wall-clock deadlines

**Files:**
- Create: `Sources/Cyclop/Activities/Timers/TimerStore.swift`
- Create: `Tests/CyclopTests/Activities/Timers/TimerStoreTests.swift`
- Modify: `Tests/CyclopTests/Support/ActivityTestDoubles.swift`

**Interfaces:**
- Consumes: `ActivityClock`, `ActivityScheduling`, `TimerPersisting`.
- Produces: `TimerStore.create`, `pause`, `resume`, `cancel`, `dismiss`, `remaining`.

- [ ] **Step 1: Добавить memory persistence double**

```swift
final class MemoryTimerPersistence: TimerPersisting {
    var stored: [CyclopTimer]
    var loadError: Error?
    var saveError: Error?
    init(_ stored: [CyclopTimer] = []) { self.stored = stored }
    func load() throws -> [CyclopTimer] {
        if let loadError { throw loadError }
        return stored
    }
    func save(_ timers: [CyclopTimer]) throws {
        if let saveError { throw saveError }
        stored = timers
    }
}
```

- [ ] **Step 2: Написать test create → pause → resume → cancel**

```swift
@MainActor
func testLifecycleUsesDeadlineAndPersistsEveryMutation() throws {
    let clock = MutableActivityClock(now: Date(timeIntervalSince1970: 1_000))
    let persistence = MemoryTimerPersistence()
    let store = TimerStore(clock: clock, scheduler: ManualActivityScheduler(), persistence: persistence)
    try store.start()

    let id = try store.create(name: "Фокус", duration: 600)
    XCTAssertEqual(store.timer(id)?.endsAt, clock.now.addingTimeInterval(600))
    clock.advance(by: 100)
    try store.pause(id)
    XCTAssertEqual(store.timer(id)?.pausedRemaining, 500)
    clock.advance(by: 50)
    try store.resume(id)
    XCTAssertEqual(store.timer(id)?.endsAt, clock.now.addingTimeInterval(500))
    try store.cancel(id)
    XCTAssertEqual(store.timer(id)?.phase, .cancelled)
    XCTAssertEqual(persistence.stored, store.timers)
}
```

- [ ] **Step 3: Запустить test до реализации**

Run: `swift test --filter TimerStoreTests/testLifecycle`

Expected: FAIL с отсутствующим `TimerStore`.

- [ ] **Step 4: Реализовать public API и validation**

```swift
enum TimerStoreError: LocalizedError, Equatable {
    case invalidDuration
    case timerNotFound
    case invalidTransition
    case persistenceFailed
}

@MainActor
final class TimerStore: ObservableObject {
    @Published private(set) var timers: [CyclopTimer] = []
    @Published private(set) var health: ActivitySourceHealth = .available

    func start() throws
    func stop()
    @discardableResult func create(name: String, duration: TimeInterval) throws -> UUID
    func pause(_ id: UUID) throws
    func resume(_ id: UUID) throws
    func cancel(_ id: UUID) throws
    func dismiss(_ id: UUID) throws
    func restart(_ id: UUID) throws
    func timer(_ id: UUID) -> CyclopTimer?
    func remaining(for id: UUID) -> TimeInterval?
}
```

`duration` допустима в диапазоне `1...359_999` секунд. Пустое имя нормализуется в `"Таймер"` на model/UI boundary. `dismiss` удаляет только `.completed` и `.cancelled`. `restart` сохраняет тот же UUID/name/duration, выставляет новый `endsAt = now + originalDuration` и сбрасывает completion fields/sound flag. Каждая мутация сначала формирует новый массив, затем сохраняет его, и лишь после успешного save публикует — UI не должен показывать несохранённое состояние.

- [ ] **Step 5: Реализовать один deadline scheduler**

После каждой мутации отменять единственный `scheduledWake`, выбирать минимальный `endsAt` среди running timers и назначать одно пробуждение. Callback вызывает `reconcile(now:)`, а затем планирует следующее. Не создавать один `Foundation.Timer` на запись.

```swift
private func scheduleNextWake() {
    scheduledWake?.cancel()
    guard let next = timers.compactMap({ $0.phase == .running ? $0.endsAt : nil }).min() else {
        scheduledWake = nil
        return
    }
    scheduledWake = scheduler.schedule(at: next) { [weak self] in self?.reconcile() }
}
```

- [ ] **Step 6: Проверить invalid transitions**

Test matrix: running→pause/cancel; paused→resume/cancel; completed→dismiss/restart; cancelled→dismiss/restart. Повторные pause/resume и действие над неизвестным UUID возвращают соответствующую ошибку и не меняют persistence.

- [ ] **Step 7: Запустить suite и закоммитить**

Run: `swift test --filter TimerStoreTests`

Expected: PASS.

```bash
git add Sources/Cyclop/Activities/Timers/TimerStore.swift Tests/CyclopTests
git commit -m "feat: manage multiple Cyclop timers"
```

### Task 3: Восстанавливать завершения после сна/перезапуска и проигрывать сигнал один раз

**Files:**
- Modify: `Sources/Cyclop/Activities/Timers/TimerStore.swift`
- Create: `Sources/Cyclop/Activities/Timers/TimerSoundPlayer.swift`
- Create: `Tests/CyclopTests/Activities/Timers/TimerRecoveryTests.swift`

**Interfaces:**
- Produces: `TimerSoundPlaying`, `SystemTimerSoundPlayer`, one-shot completion transition.

- [ ] **Step 1: Написать recovery test**

```swift
@MainActor
func testStartCompletesExpiredTimerAndPlaysSoundExactlyOnce() throws {
    let expired = runningTimer(endsAt: Date(timeIntervalSince1970: 900))
    let persistence = MemoryTimerPersistence([expired])
    let sound = SpyTimerSoundPlayer()
    let store = TimerStore(clock: MutableActivityClock(now: Date(timeIntervalSince1970: 1_000)),
        scheduler: ManualActivityScheduler(), persistence: persistence, soundPlayer: sound)

    try store.start()
    XCTAssertEqual(store.timer(expired.id)?.phase, .completed)
    XCTAssertEqual(sound.playCount, 1)
    store.stop()
    try store.start()
    XCTAssertEqual(sound.playCount, 1)
}
```

- [ ] **Step 2: Добавить sound protocol и spy**

```swift
protocol TimerSoundPlaying { func playCompletion() }

struct SystemTimerSoundPlayer: TimerSoundPlaying {
    func playCompletion() { NSSound(named: "Glass")?.play() }
}

final class SpyTimerSoundPlayer: TimerSoundPlaying {
    private(set) var playCount = 0
    func playCompletion() { playCount += 1 }
}
```

- [ ] **Step 3: Реализовать reconcile как атомарный переход**

Для каждого running timer с `endsAt <= now`: выставить `.completed`, `completedAt = endsAt`, `endsAt = nil`, `pausedRemaining = 0`. Сначала сохранить все переходы одним write и опубликовать. Для каждой записи, которой нужен звук, сначала атомарно сохранить `completionSoundPlayed = true`, затем вызвать sound player. Такой порядок даёт at-most-once сигнал при crash между side effect и записью; если запись флага не удалась, звук не проигрывается и source показывает ошибку вместо возможного дубля после relaunch.

- [ ] **Step 4: Покрыть сон и несколько одновременных завершений**

Один callback после скачка clock на час должен завершить все просроченные таймеры, но сделать один UI publish. Каждый таймер получает собственное completion event и не звучит повторно после restart.

- [ ] **Step 5: Покрыть persistence failure**

Если save completion transition падает, исходные running records остаются опубликованы, `health = .unavailable(message: "Не удалось сохранить таймеры")`; звук не проигрывается. Следующий lifecycle/reload может повторить reconcile.

- [ ] **Step 6: Запустить tests и закоммитить**

Run: `swift test --filter TimerRecoveryTests`

Expected: PASS.

```bash
git add Sources/Cyclop/Activities/Timers Tests/CyclopTests/Activities/Timers
git commit -m "feat: recover completed timers reliably"
```

### Task 4: Добавить экономный visible countdown ticker

**Files:**
- Modify: `Sources/Cyclop/Activities/Timers/TimerStore.swift`
- Create: `Tests/CyclopTests/Activities/Timers/TimerCountdownTests.swift`

**Interfaces:**
- Produces: `setCountdownVisible(_:)`, `@Published countdownRevision`.

- [ ] **Step 1: Написать energy-behavior tests**

```swift
@MainActor
func testNoSecondWakeIsScheduledWhileCountdownIsHidden() throws {
    let scheduler = ManualActivityScheduler()
    let store = makeStore(scheduler: scheduler)
    _ = try store.create(name: "Фокус", duration: 600)
    XCTAssertEqual(scheduler.activeEntries.count, 1) // только deadline
}

@MainActor
func testVisibleCountdownSchedulesAtMostOneOneSecondWake() throws {
    let scheduler = ManualActivityScheduler()
    let store = makeStore(scheduler: scheduler)
    _ = try store.create(name: "Фокус", duration: 600)
    store.setCountdownVisible(true)
    XCTAssertLessThanOrEqual(scheduler.activeEntries.count, 1)
}
```

- [ ] **Step 2: Объединить deadline и UI pulse в один wake**

Store вычисляет `nextWake = min(nearestDeadline, nextWholeSecond)` только когда visible; один callback увеличивает `countdownRevision`, делает reconcile и заново планирует wake. При `setCountdownVisible(false)` ближайшим wake снова становится только deadline. При отсутствии running timers scheduler пуст.

- [ ] **Step 3: Запустить tests и закоммитить**

Run: `swift test --filter TimerCountdownTests`

Expected: PASS.

```bash
git add Sources/Cyclop/Activities/Timers/TimerStore.swift Tests/CyclopTests/Activities/Timers/TimerCountdownTests.swift
git commit -m "perf: tick timer countdowns only while visible"
```

### Task 5: Адаптировать таймеры к ActivitySource

**Files:**
- Create: `Sources/Cyclop/Activities/Timers/TimerActivitySource.swift`
- Create: `Tests/CyclopTests/Activities/Timers/TimerActivitySourceTests.swift`

**Interfaces:**
- Consumes: `TimerStore`.
- Produces: source ID `timers`, snapshots и action routing.

- [ ] **Step 1: Написать mapping test**

```swift
@MainActor
func testMapsPhasesDeadlinesAndActions() throws {
    let store = makeTimerStore()
    let runningID = try store.create(name: "Фокус", duration: 1_500)
    let source = TimerActivitySource(store: store)
    let state = awaitValue(source.statePublisher)
    let snapshot = try XCTUnwrap(state.snapshots.first { $0.id.local == runningID.uuidString })
    XCTAssertEqual(snapshot.phase, .active)
    XCTAssertEqual(snapshot.availableActions, [.pause, .cancel])
    XCTAssertEqual(snapshot.deadline, store.timer(runningID)?.endsAt)
}
```

- [ ] **Step 2: Реализовать mapping**

```swift
@MainActor
final class TimerActivitySource: ActivitySource {
    let sourceID = "timers"
    var statePublisher: AnyPublisher<ActivitySourceState, Never> { state.eraseToAnyPublisher() }
    func perform(_ action: ActivityAction, activityID: ActivityID)
}
```

Mapping: running→`.active` + pause/cancel; paused→`.paused` + resume/cancel; completed→`.completed` + dismiss/restart; cancelled records не публикуются. `occurredAt` для completed равен `completedAt`, чтобы attention ID оставался стабильным после relaunch.

- [ ] **Step 3: Покрыть action routing**

`pause/resume/cancel/dismiss/restart` вызывают соответствующий store method; неподдерживаемое действие игнорируется и логируется. Ошибка store публикуется в `health`, но не приводит к crash.

- [ ] **Step 4: Запустить полный timer suite**

Run: `swift test --filter Timer`

Expected: PASS.

Run: `swift build`

Expected: PASS.

- [ ] **Step 5: Закоммитить adapter**

```bash
git add Sources/Cyclop/Activities/Timers Tests/CyclopTests/Activities/Timers
git commit -m "feat: expose timers as activities"
```

## Timer checkpoint

Run: `swift test --filter 'Timer|ActivityCoordinator|ActivityAttention'`

Expected: все tests PASS; expired timers после relaunch становятся completed; повторного звука нет; в idle нет секундного ticker.
