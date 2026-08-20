# Task 1 — ActivityCenterViewModel

## Статус

`DONE_WITH_CONCERNS`

Реализация зафиксирована коммитом `d4661120623880956de26adf0d802d38c5d8d5c0` (`feat: add activity center view model`).

## Scope

- Добавлены `ActivityCenterViewModel`, presentation-модели и единый
  `ActivityCenterPresentationMapper` для expanded и будущих compact/attention UI.
- Введены узкие protocol seams для coordinator, timers и downloads; raw
  `ActivitySnapshot` не хранится в состоянии view model.
- Карточки получают детерминированный порядок, маскирование только title/subtitle,
  progress/actions/countdown остаются доступны. Privacy key содержит длину UTF-8
  source и полный source+local, поэтому не коллидирует при неоднозначной конкатенации.
- `reveal(ActivityID)` выставляет только scroll/focus target; Finder reveal идёт
  только через `perform(.reveal, on:)`.
- `setVisible` и `setCompactTimerVisible` объединяются для
  `TimerStore.setCountdownVisible`; countdown пересобирается только на
  `countdownRevision` через `TimerStore.remaining(for:)`.
- При hidden→visible и при новых terminal downloads в visible pane вызывается
  `markViewed`; completed timers не отмечаются. Карточки остаются в центре.
- Добавлены русский/английский ключи placeholder и минимальный
  `PrivacyMode.Section.activities`.
- Diagnostics строятся отдельно от карточек и не вытесняют их.

## RED → GREEN

1. RED: `swift test --filter ActivityCenterViewModelTests` — отсутствовали
   `ActivityCenterViewModel`, protocol seams и `.activities`.
2. RED: после первого шага compiler выявил actor-isolation mapper; причина
   устранена изоляцией mapper на MainActor.
3. GREEN focused: `swift test --filter ActivityCenterViewModelTests` — 7/7.
4. Регрессионный checkpoint:
   `swift test --filter 'ActivityCoordinatorTests|TimerStoreTests|TimerCountdownTests|DownloadManagerTests|PrivacyMode'` — 138/138.
5. Build: `swift build` — успешно.
6. Full suite на неизменяемом commit `d466112…`: `swift test` — 472/473.

Все Swift-команды выполнены через Xcode toolchain с изолированными cache paths:
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`,
`CLANG_MODULE_CACHE_PATH=/private/tmp/cyclop-clang-module-cache`,
`SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/cyclop-swiftpm-module-cache`.

## Concerns

1. Full suite воспроизводимо падает вне scope Task 1:
   `URLSessionDownloadTransportTests.testHTTP200KnownLengthHandsTemporaryFileToMainActorSynchronously` ожидает suggested filename `known`, но текущий Foundation/Xcode передаёт `known.txt`. Файлы transport и его tests в этом task не менялись; isolated repro даёт ту же ошибку. Не исправлялось, чтобы не менять несвязанный контракт.
2. `.activities` добавлена минимально, потому что без section невозможно masking Task 1. Миграция сохранённых old-full наборов и `PrivacyMode.init(defaults:)` намеренно оставлены Task 7 согласно ledger ruling.
3. Корневые `.lproj` tables не входят в SwiftPM test bundle, поэтому тест placeholder сверяет `localized("Hidden Activity")`; русское отображение задано в `Resources/ru.lproj/Localizable.strings`.
