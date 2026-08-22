import AppKit
import Foundation

enum NotchDropPayload: Equatable {
    case files([URL])

    /// Cyclop принимает на полку только файлы. Ссылки намеренно не являются
    /// полезной нагрузкой: встроенный URL-загрузчик удалён.
    static func parse(_ items: [NSPasteboardItem]) -> Self? {
        guard !items.isEmpty else { return nil }

        var files: [URL] = []

        for item in items {
            if let fileURL = fileURL(from: item) {
                files.append(fileURL)
            } else {
                return nil
            }
        }

        if !files.isEmpty { return .files(files) }
        return nil
    }

    private static func fileURL(from item: NSPasteboardItem) -> URL? {
        guard let raw = item.string(forType: .fileURL),
              let url = URL(string: raw),
              url.isFileURL else {
            return nil
        }
        return url
    }
}
