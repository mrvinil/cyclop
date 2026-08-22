# План реализации автоматической жанровой анимации музыки

> **Для агентных исполнителей:** ОБЯЗАТЕЛЬНЫЙ ПОДНАВЫК: использовать `superpowers:subagent-driven-development` (рекомендуется) или `superpowers:executing-plans` для выполнения этого плана по задачам. Шаги отмечены чекбоксами.

**Цель:** Добавить в Cyclop режим «Автоматически по жанру», который для треков нативной Яндекс Музыки выбирает отдельный стиль анимации по жанру альбома из публичного каталога.

**Архитектура:** Пользовательская настройка `MediaAnimationMode` отделяется от фактического `MediaAnimationStyle`. `GenreAnimationResolver` наблюдает уже существующий `MediaController`, допускает lookup только для `Yandex Music` / `Яндекс Музыка`, кэширует результат в памяти и публикует стиль для UI. Сетевой клиент скрыт за протоколом; `MediaActivitySource` и MediaRemote helper не получают сетевой ответственности.

**Технологии:** Swift 5 language mode, SwiftUI, Combine, URLSession, XCTest, macOS 15+.

**Спецификация:** `docs/superpowers/specs/2026-08-22-genre-driven-music-animation-design.md`

## Глобальные ограничения

- Все новые пользовательские подписи, статусы и ошибки — на русском языке.
- Запросы выполняются только для отображаемого источника `Yandex Music` или `Яндекс Музыка`; Apple Music, Spotify, браузеры и неизвестный источник не отправляют метаданные в каталог.
- Никаких токенов, cookies, Universal Access, scraping, закрытых API или сохранения истории прослушивания на диск.
- Сомнительное совпадение, ошибка сети, HTTP-ошибка, пустой жанр и неизвестный тег всегда дают `universal` без пользовательской ошибки.
- Все сетевые тесты используют fake transport; unit-тесты не выходят в интернет.
- При паузе эквалайзер перестаёт двигаться, бегущая строка продолжает работать; `Reduce Motion` отключает движение.
- Не изменять контракт `MediaActivitySource`, MediaRemote helper, команды плеера или существующие ручные стили `rockRiff` и `rockWall`.

---

### Задача 1: Разделить режим настройки и стиль анимации

**Файлы:**

- Создать: `Sources/Cyclop/Activities/Media/GenreAnimation.swift`
- Изменить: `Sources/Cyclop/Activities/ActivitySettings.swift`
- Изменить: `Sources/Cyclop/UI/Settings/ActivitySettingsSection.swift`
- Изменить: `Tests/CyclopTests/Activities/ActivitySettingsTests.swift`
- Создать: `Tests/CyclopTests/Activities/Media/GenreAnimationCatalogTests.swift`
- Изменить: `Tests/CyclopTests/Activities/UI/ActivitySettingsPresentationTests.swift`

**Интерфейсы:**

- Производит `MediaAnimationStyle`, `GenreAnimationCatalog` и `MediaAnimationMode.resolvedManualStyle`.
- Потребляет сохранённый ключ `activities.mediaAnimationMode` без его переименования.
- Следующая задача использует `GenreAnimationCatalog.style(for:)` и `MediaAnimationStyle.universal`.

- [ ] **Шаг 1: Написать падающие тесты миграции и каталога**

```swift
func testAutomaticModeIsPersistedAndRestored() {
    defaults.set("automatic", forKey: "activities.mediaAnimationMode")
    XCTAssertEqual(ActivitySettings(defaults: defaults).mediaAnimationMode, .automatic)
}

func testGenreCatalogMapsKnownTagsAndFallsBackToUniversal() {
    XCTAssertEqual(GenreAnimationCatalog.style(for: "alternativemetal"), .metal)
    XCTAssertEqual(GenreAnimationCatalog.style(for: "BREAKBEATGENRE"), .breakbeat)
    XCTAssertEqual(GenreAnimationCatalog.style(for: "unknown-tag"), .universal)
}

func testAutomaticModeHasRussianLabel() {
    XCTAssertEqual(ActivitySettingsPresentation.animationLabel(for: .automatic), "Автоматически по жанру")
}
```

- [ ] **Шаг 2: Убедиться, что тесты падают**

Запустить:

```zsh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter 'ActivitySettingsTests|GenreAnimationCatalogTests|ActivitySettingsPresentationTests'
```

Ожидание: ошибка компиляции, так как `.automatic`, `MediaAnimationStyle` и `GenreAnimationCatalog` ещё не объявлены.

- [ ] **Шаг 3: Добавить типы стилей и точную таблицу тегов**

В `GenreAnimation.swift` объявить:

```swift
enum MediaAnimationStyle: String, CaseIterable, Codable {
    case universal, rockRiff, rockWall, punk, metal, alternativeIndie
    case pop, dance, electronic, techno, breakbeat, rap, lofi
    case jazzBlues, classical, folk, cinematic
}

enum GenreAnimationCatalog {
    static func style(for genre: String) -> MediaAnimationStyle {
        switch genre.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "rock", "rusrock": .rockRiff
        case "hardrock", "grunge": .rockWall
        case "punk", "hardcore": .punk
        case "metal", "alternativemetal": .metal
        case "alternative", "indie": .alternativeIndie
        case "pop", "ruspop": .pop
        case "dance", "eurodance", "hyperpopgenre": .dance
        case "electronics", "experimental": .electronic
        case "techno", "house", "trance": .techno
        case "breakbeatgenre", "drumandbass": .breakbeat
        case "rap", "rusrap": .rap
        case "lofi", "ambient", "chill", "relax": .lofi
        case "jazz", "blues": .jazzBlues
        case "classical": .classical
        case "folk", "country", "latin": .folk
        case "soundtrack", "world": .cinematic
        default: .universal
        }
    }
}
```

В `MediaAnimationMode` сохранить существующие `off`, `universal`, `rockRiff`,
`rockWall`, `electronic`, `lofi` и добавить этот полный набор cases:

```swift
case automatic
case punk
case metal
case alternativeIndie
case pop
case dance
case techno
case breakbeat
case rap
case jazzBlues
case classical
case folk
case cinematic
```

Добавить:

```swift
var resolvedManualStyle: MediaAnimationStyle? {
    switch self {
    case .off: return nil
    case .automatic, .universal: return .universal
    case .rockRiff: return .rockRiff
    case .rockWall: return .rockWall
    case .punk: return .punk
    case .metal: return .metal
    case .alternativeIndie: return .alternativeIndie
    case .pop: return .pop
    case .dance: return .dance
    case .electronic: return .electronic
    case .techno: return .techno
    case .breakbeat: return .breakbeat
    case .rap: return .rap
    case .lofi: return .lofi
    case .jazzBlues: return .jazzBlues
    case .classical: return .classical
    case .folk: return .folk
    case .cinematic: return .cinematic
    }
}
```

Сохранить текущие миграции `static → off`, `slow`/`fluid → universal`,
`rock`/`rockHits → rockRiff`. Для каждого нового `rawValue` возвращать
соответствующий case, а неизвестное значение оставлять `universal`.

В `ActivitySettingsPresentation.animationLabel(for:)` добавить русские подписи:
`«Автоматически по жанру»`, `«Панк»`, `«Металл»`, `«Альтернатива / инди»`,
`«Поп»`, `«Танцевальная»`, `«Техно / house / trance»`,
`«Breakbeat / DnB»`, `«Рэп»`, `«Джаз / блюз»`, `«Классика»`,
`«Фолк / country / Latin»`, `«Саундтрек / world»`. Существующие подписи не
менять.

- [ ] **Шаг 4: Запустить целевые тесты**

```zsh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter 'ActivitySettingsTests|GenreAnimationCatalogTests|ActivitySettingsPresentationTests'
```

Ожидание: PASS; тесты проверяют все 17 `MediaAnimationStyle.allCases`, все
legacy values и то, что `automatic` записывается как `"automatic"`.

- [ ] **Шаг 5: Зафиксировать задачу**

```zsh
git add Sources/Cyclop/Activities/Media/GenreAnimation.swift Sources/Cyclop/Activities/ActivitySettings.swift Sources/Cyclop/UI/Settings/ActivitySettingsSection.swift Tests/CyclopTests/Activities/ActivitySettingsTests.swift Tests/CyclopTests/Activities/Media/GenreAnimationCatalogTests.swift Tests/CyclopTests/Activities/UI/ActivitySettingsPresentationTests.swift
git commit -m "feat: add genre animation styles"
```

### Задача 2: Реализовать сопоставление трека и read-only клиент каталога

**Файлы:**

- Создать: `Sources/Cyclop/Activities/Media/YandexMusicGenreClient.swift`
- Создать: `Tests/CyclopTests/Activities/Media/YandexMusicGenreClientTests.swift`

**Интерфейсы:**

- Потребляет `GenreAnimationCatalog` из задачи 1.
- Производит `GenreLookupRequest`, `GenreLookupResult`, `YandexMusicGenreFetching` и `YandexMusicGenreClient`.
- Следующая задача использует `func genre(for request: GenreLookupRequest) async -> GenreLookupResult?`.

- [ ] **Шаг 1: Написать тесты строгого score и декодирования**

```swift
func testExactTitleArtistAndAlbumProducesAcceptedGenre() {
    let request = GenreLookupRequest(title: "Born too Slow", artist: "The Crystal Method", album: "Legion of Boom")
    let candidate = GenreTrackCandidate(
        title: "Born too Slow",
        artistNames: ["The Crystal Method"],
        albumTitle: "Legion of Boom",
        albumGenre: "breakbeatgenre"
    )
    XCTAssertEqual(YandexMusicGenreMatcher.score(request, candidate), 105)
    XCTAssertEqual(YandexMusicGenreMatcher.bestMatch(for: request, candidates: [candidate])?.albumGenre, "breakbeatgenre")
}

func testTitleOnlyMatchIsRejected() {
    let request = GenreLookupRequest(title: "Прощай", artist: "VEIGEL", album: "Прощай")
    let candidate = GenreTrackCandidate(title: "Прощай", artistNames: ["Другой артист"], albumTitle: "Другой альбом", albumGenre: "pop")
    XCTAssertNil(YandexMusicGenreMatcher.bestMatch(for: request, candidates: [candidate]))
}
```

Добавить test transport, возвращающий JSON с `result.tracks.results`, и проверить:

```swift
let result = await client.genre(for: request)
XCTAssertEqual(result?.genreTag, "breakbeatgenre")
XCTAssertEqual(result?.style, .breakbeat)
```

- [ ] **Шаг 2: Убедиться, что тесты падают**

```zsh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter YandexMusicGenreClientTests
```

Ожидание: ошибка компиляции отсутствующих типов поиска.

- [ ] **Шаг 3: Добавить чистый matcher и URLSession-клиент**

Объявить контракты:

```swift
struct GenreLookupRequest: Equatable, Hashable {
    let title: String
    let artist: String
    let album: String
}

struct GenreLookupResult: Equatable {
    let genreTag: String
    let style: MediaAnimationStyle
}

protocol YandexMusicGenreFetching: Sendable {
    func genre(for request: GenreLookupRequest) async -> GenreLookupResult?
}
```

`YandexMusicGenreMatcher.score` нормализует строки регистронезависимо, убирает
диакритические знаки и объединяет пробелы. Он начисляет `65` за точное
название, `30` если хотя бы одно имя из исполнителей совпадает, `10` за точный
альбом. `bestMatch` возвращает только кандидата со счётом `>= 95`.

`YandexMusicGenreClient` строит только GET-запрос:

```swift
URLComponents(string: "https://api.music.yandex.net/search")
```

с query items `type=track`, `page=0`, `text="<artist> <title>"` и заголовком
`User-Agent: CyclopGenreLookup/1.0`. Декодировать только `title`, массив
`artists.name`, первый `albums.title` и первый `albums.genre`. При ошибке
URLSession, не-2xx ответе, ошибке декодирования или отсутствии принятого
кандидата вернуть `nil`. Не использовать `URLSession.shared` напрямую в
тестируемой логике: внедрить async transport с production default
`URLSession.shared.data(for:)`. Объявить `static let live =
YandexMusicGenreClient()` для composition root.

- [ ] **Шаг 4: Запустить тесты клиента**

```zsh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter YandexMusicGenreClientTests
```

Ожидание: PASS; transport фиксирует URL, query items и отсутствие
Authorization/Cookie заголовков.

- [ ] **Шаг 5: Зафиксировать задачу**

```zsh
git add Sources/Cyclop/Activities/Media/YandexMusicGenreClient.swift Tests/CyclopTests/Activities/Media/YandexMusicGenreClientTests.swift
git commit -m "feat: resolve Yandex Music album genres"
```

### Задача 3: Добавить resolver с memory cache и отменой устаревших ответов

**Файлы:**

- Создать: `Sources/Cyclop/Activities/Media/GenreAnimationResolver.swift`
- Создать: `Tests/CyclopTests/Activities/Media/GenreAnimationResolverTests.swift`
- Изменить: `Sources/Cyclop/Activities/ActivityComposition.swift`
- Изменить: `Tests/CyclopTests/Activities/ActivityCompositionTests.swift`

**Интерфейсы:**

- Потребляет `MediaController.mediaStatePublisher`, `ActivitySettings` и `YandexMusicGenreFetching`.
- Производит observable `GenreAnimationPresentation` с `style`, `genreLabel` и `isAutomatic`.
- Следующие UI-задачи получают единственный экземпляр resolver из `ActivityComposition`.

- [ ] **Шаг 1: Написать падающие тесты поведения resolver-а**

```swift
@MainActor
func testYandexTrackUsesResolvedStyleAndMemoryCache() async {
    let client = GenreClientFake(result: .init(genreTag: "punk", style: .punk))
    let resolver = GenreAnimationResolver(mediaStatePublisher: states.eraseToAnyPublisher(), settings: settings, client: client)
    settings.mediaAnimationMode = .automatic

    states.send(mediaState(title: "Песня", artist: "Артист", album: "Альбом", source: "Yandex Music"))
    await Task.yield()
    await Task.yield()
    XCTAssertEqual(resolver.presentation.style, .punk)
    XCTAssertEqual(client.requests.count, 1)

    states.send(mediaState(title: "Песня", artist: "Артист", album: "Альбом", source: "Yandex Music"))
    XCTAssertEqual(client.requests.count, 1)
}

@MainActor
func testNonYandexSourceDoesNotCallClient() async {
    settings.mediaAnimationMode = .automatic
    states.send(mediaState(title: "Song", artist: "Artist", album: "Album", source: "Spotify"))
    await Task.yield()
    XCTAssertEqual(client.requests, [])
    XCTAssertEqual(resolver.presentation.style, .universal)
}
```

Добавить тест с `GenreClientDeferredFake`: отправить трек A, затем B, завершить
ответ A и убедиться, что resolver не меняет стиль B. Отдельно проверить
`nil`/ошибку клиента, отрицательный cache, `Яндекс Музыка`, `nil` source,
переключение на ручной стиль и `off`.

- [ ] **Шаг 2: Убедиться, что тесты падают**

```zsh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter 'GenreAnimationResolverTests|ActivityCompositionTests'
```

Ожидание: ошибка компиляции отсутствующего resolver-а и свойства
`genreAnimation` у композиции.

- [ ] **Шаг 3: Реализовать resolver и подключить его к composition root**

Объявить presentation:

```swift
struct GenreAnimationPresentation: Equatable {
    let style: MediaAnimationStyle?
    let genreLabel: String?
    let isAutomatic: Bool

    static let off = Self(style: nil, genreLabel: nil, isAutomatic: false)
}
```

`GenreAnimationResolver` должен быть `@MainActor final class ...:
ObservableObject`; его `@Published private(set) var presentation` начинается
как manual `universal`. Он подписывается одновременно на состояние музыки и
`settings.$mediaAnimationMode`.

Правила перехода:

```swift
guard settings.mediaAnimationMode == .automatic else {
    presentation = .init(style: settings.mediaAnimationMode.resolvedManualStyle,
                         genreLabel: nil, isAutomatic: false)
    return
}
guard source == "Yandex Music" || source == "Яндекс Музыка",
      !track.title.isEmpty, !track.artist.isEmpty else {
    presentation = .init(style: .universal, genreLabel: nil, isAutomatic: true)
    return
}
```

Перед новым Task увеличивать generation. Task после `await client.genre` обязан
проверить generation, текущий `track.key`, текущий automatic mode и допустимый
source. Положительный cache хранит `GenreLookupResult`, отрицательный —
отдельный enum case `.notFound`, чтобы `nil` не удалял запись из словаря.
Ключ cache — нормализованные title/artist/album, только в оперативной памяти.

В `ActivityComposition` добавить `let genreAnimation: GenreAnimationResolver`,
создать его сразу после `self.media = media` с live client и не включать в
массив `ActivitySource`. В тестовом initializer добавить необязательный
параметр `genreClient: any YandexMusicGenreFetching = YandexMusicGenreClient.live`;
это не меняет клиентов существующих coordinator-тестов.

- [ ] **Шаг 4: Запустить resolver и регрессионные тесты активностей**

```zsh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter 'GenreAnimationResolverTests|ActivityCompositionTests|MediaControllerActivityStateTests'
```

Ожидание: PASS; все источники активности остаются без сетевой зависимости.

- [ ] **Шаг 5: Зафиксировать задачу**

```zsh
git add Sources/Cyclop/Activities/Media/GenreAnimationResolver.swift Sources/Cyclop/Activities/ActivityComposition.swift Tests/CyclopTests/Activities/Media/GenreAnimationResolverTests.swift Tests/CyclopTests/Activities/ActivityCompositionTests.swift
git commit -m "feat: resolve automatic genre animation"
```

### Задача 4: Нарисовать отличимые паттерны всех стилей

**Файлы:**

- Изменить: `Sources/Cyclop/UI/Activities/MediaEqualizerView.swift`
- Изменить: `Tests/CyclopTests/Activities/UI/MediaAnimationPolicyTests.swift`

**Интерфейсы:**

- Потребляет `MediaAnimationStyle` и optional style из `GenreAnimationPresentation`.
- Производит те же четыре визуальные полосы; размеры острова и текст не меняются.

- [ ] **Шаг 1: Написать падающие тесты политики анимации**

```swift
func testEveryStyleUsesDisplayTimelineOnlyDuringActivePlayback() {
    for style in MediaAnimationStyle.allCases {
        XCTAssertTrue(MediaAnimationPolicy(style: style, isPlaying: true, reduceMotion: false).usesDisplayLinkedTimeline)
        XCTAssertFalse(MediaAnimationPolicy(style: style, isPlaying: false, reduceMotion: false).usesDisplayLinkedTimeline)
        XCTAssertFalse(MediaAnimationPolicy(style: style, isPlaying: true, reduceMotion: true).usesDisplayLinkedTimeline)
    }
}

func testNilStyleNeverAllocatesTimeline() {
    XCTAssertFalse(MediaAnimationPolicy(style: nil, isPlaying: true, reduceMotion: false).usesDisplayLinkedTimeline)
}
```

- [ ] **Шаг 2: Убедиться, что тесты падают**

```zsh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter MediaAnimationPolicyTests
```

Ожидание: прежняя политика принимает `MediaAnimationMode`, а не
`MediaAnimationStyle?`.

- [ ] **Шаг 3: Перевести equalizer на фактический стиль**

Заменить вход view на:

```swift
struct MediaEqualizerView: View {
    let style: MediaAnimationStyle
    let isPlaying: Bool
}
```

Внешний слой не создаёт view при `style == nil`. `MediaAnimationPolicy` принимает
`MediaAnimationStyle?`; `usesDisplayLinkedTimeline` требует непустой style,
воспроизведение и выключенный Reduce Motion.

В `height(index:phase:)` оставить существующие формулы `universal`, `rockRiff`,
`rockWall`, `electronic`, `lofi` без изменения. Для новых стилей добавить
отдельные ветви с этими правилами:

```swift
case .punk:       level = pulse(phase, speed: 12.5, offset: offset, sync: 3.0)
case .metal:      level = min(1, 0.32 + pulse(phase, speed: 14.0, offset: offset, sync: 5.0))
case .alternativeIndie: level = normalized(sin(phase * 5.8 + offset) + sin(phase * 9.1 + offset * 0.55) * 0.42)
case .pop:        level = normalized(sin(phase * 3.5 + offset * 0.65) + sin(phase * 6.0 + offset) * 0.20)
case .dance:      level = pulse(phase, speed: 6.8, offset: offset, sync: 1.0)
case .techno:     level = pulse(phase, speed: 7.2, offset: offset * 0.2, sync: 0.0)
case .breakbeat:  level = brokenBeat(phase, offset: offset)
case .rap:        level = pulse(phase, speed: 4.4, offset: offset * 1.4, sync: 0.0)
case .jazzBlues:  level = normalized(sin(phase * 3.1 + offset * 1.35) + sin(phase * 5.3 + offset) * 0.30)
case .classical:  level = normalized(sin(phase * 1.9 + offset * 0.52) + sin(phase * 3.0 + offset) * 0.18)
case .folk:       level = normalized(sin(phase * 3.0 + offset * 0.9) + sin(phase * 4.6 + offset * 0.33) * 0.20)
case .cinematic:  level = normalized(sin(phase * 2.2 + offset * 0.4) + sin(phase * 1.1) * 0.48)
```

Добавить два private pure helper-а:

```swift
private func pulse(_ phase: TimeInterval, speed: Double, offset: Double, sync: Double) -> Double {
    let kick = max(0, sin(phase * speed + sync))
    let bar = (sin(phase * speed * 0.5 + offset) + 1) / 2
    return min(max(kick * 0.72 + bar * 0.28, 0), 1)
}

private func brokenBeat(_ phase: TimeInterval, offset: Double) -> Double {
    let pattern: [Double] = [1, 0.28, 0.72, 0.14, 0.88, 0.38, 0.62]
    let index = Int(floor(phase * 5.6 + offset * 0.35)).quotientAndRemainder(dividingBy: pattern.count).remainder
    let swung = (sin(phase * 12.0 + offset) + 1) / 2
    return min(max(pattern[index] * 0.78 + swung * 0.22, 0), 1)
}
```

Задать следующие точные `minimum`/`amplitude`: `punk` — `6/15`, `metal` —
`9/13`, `alternativeIndie` — `7/12`, `pop` — `7/11`, `dance` — `6/14`,
`techno` — `7/14`, `breakbeat` — `6/15`, `rap` — `8/12`, `jazzBlues` —
`7/10`, `classical` — `6/12`, `folk` — `7/10`, `cinematic` — `8/13`.
Высота не должна выйти за 22 pt. Не использовать случайные числа,
аудиозахват или новые таймеры.

- [ ] **Шаг 4: Запустить тесты политики**

```zsh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter MediaAnimationPolicyTests
```

Ожидание: PASS; static first frame для paused/reduce-motion детерминирован.

- [ ] **Шаг 5: Зафиксировать задачу**

```zsh
git add Sources/Cyclop/UI/Activities/MediaEqualizerView.swift Tests/CyclopTests/Activities/UI/MediaAnimationPolicyTests.swift
git commit -m "feat: animate music styles by genre"
```

### Задача 5: Подключить resolver к компактному острову и вкладке «Музыка»

**Файлы:**

- Изменить: `Sources/Cyclop/Model/NotchViewModel.swift`
- Изменить: `Sources/Cyclop/Notch/NotchController.swift`
- Изменить: `Sources/Cyclop/UI/NotchContentView.swift`
- Изменить: `Sources/Cyclop/UI/Activities/CompactActivityView.swift`
- Изменить: `Sources/Cyclop/UI/MediaPane.swift`
- Создать: `Sources/Cyclop/UI/Activities/CompactMediaPresentation.swift`
- Создать: `Sources/Cyclop/UI/MediaGenrePresentation.swift`
- Изменить: `Tests/CyclopTests/Activities/UI/CompactMediaPresentationTests.swift`
- Изменить: `Tests/CyclopTests/Activities/UI/ActivitySettingsPresentationTests.swift`

**Интерфейсы:**

- Потребляет `ActivityComposition.genreAnimation` из задачи 3.
- Потребляет `GenreAnimationPresentation.style`, `genreLabel`, `isAutomatic`.
- Производит компактный equalizer и вторичный текст только для открытой вкладки музыки.

- [ ] **Шаг 1: Написать падающие тесты presentation-правил**

```swift
func testAutomaticGenreStatusIsVisibleOnlyForAutomaticResolvedGenre() {
    let presentation = GenreAnimationPresentation(style: .breakbeat, genreLabel: "Breakbeat / DnB", isAutomatic: true)
    XCTAssertEqual(MediaGenrePresentation.statusText(for: presentation), "Жанр: Breakbeat / DnB · анимация выбрана автоматически")
    XCTAssertNil(MediaGenrePresentation.statusText(for: .init(style: .punk, genreLabel: nil, isAutomatic: false)))
}

func testCompactPresentationUsesResolvedStyleInsteadOfSettingsMode() {
    let presentation = GenreAnimationPresentation(style: .metal, genreLabel: "Металл", isAutomatic: true)
    XCTAssertEqual(CompactMediaPresentation.equalizerStyle(for: presentation), .metal)
}
```

- [ ] **Шаг 2: Убедиться, что тесты падают**

```zsh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter 'CompactMediaPresentationTests|ActivitySettingsPresentationTests'
```

Ожидание: отсутствуют presentation helpers и resolver не передаётся в UI.

- [ ] **Шаг 3: Пробросить единый observable экземпляр до View**

В `NotchViewModel` добавить:

```swift
let genreAnimation: GenreAnimationResolver?
```

и включить `genreAnimation.objectWillChange` в `forwardedChildren`, чтобы
закрытый остров менялся сразу после ответа lookup, без наведения курсора.

В `NotchController.build()` передать `activityComposition.genreAnimation`.
В `NotchContentView` передать resolver в оба места:

```swift
CompactActivityView(state: state.display, settings: settings, genreAnimation: resolver, card: card)
MediaPane(media: vm.media, genreAnimation: vm.genreAnimation)
```

`CompactActivityView` читает `genreAnimation?.presentation.style` для media
card; при отсутствии resolver использует `settings.mediaAnimationMode.resolvedManualStyle`.
Если style `nil`, `MediaEqualizerView` не создаётся. Это сохраняет `Выкл` и
совместимость тестовых initializer-ов.

В `MediaPane` добавить optional `@ObservedObject` нельзя, поэтому передавать
value `GenreAnimationPresentation?` либо небольшой observable adapter. Выбрать
value: `NotchContentView` вычисляет `let genrePresentation =
vm.genreAnimation?.presentation`, а `MediaPane` принимает `genrePresentation:
GenreAnimationPresentation?`. Под заголовком/подзаголовком показать
`MediaGenrePresentation.statusText(for:)`, только когда `isAutomatic == true`
и есть `genreLabel`. Шрифт: `.system(size: 10.5, weight: .medium)`, цвет
`Theme.tertiary`, одна строка.

- [ ] **Шаг 4: Запустить UI-тесты**

```zsh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter 'CompactMediaPresentationTests|ActivitySettingsPresentationTests|MediaAnimationPolicyTests'
```

Ожидание: PASS; остров не получает дополнительной строки жанра, а вкладка
«Музыка» показывает только русский автоматический статус.

- [ ] **Шаг 5: Зафиксировать задачу**

```zsh
git add Sources/Cyclop/Model/NotchViewModel.swift Sources/Cyclop/Notch/NotchController.swift Sources/Cyclop/UI/NotchContentView.swift Sources/Cyclop/UI/Activities/CompactActivityView.swift Sources/Cyclop/UI/Activities/CompactMediaPresentation.swift Sources/Cyclop/UI/MediaPane.swift Sources/Cyclop/UI/MediaGenrePresentation.swift Tests/CyclopTests/Activities/UI/CompactMediaPresentationTests.swift Tests/CyclopTests/Activities/UI/ActivitySettingsPresentationTests.swift
git commit -m "feat: present automatic music genre"
```

### Задача 6: Обновить документацию и провести финальную проверку

**Файлы:**

- Изменить: `docs/testing/activity-media-manual-matrix.md`
- Изменить: `README.ru.md`

**Интерфейсы:**

- Потребляет реализацию и все тестовые контракты задач 1–5.
- Производит актуальные правила ручной приёмки и понятное описание privacy boundary.

- [ ] **Шаг 1: Дополнить ручную матрицу точными сценариями**

Добавить для строки нативной Яндекс Музыки проверки:

1. Включить «Автоматически по жанру», проиграть два трека с разными жанрами и
   записать отображаемые жанр/стиль во вкладке «Музыка».
2. Быстро переключить A → B → C и убедиться, что результат A/B не меняет стиль C.
3. Отключить сеть до смены трека: остров остаётся на «Универсальный», без
   ошибки и задержки play/pause.
4. Подать трек без принятого жанра: остаётся «Универсальный».
5. Проверить Apple Music, Spotify, Safari и Chrome: их воспроизведение не
   вызывает lookup и сохраняет выбранный ручной стиль.
6. Поставить музыку на паузу: полосы неподвижны, название продолжает бежать.
7. Включить Reduce Motion: полосы не двигаются.

В `README.ru.md` описать, что в automatic mode на публичный каталог Яндекс
Музыки уходят метаданные текущего трека для поиска, но не уходят аккаунт,
cookies или токены. Явно указать, что эта проверка выполняется только для
нативной Яндекс Музыки, не для Apple Music, Spotify и браузеров.

- [ ] **Шаг 2: Запустить полный test suite**

```zsh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

Ожидание: PASS без сетевых запросов; зафиксировать количество тестов из вывода.

- [ ] **Шаг 3: Собрать приложение и проверить подпись**

```zsh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./Scripts/bundle.sh
codesign --verify --deep --strict build/Cyclop.app
```

Ожидание: bundle script завершается успешно, `codesign` не выводит ошибок.

- [ ] **Шаг 4: Выполнить ручную проверку на целевой macOS**

Пройти добавленные строки матрицы в нативной Яндекс Музыке. Зафиксировать
версию Cyclop, версию macOS, версию Яндекс Музыки, два фактических жанра и
результат offline сценария. Не заявлять прохождение не выполненных вручную
строк.

- [ ] **Шаг 5: Зафиксировать документацию**

```zsh
git add docs/testing/activity-media-manual-matrix.md README.ru.md
git commit -m "docs: document automatic genre animation"
```
