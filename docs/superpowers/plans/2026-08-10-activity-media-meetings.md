# Музыка и встречи как активности — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:test-driven-development. Execute after the activity foundation; reuse `MediaController` and `CalendarStore` instead of replacing them.

**Goal:** Подключить системную музыку и ближайшие встречи к activity coordinator с экономным расписанием и без новых разрешений/приватных API.

**Architecture:** Два тонких адаптера превращают уже существующие published state в `ActivitySnapshot`. Media source управляет 15-секундным grace period после паузы. Meeting source использует чистую policy и один one-shot scheduler для границ threshold/1 minute/start/end, не запуская polling.

**Tech Stack:** Swift, Combine, EventKit через существующий `CalendarStore`, MediaRemote helper через существующий `MediaController`, XCTest.

## Обязательное переиспользование

- Не дублировать Now Playing bridge, artwork decoding, transport actions и fallback: это уже делает `Sources/Cyclop/Services/MediaController.swift`.
- Не дублировать EventKit permission, hidden calendar filtering и meeting link parsing: это уже делает `Sources/Cyclop/Services/CalendarStore.swift`.
- Не запрашивать Calendar access при запуске activity system: текущий явный запрос из Calendar pane сохраняется.
- Яндекс Музыка поддерживается через system Now Playing, как браузер и другие players. Прямой AppleScript fallback остаётся только для Apple Music/Spotify — это существующее ограничение, а не повод добавлять приватную интеграцию.

---

### Task 1: Создать pure media payload и adapter seam

**Files:**
- Create: `Sources/Cyclop/Activities/Media/MediaActivityPayload.swift`
- Create: `Sources/Cyclop/Activities/Media/MediaActivitySource.swift`
- Create: `Tests/CyclopTests/Activities/Media/MediaActivitySourceTests.swift`

**Interfaces:**
- Consumes: `MediaController` state/actions.
- Produces: source ID `media`.

- [ ] **Step 1: Написать playing mapping test**

```swift
@MainActor
func testPlayingTrackMapsMetadataAndTransportActions() {
    let harness = MediaSourceHarness(now: Date(timeIntervalSince1970: 1_000))
    harness.send(.init(trackKey: "track-1", title: "Песня", artist: "Исполнитель",
        album: "Альбом", sourceName: "Яндекс Музыка", isPlaying: true,
        duration: 240, position: 60, canSkip: true))
    let snapshot = harness.latest.snapshots.first
    XCTAssertEqual(snapshot?.kind, .media)
    XCTAssertEqual(snapshot?.phase, .active)
    XCTAssertEqual(snapshot?.title, "Песня")
    XCTAssertEqual(snapshot?.subtitle, "Исполнитель")
    XCTAssertEqual(snapshot?.availableActions, [.pause, .previous, .next])
}
```

- [ ] **Step 2: Определить payload и action seam**

```swift
struct MediaActivityPayload: Equatable {
    let trackKey: String
    let title: String
    let artist: String
    let album: String
    let sourceName: String?
    let isPlaying: Bool
    let duration: TimeInterval
    let position: TimeInterval
    let canSkip: Bool
}

@MainActor
protocol MediaActivityControlling: AnyObject {
    func togglePlayPause()
    func next()
    func previous()
}
```

Добавить `extension MediaController: MediaActivityControlling {}`. Production initializer source подписывается на `track/isPlaying/duration/position/sourceName/canSkip` и собирает payload; test initializer принимает `AnyPublisher<MediaActivityPayload?, Never>` и fake actions.

- [ ] **Step 3: Реализовать source mapping**

```swift
@MainActor
final class MediaActivitySource: ActivitySource {
    let sourceID = "media"
    var statePublisher: AnyPublisher<ActivitySourceState, Never> { state.eraseToAnyPublisher() }
    func perform(_ action: ActivityAction, activityID: ActivityID)
}
```

`ActivityID.local = trackKey`. Playing→`.active`; paused payload временно→`.paused`; `containsSensitiveText = true`. Snapshot progress допустимо вычислить один раз при source event, но compact UI не создаёт ticker для его анимации.

- [ ] **Step 4: Покрыть actions и canSkip**

Playing actions: pause + previous/next только при `canSkip`. Paused actions: play + optional previous/next. Неверный activity ID и чужие actions игнорируются. Tests проверяют ровно один вызов fake controller.

- [ ] **Step 5: Запустить tests и закоммитить**

Run: `swift test --filter MediaActivitySourceTests`

Expected: PASS.

```bash
git add Sources/Cyclop/Activities/Media Tests/CyclopTests/Activities/Media
git commit -m "feat: expose now playing as an activity"
```

### Task 2: Реализовать 15-секундный grace period после паузы

**Files:**
- Modify: `Sources/Cyclop/Activities/Media/MediaActivitySource.swift`
- Create: `Tests/CyclopTests/Activities/Media/MediaPauseGraceTests.swift`

**Interfaces:**
- Consumes: `ActivityClock`, `ActivityScheduling`.
- Produces: pause grace without polling.

- [ ] **Step 1: Написать pause → hide test**

```swift
@MainActor
func testPausedTrackRemainsForFifteenSecondsThenHides() {
    let harness = MediaSourceHarness(now: Date(timeIntervalSince1970: 1_000))
    harness.send(playingTrack())
    harness.send(pausedTrack())
    XCTAssertEqual(harness.latest.snapshots.first?.phase, .paused)
    XCTAssertEqual(harness.scheduler.nextDate, harness.clock.now.addingTimeInterval(15))
    harness.fireNext()
    XCTAssertTrue(harness.latest.snapshots.isEmpty)
}
```

- [ ] **Step 2: Написать resume/new-track cancellation tests**

Resume до 15 секунд отменяет pending hide и сразу возвращает `.active`. Смена track key отменяет timer старого трека; старый scheduled closure не имеет права скрыть новый трек. Empty Now Playing state скрывает сразу.

- [ ] **Step 3: Реализовать generation-safe one-shot**

Хранить `pauseGeneration`, `pauseStartedAt`, одну cancellation. На каждом playing payload отменять cancellation. На paused назначать hide на `now + 15`; callback сравнивает generation и текущий track key.

- [ ] **Step 4: Проверить relaunch semantics**

Grace не персистится. После relaunch source показывает paused track только если system Now Playing ещё отдаёт его, и начинает новые 15 секунд; это не пользовательская задача и не требует disk state.

- [ ] **Step 5: Запустить tests и закоммитить**

Run: `swift test --filter MediaPauseGraceTests`

Expected: PASS.

```bash
git add Sources/Cyclop/Activities/Media Tests/CyclopTests/Activities/Media
git commit -m "feat: keep paused media activity briefly"
```

### Task 3: Определить чистую meeting policy

**Files:**
- Create: `Sources/Cyclop/Activities/Meetings/MeetingActivityPolicy.swift`
- Create: `Tests/CyclopTests/Activities/Meetings/MeetingActivityPolicyTests.swift`

**Interfaces:**
- Produces: visibility, phase, latest milestone и next boundary.

- [ ] **Step 1: Написать table-driven visibility tests**

```swift
func testMeetingAppearsAtConfiguredThresholdAndDisappearsAtEnd() {
    let meeting = fixture(start: date(10, 0), end: date(10, 30))
    let policy = MeetingActivityPolicy(leadMinutes: 15)
    XCTAssertFalse(policy.presentation(for: meeting, now: date(9, 44, 59)).isVisible)
    XCTAssertTrue(policy.presentation(for: meeting, now: date(9, 45)).isVisible)
    XCTAssertTrue(policy.presentation(for: meeting, now: date(10, 0)).isVisible)
    XCTAssertFalse(policy.presentation(for: meeting, now: date(10, 30)).isVisible)
}
```

- [ ] **Step 2: Написать milestone tests для 5/10/15/30**

Для каждого lead value проверить границы `start-lead`, `start-60`, `start`, `end`. Если lead=1 minute не существует в UI, threshold никогда не совпадает с one-minute boundary. При clock jump policy возвращает только самый свежий достигнутый milestone, чтобы после сна не показать три attention подряд.

- [ ] **Step 3: Реализовать policy types**

```swift
struct MeetingActivityInput: Equatable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let link: URL?
    let provider: String?
}

enum MeetingMilestone: String, Equatable { case threshold, oneMinute, started }

struct MeetingPresentation: Equatable {
    let isVisible: Bool
    let phase: ActivityPhase
    let milestone: MeetingMilestone?
    let milestoneDate: Date?
    let nextBoundary: Date?
}
```

Upcoming within lead→`.active`; running→`.active`. `nextBoundary` — ближайшая будущая из threshold/oneMinute/start/end. Milestone возвращается, только если boundary лежит после previous evaluation date и не позже now; initializer source передаёт previous evaluation, чтобы ordinary refresh не переиздавал событие.

- [ ] **Step 4: Покрыть overlaps/all-day/past**

All-day и cancelled уже отфильтрованы `CalendarStore`; policy не повторяет фильтрацию. Несколько overlapping meetings остаются отдельными snapshots; ranking выберет ближайшую start/deadline.

- [ ] **Step 5: Запустить tests и закоммитить**

Run: `swift test --filter MeetingActivityPolicyTests`

Expected: PASS.

```bash
git add Sources/Cyclop/Activities/Meetings Tests/CyclopTests/Activities/Meetings
git commit -m "feat: define meeting activity policy"
```

### Task 4: Адаптировать CalendarStore событийно

**Files:**
- Create: `Sources/Cyclop/Activities/Meetings/MeetingActivitySource.swift`
- Create: `Tests/CyclopTests/Activities/Meetings/MeetingActivitySourceTests.swift`

**Interfaces:**
- Consumes: `CalendarStore.$meetings`, `CalendarStore.$access`, `ActivitySettings.meetingLeadMinutes`, clock/scheduler.
- Produces: source ID `meetings`.

- [ ] **Step 1: Написать mapping test**

```swift
@MainActor
func testUpcomingMeetingMapsJoinActionAndDeadline() {
    let harness = MeetingSourceHarness(now: date(9, 50), leadMinutes: 15)
    harness.send([meeting(id: "42", title: "Планирование", start: date(10, 0),
        end: date(10, 30), link: URL(string: "https://meet.example/42"))])
    let snapshot = harness.latest.snapshots.first
    XCTAssertEqual(snapshot?.id, ActivityID(source: "meetings", local: "42"))
    XCTAssertEqual(snapshot?.deadline, date(10, 0))
    XCTAssertEqual(snapshot?.availableActions, [.join])
}
```

- [ ] **Step 2: Реализовать production/test initializers**

```swift
@MainActor
final class MeetingActivitySource: ActivitySource {
    let sourceID = "meetings"
    init(calendar: CalendarStore, settings: ActivitySettings,
         clock: ActivityClock, scheduler: ActivityScheduling)
    init(states: AnyPublisher<MeetingSourceInput, Never>, leadMinutes: AnyPublisher<Int, Never>,
         opener: @escaping (URL) -> Void, clock: ActivityClock, scheduler: ActivityScheduling)
}
```

Production mapping сохраняет `CalendarStore.Meeting` только как `MeetingActivityInput`; source не обращается к `EKEventStore` и не вызывает `requestAccess()`.

- [ ] **Step 3: Реализовать один boundary scheduler**

На update meetings/lead threshold пересчитать snapshots, отменить один pending wake и назначить ближайший `nextBoundary` среди всех meetings. Callback пересчитывает policy от current clock и назначает следующий. Никакого 30-second polling в collapsed state.

- [ ] **Step 4: Реализовать attention marker**

При milestone snapshot получает `occurredAt = milestoneDate`; transition policy выводит kind по отношению к `deadline`: threshold, one minute или start. Stable event ID: `meeting:<eventID>:<milestoneRaw>:<milestoneEpoch>`. Обычные CalendarStore reload с теми же данными не переиздают marker.

- [ ] **Step 5: Реализовать access health**

`.notRequested`→available + empty snapshots (не показывать ошибку и не prompting); `.denied`→unavailable message `Нет доступа к календарю`; `.granted`→policy output. Activity center отображает recovery link на existing Calendar tab/settings, но источник сам не открывает системный prompt.

- [ ] **Step 6: Реализовать join action**

Только `.join` для совпавшего ID и non-nil HTTPS/custom meeting URL. Production opener использует `NSWorkspace.shared.open`. В privacy mode URL не попадает в snapshot display text.

- [ ] **Step 7: Запустить tests и закоммитить**

Run: `swift test --filter MeetingActivitySourceTests`

Expected: PASS.

```bash
git add Sources/Cyclop/Activities/Meetings Tests/CyclopTests/Activities/Meetings
git commit -m "feat: expose upcoming meetings as activities"
```

### Task 5: Проверить реальных media providers без provider-specific кода

**Files:**
- Create: `docs/testing/activity-media-manual-matrix.md`
- Modify: `Tests/CyclopTests/Activities/Media/MediaActivitySourceTests.swift`

- [ ] **Step 1: Добавить provider-neutral contract test**

Один и тот же payload/action suite прогнать для source names `Music`, `Spotify`, `Safari`, `Google Chrome`, `Яндекс Музыка`; sourceName влияет только на subtitle/badge и никогда на доступность activity.

- [ ] **Step 2: Описать manual matrix**

Для Apple Music, Spotify, Safari/Chrome media и Яндекс Музыки в браузере проверить track metadata, artwork в expanded existing media pane, play/pause, skip capability, смену трека, pause grace. Для desktop Яндекс Музыки выполнить те же проверки, если клиент публикует системный Now Playing; иначе зафиксировать ограничение macOS integration без добавления scraping/Accessibility permission.

- [ ] **Step 3: Зафиксировать fallback limitation**

В matrix явно указать: при недоступном NowPlaying helper существующий fallback видит Apple Music/Spotify, но не обещает browser/Яндекс Музыку. Это degraded mode и health diagnostic, не silent claim полной поддержки.

- [ ] **Step 4: Запустить source suites и закоммитить**

Run: `swift test --filter 'Media|Meeting'`

Expected: PASS.

```bash
git add Tests/CyclopTests/Activities/Media docs/testing/activity-media-manual-matrix.md
git commit -m "test: define media provider acceptance matrix"
```

## Media/meetings checkpoint

Run: `swift test --filter 'Media|Meeting|ActivityAttention|ActivityRanking'`

Expected: paused music disappears exactly after 15 seconds; meetings appear at configured boundary; sleep/reload does not replay stale milestones; no Calendar prompt appears on app launch.
