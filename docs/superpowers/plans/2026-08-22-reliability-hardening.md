# Укрепление надёжности и безопасности загрузок — план реализации

> **Для агентных исполнителей:** обязательный навык: `superpowers:executing-plans`; шаги отмечаются чекбоксами.

**Цель:** Защитить скачанные файлы и восстановление загрузок, а также устранить потерю текста и зависание телесуфлёра при закрытии.

**Архитектура:** Системный карантин включается в plist бандла. `DownloadManager`, владеющий настройкой папки загрузок, отклоняет журналы с путями вне неё. Жизненный цикл телесуфлёра остаётся в `NotchViewModel` и `NotchController`; `NotchPanel` только сообщает о Escape.

**Технологии:** Swift 6 / SwiftPM, XCTest, AppKit, SwiftUI, shell.

**Спецификация:** `docs/superpowers/specs/2026-08-22-reliability-hardening-design.md`

## Глобальные ограничения

- macOS 15.0+, без новых зависимостей и разрешений.
- Не изменять GitHub Actions.
- Пользовательские сообщения — на русском.
- Каждое поведенческое изменение начинается с падающего XCTest.

---

### Задача 1: Карантин файлов бандла

**Файлы:**
- Изменить: `Scripts/bundle.sh:20-49`
- Тест: `Tests/CyclopTests/Build/BundleScriptTests.swift` (создать)

- [ ] Написать тест, который читает `Scripts/bundle.sh` и требует строку plist `<key>LSFileQuarantineEnabled</key><true/>`.
- [ ] Запустить `swift test --filter BundleScriptTests`; ожидается падение из-за отсутствующего ключа.
- [ ] Добавить ключ рядом с `LSUIElement`.
- [ ] Повторить тест; ожидается успех.
- [ ] Собрать бандл и проверить `/usr/libexec/PlistBuddy -c 'Print LSFileQuarantineEnabled' build/Cyclop.app/Contents/Info.plist`.

### Задача 2: Ограничение пути восстановленной загрузки

**Файлы:**
- Изменить: `Sources/Cyclop/Activities/Downloads/DownloadManager.swift:704-754`
- Тест: `Tests/CyclopTests/Activities/Downloads/DownloadManagerTests.swift`

- [ ] Написать тест с staged-файлом и журналом, указывающим вне `settings.downloadsFolder`; после `start()` внешний путь не существует, staged-файл не перемещён, health — недоступен.
- [ ] Запустить точный тест; ожидается падение: менеджер создаёт внешний каталог/перемещает файл.
- [ ] Ввести приватный метод `isAllowedDestination(_:) -> Bool`, который сравнивает `resolvingSymlinksInPath().standardizedFileURL.path` с выбранной папкой и принимает только путь с префиксом `folder + "/"`.
- [ ] Перед любым `createDirectory`, `moveItem` и обработкой существующего файла в `completeDurableFinalization` отклонять неподходящий путь, выставляя `finalizationRecoveryFailureMessage`.
- [ ] Добавить позитивный тест: путь в выбранной папке продолжает завершаться.
- [ ] Запустить фильтр `DownloadManagerTests`; ожидается успех.

### Задача 3: Надёжное завершение телесуфлёра

**Файлы:**
- Изменить: `Sources/Cyclop/Services/TeleprompterStore.swift`
- Изменить: `Sources/Cyclop/Model/NotchViewModel.swift:277-283`
- Тест: `Tests/CyclopTests/Notch/TeleprompterLifecycleTests.swift` (создать)

- [ ] Сделать сохранение телесуфлёра тестируемым через внедряемую операцию записи или счётчик flush в тестовом экземпляре.
- [ ] Написать тест: `stop()` вызывает flush ровно один раз.
- [ ] Запустить тест; ожидается падение, потому что `stop()` сохраняет только заметки.
- [ ] Вызвать `teleprompter.flush()` в `NotchViewModel.stop()`.
- [ ] Повторить тест; ожидается успех.

### Задача 4: Escape и клик вне работающего телесуфлёра

**Файлы:**
- Изменить: `Sources/Cyclop/Notch/NotchPanel.swift`
- Изменить: `Sources/Cyclop/Notch/NotchController.swift:214-225,315-353`
- Тест: `Tests/CyclopTests/Notch/TeleprompterLifecycleTests.swift`

- [ ] Написать unit-тест для извлечённого действия закрытия: при `holdsOpen == true` оно вызывает `teleprompter.suspend()` и `setOpen(false)`; при другой вкладке ничего не делает.
- [ ] Запустить тест; ожидается падение, так как действия нет.
- [ ] Добавить `onEscape` в `NotchPanel.sendEvent`; для `keyCode == 53` вызывать callback до `super`.
- [ ] В `NotchController` использовать одно приватное действие для Escape и ухода указателя: при `holdsOpen` остановить телесуфлёр, затем закрыть панель. Не перехватывать клик вне активного прямоугольника.
- [ ] Повторить unit-тесты и существующие notch-тесты; ожидается успех.

### Задача 5: Полная проверка и фиксация

**Файлы:**
- Изменить: только перечисленные выше файлы и тесты.

- [ ] Запустить полный `swift test` с `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.
- [ ] Запустить `./Scripts/bundle.sh` и проверить подпись `codesign --verify --strict build/Cyclop.app`.
- [ ] Проверить `git diff --check` и `git status --short`.
- [ ] Закоммитить с сообщением `fix: harden downloads and teleprompter lifecycle`.
