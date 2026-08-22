import Foundation

enum MediaAnimationStyle: String, CaseIterable, Codable {
    case universal, rockRiff, rockWall, punk, metal, alternativeIndie
    case pop, dance, electronic, techno, breakbeat, rap, lofi
    case jazzBlues, classical, folk, cinematic
}

/// Статический снимок публичной таксономии Яндекс Музыки от 2026-08-22.
///
/// Список не загружается во время работы приложения: API поиска по-прежнему
/// возвращает только тег найденного альбома, а этот каталог локально превращает
/// его в стиль и человеческую подпись.
enum GenreAnimationCatalog {
    static var knownYandexGenreCount: Int { yandexEntries.count }

    static func style(for genre: String) -> MediaAnimationStyle {
        entry(for: genre)?.style ?? .universal
    }

    static func label(for genre: String) -> String? {
        entry(for: genre)?.label
    }

    private static func entry(for genre: String) -> Entry? {
        let normalized = genre
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return yandexEntries[normalized] ?? legacyEntries[normalized]
    }

    private static let yandexEntries = entries(from: """
pop|pop|Поп
ruspop|pop|Русская поп-музыка
disco|pop|Диско
kpop|pop|K-Pop
turkishpop|pop|Турецкая поп-музыка
uzbekpop|pop|Узбекская поп-музыка
japanesepop|pop|J-Pop
israelipop|pop|Израильская поп-музыка
azerbaijanpop|pop|Азербайджанская поп-музыка
hyperpopgenre|pop|Гиперпоп
mizrahi|pop|Мизрахи
arabicpop|pop|Арабский поп
egyptianpop|pop|Египетский поп
khaleejipop|pop|Халиджи
qazaqpop|pop|Q-Pop
levantpop|pop|Левантийский поп
iraqipop|pop|Иракский поп
moroccanpop|pop|Марокканский поп
punjabipopgenre|pop|Панджаби поп
allrock|rockRiff|Рок
rusrock|rockRiff|Русский рок
rnr|rockRiff|Рок-н-ролл
prog|rockRiff|Прогрессивный рок
postrock|rockRiff|Построк
newwave|alternativeIndie|Новая волна
ukrrock|rockRiff|Украинский рок
folkrock|rockRiff|Фолк-рок
stonerrock|rockWall|Стоунер-рок
hardrock|rockWall|Хард-рок
turkishrock|rockRiff|Турецкий рок
rock|rockRiff|Иностранный рок
israelirock|rockRiff|Израильский рок
indie|alternativeIndie|Инди
local-indie|alternativeIndie|Местное инди
metal|metal|Метал
progmetal|metal|Прогрессив
epicmetal|metal|Эпический
folkmetal|metal|Фолк
gothicmetal|metal|Готический
industrial|metal|Индастриал
sludgemetal|metal|Сладж
postmetal|metal|Постметал
numetal|metal|Ню-метал
metalcoregenre|metal|Металкор
classicmetal|metal|Хэви-метал
thrashmetal|metal|Трэш-метал
deathmetal|metal|Дэт-метал
blackmetal|metal|Блэк-метал
doommetal|metal|Дум-метал
alternativemetal|metal|Альтернативный метал
alternative|alternativeIndie|Альтернатива
posthardcore|punk|Постхардкор
hardcore|punk|Хардкор
turkishalternative|alternativeIndie|Турецкая альтернативная музыка
dance|dance|Танцевальная
phonkgenre|rap|Фонк
edmgenre|dance|EDM
electronics|electronic|Электроника
techno|techno|Техно
house|techno|Хаус
trance|techno|Транс
breakbeatgenre|breakbeat|Брейкбит
bassgenre|breakbeat|Бейс
dnb|breakbeat|Драм-н-бэйс
dubstep|breakbeat|Дабстеп
triphopgenre|lofi|Трип-хоп
ukgaragegenre|breakbeat|UK-гэридж
idmgenre|electronic|IDM
ambientgenre|lofi|Эмбиент
newage|lofi|Нью-эйдж
lounge|lofi|Лаундж
experimental|electronic|Экспериментальная
rap|rap|Рэп и хип-хоп
rusrap|rap|Русский рэп
foreignrap|rap|Иностранный рэп
turkishrap|rap|Турецкий рэп и хип-хоп
israelirap|rap|Израильский рэп и хип-хоп
arabicrap|rap|Арабский рэп и хип-хоп
kazakhrap|rap|Рэп на казахском
uzbekrap|rap|Рэп на узбекском
egyptrap|rap|Египетский рэп и хип-хоп
khaleejirap|rap|Халиджи рэп и хип-хоп
levantrap|rap|Рэп и хип-хоп Леванта
moroccanrap|rap|Марокканский рэп и хип-хоп
urduhiphop|rap|Урду хип-хоп/трэп
rnb|pop|R&B
soul|jazzBlues|Соул
funk|pop|Фанк
jazz|jazzBlues|Джаз
tradjazz|jazzBlues|Традиционный джаз
conjazz|jazzBlues|Современный джаз
bebopgenre|jazzBlues|Бибоп
vocaljazz|jazzBlues|Вокальный джаз
smoothjazz|jazzBlues|Смус-джаз
bigbands|jazzBlues|Биг бэнды
bestofjazz|jazzBlues|Шедевры джаза
blues|jazzBlues|Блюз
reggae|folk|Регги
reggaeton|dance|Реггетон
dub|electronic|Даб
ska|punk|Ска
punk|punk|Панк
postpunk|alternativeIndie|Постпанк
folk|folk|Музыка мира
rusfolk|folk|Русская
tatar|folk|Татарская
celtic|folk|Кельтская
balkan|folk|Балканская
eurofolk|folk|Европейская
jewish|folk|Еврейская
eastern|folk|Восточная
african|folk|Африканская
latinfolk|folk|Латиноамериканская
amerfolk|folk|Американская
romances|folk|Романсы
argentinetango|folk|Аргентинское танго
armenian|folk|Армянская
georgian|folk|Грузинская
azerbaijani|folk|Азербайджанская
caucasian|folk|Кавказская
turkishclassical|folk|Турецкая классическая музыка
arabesquemusic|folk|Арабеска
turkishfolk|folk|Турецкая народная музыка
tarab|folk|Тараб
mahraganat|folk|Махраганат
uzbekfolk|folk|Узбекская народная музыка
kazakhfolk|folk|Казахская народная музыка
shelatgenre|folk|Шейлат
raigenre|folk|Раи
dabkegenre|folk|Дабка
sufifolkgenre|folk|Суфийский фолк
estrada|pop|Эстрада
rusestrada|pop|Русская
kazestrada|pop|Казахская эстрада
uzretropop|pop|Узбекская эстрада
shanson|folk|Шансон
country|folk|Кантри
soundtrack|cinematic|Саундтреки
films|cinematic|Из фильмов
tvseries|cinematic|Из сериалов
animated|cinematic|Из мультфильмов
videogame|cinematic|Из видеоигр
animemusic|cinematic|Аниме
musical|cinematic|Мюзиклы
bollywood|cinematic|Болливуд
relax|lofi|Лёгкая музыка
meditation|lofi|Медитация
children|pop|Детская музыка со всего мира
arabickids|pop|Арабская музыка для детей
naturesounds|lofi|Звуки природы и шум города
bard|folk|Авторская песня
rusbards|folk|Русская
foreignbard|folk|Иностранная
forchildren|pop|Детская
lullaby|pop|Колыбельные
classicalmusic|classical|Классика
vocal|classical|Вокал
modern|classical|Современная классика
classical|classical|Мировая классика
classicalmasterpieces|classical|Шедевры мировой классики
folkgenre|folk|Фолк
islamicgenre|folk|Исламская музыка
other|universal|Другое
sport|universal|Спортивная
holiday|universal|Christmas-Repetoire
""")

    /// Эти теги встречаются в метаданных альбомов, но отсутствуют в текущем
    /// endpoint /genres. Сохраняем совместимость и даём им ясные подписи.
    private static let legacyEntries: [String: Entry] = [
        "grunge": .init(style: .rockWall, label: "Гранж"),
        "eurodance": .init(style: .dance, label: "Евродэнс"),
        "drumandbass": .init(style: .breakbeat, label: "Драм-н-бэйс"),
        "lofi": .init(style: .lofi, label: "Лоу-фай"),
        "ambient": .init(style: .lofi, label: "Эмбиент"),
        "chill": .init(style: .lofi, label: "Chill"),
        "latin": .init(style: .folk, label: "Латиноамериканская музыка"),
        "world": .init(style: .cinematic, label: "Музыка мира"),
        "indierock": .init(style: .alternativeIndie, label: "Инди-рок"),
        "poppunk": .init(style: .punk, label: "Поп-панк"),
        "deephouse": .init(style: .techno, label: "Deep house"),
        "jungle": .init(style: .breakbeat, label: "Jungle"),
        "hiphop": .init(style: .rap, label: "Хип-хоп")
    ]

    private static func entries(from snapshot: String) -> [String: Entry] {
        snapshot
            .split(whereSeparator: \.isNewline)
            .reduce(into: [:]) { entries, line in
                let fields = line.split(
                    separator: "|",
                    maxSplits: 2,
                    omittingEmptySubsequences: false
                )
                guard fields.count == 3,
                      let style = MediaAnimationStyle(rawValue: String(fields[1])) else {
                    return
                }
                entries[String(fields[0])] = .init(
                    style: style,
                    label: String(fields[2])
                )
            }
    }

    private struct Entry {
        let style: MediaAnimationStyle
        let label: String
    }
}
