# Удаление собственного загрузчика — план реализации

> **Для агентных исполнителей:** обязательный навык: `superpowers:executing-plans`; шаги отмечаются чекбоксами.

**Цель:** Оставить в Cyclop только внешние завершённые загрузки из наблюдаемой папки.

**Архитектура:** `ActivityComposition` создаёт только watcher и внешний источник. Одноразовый `RetiredOwnDownloadCleanup` отменяет прежние фоновые задачи и удаляет служебные данные до запуска watcher. URL-drop и композер исчезают из UI.

**Технологии:** Swift 6, XCTest, Foundation URLSession.

**Спецификация:** `docs/superpowers/specs/2026-08-22-remove-own-downloader-design.md`

## Глобальные ограничения

- macOS 15+, без CI, разрешений и зависимостей.
- Пользовательские файлы загрузок не удалять и не перемещать.
- Удалить весь неиспользуемый код собственной очереди и её тесты.

---

### Задача 1: Одноразовая миграция

**Файлы:**
- Создать: `Sources/Cyclop/Activities/Downloads/RetiredOwnDownloadCleanup.swift`
- Тест: `Tests/CyclopTests/Activities/Downloads/RetiredOwnDownloadCleanupTests.swift`

- [ ] Написать тест: `runIfNeeded()` отменяет старые задачи, удаляет только `downloads.json` и `DownloadFinalizations`, ставит флаг миграции и при втором запуске не повторяет действия.
- [ ] Запустить тест; ожидается ошибка отсутствующего типа.
- [ ] Реализовать `RetiredOwnDownloadCleanup` с инъекцией отмены задач, `FileManager` и `UserDefaults`.
- [ ] Повторить тест; ожидается успех.

### Задача 2: Оставить только внешнюю активность

**Файлы:**
- Изменить: `Sources/Cyclop/Activities/ActivityComposition.swift`, `DownloadsFolderWatcher.swift`, `DownloadActivitySources.swift`, `ActivityCenterViewModel.swift`, `ActivityCenterPane.swift`
- Тест: `Tests/CyclopTests/Activities/ActivityCompositionTests.swift`, `ActivityCenterViewModelTests.swift`

- [ ] Написать тест состава: `sourceIDs` содержит `downloads.external`, но не `downloads.own`; центр не принимает URL загрузки.
- [ ] Запустить тест; ожидается падение.
- [ ] Удалить `DownloadManager` из composition, зависимость watcher от `ownFileMovePublisher`, собственный источник и URL-композер API.
- [ ] Сохранить действия внешней карточки и очистку её истории.
- [ ] Повторить тесты ActivityComposition и ActivityCenter; ожидается успех.

### Задача 3: Убрать URL-drop и неиспользуемые модули

**Файлы:**
- Изменить: `NotchDropPayload.swift`, `NotchViewModel.swift`, `NotchController.swift` и их тесты.
- Удалить: `DownloadComposer.swift`, собственную очередь/transport/persistence/finalization/request/naming/record validator и соответствующие тесты.

- [ ] Написать тест: URL в pasteboard больше не образует payload, файл по-прежнему образует `.files`.
- [ ] Запустить тест; ожидается падение.
- [ ] Удалить URL-путь из payload и UI; удалить перечисленные файлы через `git rm` только после подтверждения отсутствия импортов `rg`.
- [ ] Повторить notch и загрузочные тесты; ожидается успех.

### Задача 4: Проверка

- [ ] Запустить полный `swift test` и `./Scripts/bundle.sh`.
- [ ] Проверить `git diff --check`, статус и отсутствие `downloads.own`, `DownloadManager`, `DownloadComposer`, `URLSessionDownloadTransport` через `rg`.
- [ ] Закоммитить `refactor: remove own URL downloader` и отправить `main` в fork.
