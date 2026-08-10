# Roadmap реализации полноценной системы активностей Cyclop

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to execute this roadmap in a dedicated implementation session, loading each linked plan before its phase.

**Goal:** Реализовать утверждённую систему активностей полностью в fork, проверить её на реальном Mac и только затем предложить upstream maintainer.

## Порядок исполнения

1. `2026-08-10-activity-verification-and-pr.md`, Tasks 0–1 — fork и совместимый toolchain до production-кода.
2. `2026-08-10-activity-foundation.md` — test target, domain model, ranking, attention, coordinator, presentation и layout metrics.
3. `2026-08-10-activity-timers.md` — собственные таймеры и one-shot completion sound.
4. `2026-08-10-activity-downloads.md` — own background downloader и external folder watcher.
5. `2026-08-10-activity-media-meetings.md` — адаптеры существующих MediaController/CalendarStore.
6. `2026-08-10-activity-ui-integration.md` — вкладка, compact/attention island, adaptive depth, settings/privacy/lifecycle.
7. `2026-08-10-activity-verification-and-pr.md`, Tasks 2–8 — CI, failure injection, manual matrix, energy, docs, review и PR.

Каждая фаза начинается только после checkpoint предыдущей. Если upstream/main меняется во время реализации, merge выполняется после subsystem checkpoint, а не посреди падающего TDD цикла.

В текущем Codex sandbox все `swift build/test` команды выполняются с `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`, module caches в `/private/tmp` и `--disable-sandbox`; baseline v0.6.4 в такой конфигурации уже PASS. Это устраняет mismatch активных Command Line Tools без глобального системного переключения.

## Ключевые контрольные точки

- **F0 — Fork ready:** origin=`mrvinil/cyclop`, upstream push disabled, baseline build PASS.
- **F1 — Foundation:** tests ядра PASS, видимое поведение v0.6.4 не изменилось.
- **F2 — Services:** timer/download/media/meeting suites PASS независимо от UI.
- **F3 — End-to-end:** four sources видны во вкладке и compact/attention states.
- **F4 — Acceptance:** full tests, bundle, physical/synthetic/manual/energy matrices PASS.
- **F5 — Upstream-ready:** review закрыт, fork CI green, maintainer получил demo и выбирает форму PR.

## Принятые продуктовые решения

- Одно приоритетное activity + до трёх indicators (`2 + N` при 4+).
- Adaptive depth: physical wings и synthetic capsule.
- Отдельная вкладка «Активности» на правом rail.
- Собственные параллельные таймеры; presets 5/10/25/45/60; custom h/m/s.
- Hybrid downloads: explicit HTTP(S) downloader + completion-only watcher выбранной папки; максимум 3 own transfers.
- Meeting threshold 5/10/15/30, default 15.
- Paused media остаётся 15 секунд.
- Apple Music, Spotify, browsers и Яндекс Музыка через system Now Playing; provider-specific scraping не добавляется.
- Media animation выбирается static/slow/fluid; default slow; Reduce Motion имеет приоритет.
- Completion feedback возле чёлки; timer sound настраивается; notification permission не запрашивается.
- Все sources включены по умолчанию; visibility settings не останавливают tasks.
- Activity privacy маскирует тексты, но не countdown/progress.

## Основные риски и mitigation

| Риск | Решение в плане |
|---|---|
| Background URLSession recovery | taskDescription mapping, persisted metadata, task-lost state, delegate integration tests |
| Ложные external completions | baseline, temp suffix filter, two stable scans, own suppression set |
| Повторные события после sleep/rebuild | stable AttentionEvent ID, 24h ledger, generation tokens |
| Пропущенные/повторные timer sounds | absolute deadline, persisted sound flag, recovery tests |
| Энергопотребление | event-driven sources, one scheduler, visible-only 1Hz/equalizer, Instruments report |
| Keyboard/hover regression | supportsKeyboard отдельно от autoRequestsKeyboard, tab routing tests |
| Click interception у synthetic notch | state-specific active rect, physical/synthetic manual matrix |
| Privacy migration | schema-v2 test для старого `All`, masking во всех three presentations |
| Большой upstream PR | полный demo branch в fork, maintainer выбирает один PR или серию |

## Оценка объёма

Это крупная feature, а не локальная доработка: ориентир **6–10 недель работы одного опытного macOS-разработчика** с доступом к реальному MacBook с чёлкой и дополнительному synthetic-display сценарию. Из них примерно 35–45% — downloader/recovery и системная интеграция, 25–30% — UI/presentation, остальное — таймеры, adapters, tests, manual/energy QA и upstream polish.

План намеренно не включает release/version work: после принятия PR версию выбирает maintainer.
