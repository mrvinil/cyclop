import Foundation

enum MediaGenrePresentation {
    static func statusText(for presentation: GenreAnimationPresentation?) -> String? {
        guard let presentation,
              presentation.isAutomatic,
              let genreLabel = presentation.genreLabel,
              !genreLabel.isEmpty else {
            return nil
        }

        return "Жанр: \(genreLabel) · анимация выбрана автоматически"
    }
}
