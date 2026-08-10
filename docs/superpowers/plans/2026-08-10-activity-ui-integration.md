# UI и интеграция центра активностей — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:test-driven-development for view models and integration logic; use superpowers:verification-before-completion before the checkpoint. Execute after foundation, timers, downloads, media and meetings.

**Goal:** Встроить полноценный центр активностей в существующий notch UI: отдельная вкладка, compact/attention states, adaptive depth, настройки, privacy, drag/paste URL и app lifecycle.

**Architecture:** `NotchViewModel` становится composition root сервисов, но продуктовые решения остаются в `ActivityCoordinator`, `ActivityCenterViewModel` и `NotchPresentationModel`. SwiftUI использует общий card shell и небольшие видовые cards. `NotchController` продолжает владеть одним `NSPanel`, pointer, keyboard и active rect, подписываясь на готовое presentation state.

**Tech Stack:** SwiftUI, AppKit, Combine, XCTest, существующие Theme/NotchShape/Rail/PrivacyMode/localization tables.

## UI-инварианты

- Новая вкладка «Активности» находится первой на правом rail: Активности, Заметки, Настройки.
- Автоматическое открытие active island временно выбирает «Активности», но не перезаписывает последнюю ручную вкладку.
- В idle hover открывает последнюю ручную вкладку.
- Compact показывает один приоритет и до трёх visual slots; при 4+ — два индикатора и `+N`.
- Physical notch использует боковые wings; synthetic notch — центральную capsule с adaptive depth.
- Никакой анимации frame самого `NSPanel`; меняются content size, active rect и SwiftUI shape/content.
- Activities URL field получает клавиатуру только после клика, а не от одного hover.
- Все новые видимые строки добавляются в `Resources/en.lproj/Localizable.strings` и `Resources/ru.lproj/Localizable.strings`; русские формулировки являются целевым UX.

---

### Task 1: Создать ActivityCenterViewModel

**Files:**
- Create: `Sources/Cyclop/Activities/UI/ActivityCenterViewModel.swift`
- Create: `Tests/CyclopTests/Activities/UI/ActivityCenterViewModelTests.swift`

**Interfaces:**
- Consumes: coordinator display state, timer/download services, privacy.
- Produces: ordered card models, composer state, diagnostics, scroll target.

- [ ] **Step 1: Написать card ordering и masking test**

```swift
@MainActor
func testBuildsOrderedCardsAndMasksSensitiveText() {
    let harness = ActivityCenterHarness()
    harness.send(displayState(allActivities: [media(), runningTimer(), completedDownload()]))
    harness.privacy.setCovering(.activities, true)
    XCTAssertEqual(harness.model.cards.map(\.kind), [.timer, .media, .download])
    XCTAssertEqual(harness.model.cards[1].title, "Скрытая активность")
    XCTAssertNotNil(harness.model.cards[0].countdown)
}
```

- [ ] **Step 2: Определить presentation models**

```swift
struct ActivityCardModel: Identifiable, Equatable {
    let id: ActivityID
    let kind: ActivityKind
    let phase: ActivityPhase
    let title: String
    let subtitle: String
    let progress: Double?
    let countdown: TimeInterval?
    let actions: [ActivityAction]
    let isMasked: Bool
}

struct ActivityDiagnosticModel: Identifiable, Equatable {
    let id: String
    let message: String
}
```

- [ ] **Step 3: Реализовать observable view model**

```swift
@MainActor
final class ActivityCenterViewModel: ObservableObject {
    @Published private(set) var cards: [ActivityCardModel] = []
    @Published private(set) var diagnostics: [ActivityDiagnosticModel] = []
    @Published var timerComposerPresented = false
    @Published var downloadURL = ""
    @Published var scrollTarget: ActivityID?

    func perform(_ action: ActivityAction, on id: ActivityID)
    func createTimer(name: String, duration: TimeInterval) throws
    func enqueueDownload() throws
    func enqueueDownload(url: URL) throws
    func reveal(_ id: ActivityID)
}
```

Маскировать только `title/subtitle` для `containsSensitiveText`; countdown/progress/actions остаются. Значение placeholder: localized `Hidden Activity` / `Скрытая активность`. Raw snapshot не записывать в SwiftUI state дольше coordinator state; reveal ID хранится в `PrivacyMode.revealed`.

- [ ] **Step 4: Реализовать countdown visibility handshake**

`setVisible(_:)` сообщает `TimerStore.setCountdownVisible`; при hidden не запускает ticker. View model пересобирает countdown на `TimerStore.$countdownRevision`. Compact visibility передаётся отдельно: running timer считается visible, когда он primary/indicator или Activities pane открыта. При переходе pane в visible view model вызывает coordinator `markViewed` для failed/completed downloads: карточки остаются в центре, но просмотренные события больше не занимают compact indicators. Completed timers этим вызовом не скрываются.

- [ ] **Step 5: Покрыть errors и scroll target**

Composer validation ошибки публикуются как localized transient error: `Укажите длительность таймера`, `Вставьте ссылку HTTP или HTTPS`, `Не удалось начать загрузку`. Indicator selection ставит `scrollTarget`, view сбрасывает его после `ScrollViewReader.scrollTo`.

- [ ] **Step 6: Запустить tests и закоммитить**

Run: `swift test --filter ActivityCenterViewModelTests`

Expected: PASS.

```bash
git add Sources/Cyclop/Activities/UI Tests/CyclopTests/Activities/UI
git commit -m "feat: add activity center view model"
```

### Task 2: Построить вкладку «Активности» из shared cards

**Files:**
- Create: `Sources/Cyclop/UI/Activities/ActivityCenterPane.swift`
- Create: `Sources/Cyclop/UI/Activities/ActivityCardShell.swift`
- Create: `Sources/Cyclop/UI/Activities/MediaActivityCard.swift`
- Create: `Sources/Cyclop/UI/Activities/MeetingActivityCard.swift`
- Create: `Sources/Cyclop/UI/Activities/TimerActivityCard.swift`
- Create: `Sources/Cyclop/UI/Activities/DownloadActivityCard.swift`
- Create: `Sources/Cyclop/UI/Activities/ActivityActionButton.swift`
- Create: `Tests/CyclopTests/Activities/UI/ActivityActionPresentationTests.swift`

- [ ] **Step 1: Написать pure action presentation test**

```swift
func testEveryActionHasRussianLabelAndSystemSymbol() {
    for action in ActivityAction.allCases {
        XCTAssertFalse(ActivityActionPresentation.labelKey(action).isEmpty)
        XCTAssertFalse(ActivityActionPresentation.symbol(action).isEmpty)
    }
}
```

Добавить `CaseIterable` к `ActivityAction` в foundation model.

- [ ] **Step 2: Реализовать shared shell**

```swift
struct ActivityCardShell<Content: View, Actions: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    let subtitle: String
    let progress: Double?
    @ViewBuilder let content: () -> Content
    @ViewBuilder let actions: () -> Actions
}
```

Переиспользовать `Theme.surface`, `Theme.secondary`, типографику существующих panes и monospaced digits. Не копировать background/padding/action styling в four cards.

- [ ] **Step 3: Реализовать small kind-specific cards**

- Media: source/artist + play/pause/previous/next; без второго scrubber.
- Meeting: countdown/start/provider + join.
- Timer: countdown/phase + pause/resume/cancel/dismiss/restart.
- Download: determinate/indeterminate progress, bytes, state + pause/resume/cancel/retry/open/reveal/dismiss.

Каждая card получает только `ActivityCardModel` и `perform` closure; ни одна card не импортирует EventKit/URLSession и не обращается к store напрямую.

- [ ] **Step 4: Реализовать pane**

```swift
struct ActivityCenterPane: View {
    @ObservedObject var model: ActivityCenterViewModel
    @Binding var wantsKeyboard: Bool
}
```

`ScrollViewReader` показывает diagnostics, cards и composer controls. Empty state: `Активностей пока нет`, buttons `Новый таймер`, `Скачать по ссылке`. Diagnostics не вытесняют рабочие cards.

- [ ] **Step 5: Добавить accessibility**

Cards объединяют title/state/countdown в accessibility element; buttons имеют labels и hints; progress получает `.accessibilityValue`; masked title не раскрывается accessibility API. Порядок focus совпадает с визуальным.

- [ ] **Step 6: Проверить compile и закоммитить**

Run: `swift build`

Expected: PASS.

```bash
git add Sources/Cyclop/UI/Activities Tests/CyclopTests/Activities/UI
git commit -m "feat: build activity center cards"
```

### Task 3: Добавить timer и download composers

**Files:**
- Create: `Sources/Cyclop/UI/Activities/TimerComposer.swift`
- Create: `Sources/Cyclop/UI/Activities/DownloadComposer.swift`
- Modify: `Sources/Cyclop/UI/Activities/ActivityCenterPane.swift`
- Create: `Tests/CyclopTests/Activities/UI/ActivityComposerValidationTests.swift`

- [ ] **Step 1: Написать timer validation tests**

Presets `[5, 10, 25, 45, 60]`; custom h/m/s нормализуется в seconds; all-zero и значение >359999 отклоняются; whitespace-only name становится localized `Таймер`.

- [ ] **Step 2: Реализовать TimerComposer**

Compact form: optional name, preset chips, `ч/мин/с`, buttons `Создать`/`Отмена`. Submit вызывает view model, очищает fields только после успеха и отдаёт keyboard назад (`wantsKeyboard = false`).

- [ ] **Step 3: Написать download validation tests**

Trim pasted text; HTTP/HTTPS accepted; multiple lines, file URL, missing scheme rejected. Error remains next to field and не закрывает composer.

- [ ] **Step 4: Реализовать DownloadComposer**

Один `TextField("HTTPS-ссылка")`, paste работает нативно, submit button `Скачать`. Drop highlight сообщает `Перетащите ссылку сюда`. Не читать clipboard автоматически.

- [ ] **Step 5: Запустить tests и закоммитить**

Run: `swift test --filter ActivityComposerValidationTests`

Expected: PASS.

```bash
git add Sources/Cyclop/UI/Activities Tests/CyclopTests/Activities/UI
git commit -m "feat: create timers and downloads from activity center"
```

### Task 4: Добавить вкладку и безопасную keyboard/drop маршрутизацию

**Files:**
- Modify: `Sources/Cyclop/Model/NotchViewModel.swift:6-74,94-214`
- Modify: `Sources/Cyclop/UI/NotchContentView.swift:44-168`
- Modify: `Sources/Cyclop/Notch/NotchRootView.swift:15-116`
- Modify: `Sources/Cyclop/Notch/NotchController.swift:88-180`
- Create: `Sources/Cyclop/Notch/NotchDropPayload.swift`
- Create: `Tests/CyclopTests/Notch/NotchDropPayloadTests.swift`

- [ ] **Step 1: Добавить tab metadata tests**

```swift
func testActivitiesIsFirstRightRailTabWithoutAutomaticKeyboard() {
    XCTAssertEqual(NotchViewModel.Tab.rightRail, [.activities, .notes, .settings])
    XCTAssertTrue(NotchViewModel.Tab.activities.supportsKeyboard)
    XCTAssertFalse(NotchViewModel.Tab.activities.autoRequestsKeyboard)
}
```

- [ ] **Step 2: Расширить Tab**

Добавить `.activities`, symbol `sparkles.rectangle.stack.fill`, title `localized("Activities")`. Заменить `needsKeyboard` на:

```swift
var supportsKeyboard: Bool {
    [.activities, .translate, .snippets, .notes].contains(self)
}
var autoRequestsKeyboard: Bool {
    [.translate, .snippets, .notes].contains(self)
}
```

`select` выставляет `wantsKeyboard` только для autoRequestsKeyboard. `panel.onPress` проверяет supportsKeyboard; конкретный `TextField.onTapGesture`/focus change поднимает binding.

- [ ] **Step 3: Подключить pane/header**

`NotchContentView.pane` добавляет `ActivityCenterPane(model:wantsKeyboard:)`. Header activities показывает число active cards/diagnostics. Existing panes остаются неизменными.

- [ ] **Step 4: Ввести typed drop payload**

```swift
enum NotchDropPayload: Equatable {
    case files([URL])
    case remoteURLs([URL])
}
```

`NotchRootView` register types `[.fileURL, .URL, .string]`, сначала извлекает HTTP/HTTPS URL, затем file URLs. Никакие произвольные строки не считаются URL. Callback signatures получают payload.

- [ ] **Step 5: Маршрутизировать drops**

Files сохраняют старое поведение: select Shelf + `shelf.add`. Remote URL: select Activities, открыть download composer, enqueue только после successful drop; при нескольких URL создать records в исходном порядке. Смешанный payload с files+remote URLs отклонить целиком и показать localized hint, чтобы не выполнить неожиданную половину операции.

- [ ] **Step 6: Запустить tests/build и закоммитить**

Run: `swift test --filter 'NotchDropPayload|NotchViewModel'`

Expected: PASS.

Run: `swift build`

Expected: PASS.

```bash
git add Sources/Cyclop/Model/NotchViewModel.swift Sources/Cyclop/UI/NotchContentView.swift Sources/Cyclop/Notch Tests/CyclopTests/Notch
git commit -m "feat: add activities tab and URL drops"
```

### Task 5: Отрисовать compact/attention island и adaptive depth

**Files:**
- Create: `Sources/Cyclop/UI/Activities/CompactActivityView.swift`
- Create: `Sources/Cyclop/UI/Activities/AttentionActivityView.swift`
- Create: `Sources/Cyclop/UI/Activities/ActivityIndicatorView.swift`
- Create: `Sources/Cyclop/UI/Activities/MediaEqualizerView.swift`
- Modify: `Sources/Cyclop/UI/NotchContentView.swift:3-51`
- Modify: `Sources/Cyclop/Model/NotchViewModel.swift`
- Modify: `Sources/Cyclop/Notch/NotchController.swift:185-316`
- Create: `Tests/CyclopTests/Activities/UI/MediaAnimationPolicyTests.swift`

- [ ] **Step 1: Написать animation policy tests**

```swift
func testModesRespectPlaybackAndReduceMotion() {
    XCTAssertEqual(MediaAnimationPolicy(mode: .static, isPlaying: true, reduceMotion: false).cadence, nil)
    XCTAssertEqual(MediaAnimationPolicy(mode: .slow, isPlaying: true, reduceMotion: false).cadence, 0.8)
    XCTAssertEqual(MediaAnimationPolicy(mode: .fluid, isPlaying: true, reduceMotion: false).cadence, 0.25)
    XCTAssertNil(MediaAnimationPolicy(mode: .fluid, isPlaying: true, reduceMotion: true).cadence)
}
```

- [ ] **Step 2: Реализовать compact compositions**

Physical layout: `leftWing + transparent notch gap + rightWing`; primary title/state в крыльях, indicators на противоположной стороне. Synthetic layout: единая black capsule шириной/глубиной из metrics. Обрезать длинный title одной строкой; countdown monospaced; masked text не попадает в tooltip.

- [ ] **Step 3: Реализовать indicator slots**

До 3 activity indicators; при overflow два + `+N`. Click/tap вызывает `presentation.open(activityID:)`, временно выбирает Activities и ставит scroll target. Индикаторы имеют 24pt hit target только внутри current active rect.

- [ ] **Step 4: Реализовать attention**

Attention view показывает title + короткий status (`Таймер завершён`, `Встреча через минуту`, `Загрузка завершена`, error). Appearance — opacity/scale/pulse возле notch; duration задаёт model. `accessibilityReduceMotion` заменяет pulse на cross-fade. Звук timer остаётся в TimerStore и не дублируется view.

- [ ] **Step 5: Реализовать equalizer modes**

`static`: фиксированные bars, одна короткая transition на track key и expand. `slow`: cadence 0.8 sec только while playing and visible. `fluid`: cadence 0.25 sec only while playing and visible. Использовать `TimelineView(.periodic)` только в ветке, которая реально находится в hierarchy; paused/hidden→no schedule.

- [ ] **Step 6: Перевести ContentView на presentation size**

`vm.bodySize` делегирует `NotchLayoutMetrics.visibleSize(for: presentation.state.mode)`. `idle` рисует существующую collapsed shape; `compact/attention` — новые activity views; `expanded` — существующий header/content. Анимация привязана к presentation mode, не только `isOpen`.

- [ ] **Step 7: Перевести controller active rect/pointer**

Подписаться на presentation state. При closed state применять metrics rect для idle/compact/attention; обновлять `root.activeRect`, `pointer.openRect`, `interactiveRect`, не меняя panel frame. Hover active island вызывает `openFromPointer(overActiveIsland: true)`, idle — false. Generation token предотвращает, чтобы delayed collapse/old attention уменьшил rect нового state.

- [ ] **Step 8: Запустить suites/build и закоммитить**

Run: `swift test --filter 'NotchPresentation|NotchLayout|MediaAnimation'`

Expected: PASS.

Run: `swift build`

Expected: PASS.

```bash
git add Sources/Cyclop/UI/Activities Sources/Cyclop/UI/NotchContentView.swift Sources/Cyclop/Model Sources/Cyclop/Notch Tests/CyclopTests
git commit -m "feat: present adaptive notch activities"
```

### Task 6: Добавить секцию настроек активностей

**Files:**
- Create: `Sources/Cyclop/UI/Settings/ActivitySettingsSection.swift`
- Modify: `Sources/Cyclop/UI/SettingsPane.swift:9-171`
- Create: `Tests/CyclopTests/Activities/UI/ActivitySettingsPresentationTests.swift`

- [ ] **Step 1: Вынести reusable settings rows**

`SettingsPane.section/toggleRow/actionRow` сейчас private и уже нужны второй секции. Вынести presentation-only компоненты в `Sources/Cyclop/UI/Settings/SettingsComponents.swift`, не менять внешний вид существующих General/Screenshots/Snippets.

- [ ] **Step 2: Реализовать ActivitySettingsSection**

Controls:

- общий toggle `Активности возле чёлки`;
- toggles `Музыка`, `Встречи`, `Таймеры`, `Загрузки`;
- meeting picker 5/10/15/30 минут;
- timer sound toggle;
- media animation segmented picker `Статично` / `Медленно` / `Плавно`;
- downloads folder row + `Выбрать…`.

Visibility toggles не вызывают stop у stores; меняют только compact/attention filter.

- [ ] **Step 3: Реализовать folder picker**

`NSOpenPanel`: canChooseDirectories=true, canChooseFiles=false, allowsMultipleSelection=false. На cancel настройка не меняется. Выбранная папка проверяется на existing directory/readability/writability; ошибка отображается inline `Папка недоступна для записи`. После success own manager и watcher переключаются на одну URL.

- [ ] **Step 4: Добавить presentation tests**

Проверить localized mode labels, lead options и то, что invalid stored lead restored to 15. Folder display сокращает home prefix до `~/`, но accessibility value содержит полный path.

- [ ] **Step 5: Запустить tests/build и закоммитить**

Run: `swift test --filter 'ActivitySettings'`

Expected: PASS.

```bash
git add Sources/Cyclop/UI/Settings Sources/Cyclop/UI/SettingsPane.swift Tests/CyclopTests/Activities/UI
git commit -m "feat: configure activity center"
```

### Task 7: Расширить PrivacyMode и локализацию

**Files:**
- Modify: `Sources/Cyclop/Model/PrivacyMode.swift:22-91`
- Modify: `Resources/en.lproj/Localizable.strings`
- Modify: `Resources/ru.lproj/Localizable.strings`
- Create: `Tests/CyclopTests/Model/PrivacyModeMigrationTests.swift`
- Create: `Tests/CyclopTests/App/ActivityLocalizationTests.swift`

- [ ] **Step 1: Написать migration tests**

```swift
@MainActor
func testPreviouslyCoveredAllSectionsAlsoCoversActivitiesAfterUpgrade() {
    defaults.set(["clipboard", "snippets", "calendar", "notes"], forKey: PrivacyMode.key)
    let privacy = PrivacyMode(defaults: defaults)
    XCTAssertTrue(privacy.covers(.activities))
    XCTAssertTrue(privacy.coversAll)
}

@MainActor
func testPartialSelectionDoesNotEnableActivitiesDuringMigration() {
    defaults.set(["clipboard", "calendar"], forKey: PrivacyMode.key)
    XCTAssertFalse(PrivacyMode(defaults: defaults).covers(.activities))
}
```

- [ ] **Step 2: Добавить activities section и schema marker**

`PrivacyMode.Section.activities` title `Activities`. В `init(defaults:)`: если schema version отсутствует и stored set равен полному набору старых sections, добавить activities; partial set оставить как есть; legacy bool=true покрывает все current cases. Сохранить `privacyMode.schemaVersion = 2` после migration.

- [ ] **Step 3: Добавить все новые localization keys**

Минимальный перечень: Activities, Hidden Activity, No Activities Yet, New Timer, Download from Link, HTTPS Link, Create, Cancel, Pause, Resume, Retry, Restart, Open, Show in Finder, Dismiss, Join, Timer, Download, Meeting, Completed, Failed, Queued, Paused, Meeting Lead Time, Timer Sound, Music Animation, Static, Slow, Fluid, Downloads Folder, Choose…, Activity Center, и все errors из subsystem plans.

- [ ] **Step 4: Написать localization completeness test**

Test читает обе `.strings` таблицы из repository path и проверяет exact key set + отсутствие пустых values. Русские значения отдельно сверяются для ключей ошибок и главных действий, чтобы accidental English fallback не прошёл.

- [ ] **Step 5: Запустить tests и закоммитить**

Run: `swift test --filter 'PrivacyModeMigration|ActivityLocalization'`

Expected: PASS.

```bash
git add Sources/Cyclop/Model/PrivacyMode.swift Resources Tests/CyclopTests/Model Tests/CyclopTests/App
git commit -m "feat: localize and protect activity content"
```

### Task 8: Собрать live services и lifecycle

**Files:**
- Modify: `Sources/Cyclop/Model/NotchViewModel.swift:80-214`
- Modify: `Sources/Cyclop/Notch/NotchController.swift:88-254`
- Modify: `Sources/Cyclop/App/AppDelegate.swift:4-31`
- Create: `Tests/CyclopTests/Activities/ActivityCompositionTests.swift`

- [ ] **Step 1: Написать composition ownership test**

Test composition factory проверяет unique source IDs `[media, meetings, timers, downloads.own, downloads.external]`, maxConcurrent=3 и один shared downloads folder setting. Ни один source не создаётся дважды при controller rebuild.

- [ ] **Step 2: Вынести composition factory**

```swift
@MainActor
struct ActivityComposition {
    let settings: ActivitySettings
    let timerStore: TimerStore
    let downloadManager: DownloadManager
    let folderWatcher: DownloadsFolderWatcher
    let downloadTransport: URLSessionDownloadTransport
    let coordinator: ActivityCoordinator
    let presentation: NotchPresentationModel
    let center: ActivityCenterViewModel

    static func live(media: MediaController, calendar: CalendarStore, privacy: PrivacyMode) -> Self
    func start() throws
    func stop()
}
```

Создать composition один раз внутри `NotchController`, а при screen rebuild передавать его новому `NotchViewModel`; screen change не должен повторно load/start background tasks или проигрывать completion sound.

- [ ] **Step 3: Подключить start/stop**

`NotchViewModel.start`: existing media/shelf/calendar/clipboard + composition start в определённом порядке timer→transport/download manager→watcher→sources. `stop`: flush timer/download metadata, stop watcher, cancel UI schedules; background session transfers не отменять при ordinary panel rebuild.

- [ ] **Step 4: Подключить background URLSession events**

```swift
func application(
    _ application: NSApplication,
    handleEventsForBackgroundURLSession identifier: String,
    completionHandler: @escaping () -> Void
) {
    guard identifier == URLSessionDownloadTransport.backgroundIdentifier else {
        completionHandler()
        return
    }
    controller?.handleBackgroundDownloadEvents(completionHandler)
}
```

Если callback приходит до install, AppDelegate временно хранит handler и передаёт его сразу после controller creation. Вызывать handler ровно один раз из `urlSessionDidFinishEvents`.

- [ ] **Step 5: Подключить sleep/wake**

На sleep закрыть UI/tickers как сейчас, но не отменять background downloads. На wake вызвать timer reconcile, meeting boundary reconcile, refresh Now Playing, reattach folder watcher if directory replaced. Attention ledger предотвращает replay; timer sound flag решает one-shot exception.

- [ ] **Step 6: Обработать startup failures**

Повреждённый timers/downloads JSON не завершает app: соответствующий source health становится unavailable с русской ошибкой и recovery action `Сбросить данные…`; destructive reset выполняется только после явного подтверждения пользователя и не входит в automatic start.

- [ ] **Step 7: Запустить integration tests/build и закоммитить**

Run: `swift test --filter ActivityCompositionTests`

Expected: PASS.

Run: `swift test`

Expected: PASS.

Run: `swift build`

Expected: PASS.

```bash
git add Sources/Cyclop Tests/CyclopTests
git commit -m "feat: integrate activity system lifecycle"
```

## UI integration checkpoint

Run: `swift test`

Expected: PASS.

Manual smoke before declaring success:

1. Idle appearance matches current Cyclop.
2. Playing media creates compact island without opening expanded pane.
3. Hover active island opens Activities; close + idle hover returns last manually selected tab.
4. URL field does not steal keyboard on hover, but accepts typing after click.
5. File drop still goes to Shelf; HTTP URL drop goes to Activities/downloads.
6. Privacy masks activity titles in compact, attention and expanded views, but keeps countdown/progress.
7. Reduce Motion removes pulse/equalizer motion.
8. `Scripts/version` and release notes remain untouched.
