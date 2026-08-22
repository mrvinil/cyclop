# Task 3 — resolver жанровой анимации

## Изменения

- Добавлен `@MainActor` `GenreAnimationResolver`, публикующий `GenreAnimationPresentation`.
- Resolver наблюдает `MediaController.mediaStatePublisher` и настройку анимации, поддерживает `automatic`, ручные стили и `off`.
- Lookup разрешён только для точных имён источника `Yandex Music` и `Яндекс Музыка`.
- Добавлен memory cache для найденного жанра и отдельная отрицательная запись `notFound` для `nil`-результата.
- Устаревшие запросы отменяются; ответ дополнительно защищён generation token, ключом трека, режимом и source gate.
- `ActivityComposition` создаёт единственный resolver после `media`, передаёт live-клиент по умолчанию и не добавляет resolver в массив `ActivitySource`.

## Файлы

- `Sources/Cyclop/Activities/Media/GenreAnimationResolver.swift` — новый resolver и presentation.
- `Sources/Cyclop/Activities/ActivityComposition.swift` — composition root и test injection `genreClient`.
- `Tests/CyclopTests/Activities/Media/GenreAnimationResolverTests.swift` — cache, source gate, русский source, отрицательный cache, stale answer, ручной режим и off.
- `Tests/CyclopTests/Activities/ActivityCompositionTests.swift` — resolver доступен из composition и не влияет на source IDs.

## TDD evidence

- RED: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --scratch-path /private/tmp/cyclop-genre-task3-build --filter 'GenreAnimationResolverTests|ActivityCompositionTests'` завершился ожидаемыми compile errors: отсутствовали `GenreAnimationResolver` и `ActivityComposition.genreAnimation`.
- GREEN: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --scratch-path /private/tmp/cyclop-genre-task3-build --filter 'GenreAnimationResolverTests|ActivityCompositionTests|MediaControllerActivityStateTests'` — 38 тестов, 0 failures.
- Full: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --scratch-path /private/tmp/cyclop-genre-task3-build` — 342 теста, 0 failures.

## Concerns

- Нет блокеров. Протокол lookup-клиента уже нормализует транспортные ошибки к `nil`; resolver кэширует такой исход как отрицательный и оставляет универсальный стиль.
