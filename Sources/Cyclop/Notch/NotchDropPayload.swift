import AppKit
import Foundation

enum NotchDropPayload: Equatable {
    case files([URL])
    case remoteURLs([URL])

    /// Reads one semantic value from each pasteboard item. Browser drags often
    /// expose the same link as both `.URL` and `.string`, so reading types in
    /// bulk would duplicate it. A remote URL wins within an item; otherwise a
    /// file URL is accepted. Any invalid or mixed item rejects the whole drop.
    static func parse(_ items: [NSPasteboardItem]) -> Self? {
        guard !items.isEmpty else { return nil }

        var files: [URL] = []
        var remoteURLs: [URL] = []

        for item in items {
            if let remoteURL = remoteURL(from: item) {
                remoteURLs.append(remoteURL)
            } else if let fileURL = fileURL(from: item) {
                files.append(fileURL)
            } else {
                return nil
            }

            guard files.isEmpty || remoteURLs.isEmpty else { return nil }
        }

        if !remoteURLs.isEmpty { return .remoteURLs(remoteURLs) }
        if !files.isEmpty { return .files(files) }
        return nil
    }

    private static func remoteURL(from item: NSPasteboardItem) -> URL? {
        for type in [NSPasteboard.PasteboardType.URL, .string] {
            guard let raw = item.string(forType: type),
                  let url = try? DownloadRequestParser.parse(raw) else {
                continue
            }
            return url
        }
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
