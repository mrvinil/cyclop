import Foundation

enum DownloadNaming {
    private static let maximumFilenameBytes = 240

    static func destination(
        folder: URL,
        responseFilename: String?,
        remoteURL: URL,
        fileExists: (String) -> Bool
    ) -> URL {
        let responseName = responseFilename.flatMap(sanitized)
        let remoteName = sanitized(remoteURL.lastPathComponent)
        let selectedName = responseName ?? remoteName ?? "Загрузка"
        let parts = filenameParts(selectedName)

        var collisionIndex: Int?
        while true {
            let candidateName = fittedName(parts: parts, collisionIndex: collisionIndex)
            let candidateURL = folder.appendingPathComponent(candidateName)
            guard fileExists(candidateURL.path) else {
                return candidateURL
            }
            collisionIndex = (collisionIndex ?? 1) + 1
        }
    }

    private static func sanitized(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let pathComponent = trimmed
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/", omittingEmptySubsequences: true)
            .last
            .map(String.init) ?? ""

        var result = ""
        for scalar in pathComponent.unicodeScalars {
            if isBidiFormatControl(scalar) {
                continue
            }
            if scalar == ":" || scalar == "/" || scalar == "\\"
                || scalar.properties.generalCategory == .control {
                result.append("_")
            } else {
                result.unicodeScalars.append(scalar)
            }
        }

        guard !result.isEmpty, result != ".", result != ".." else {
            return nil
        }
        return result
    }

    private static func filenameParts(_ name: String) -> (base: String, extension: String) {
        guard let dot = name.lastIndex(of: "."),
              dot != name.startIndex else {
            return (name, "")
        }

        let base = String(name[..<dot])
        let extensionStart = name.index(after: dot)
        guard extensionStart != name.endIndex, base != ".", base != ".." else {
            return (name, "")
        }
        return (base, String(name[dot...]))
    }

    private static func fittedName(
        parts: (base: String, extension: String),
        collisionIndex: Int?
    ) -> String {
        let suffix = collisionIndex.map { " (\($0))" } ?? ""
        let reservedBytes = suffix.utf8.count + parts.extension.utf8.count

        if reservedBytes <= maximumFilenameBytes {
            let base = prefix(parts.base, fitting: maximumFilenameBytes - reservedBytes)
            let candidate = base + suffix + parts.extension
            if !candidate.isEmpty, candidate != ".", candidate != ".." {
                return candidate
            }
        }

        let suffixBytes = suffix.utf8.count
        if suffixBytes <= maximumFilenameBytes {
            let base = prefix(parts.base + parts.extension, fitting: maximumFilenameBytes - suffixBytes)
            let candidate = base + suffix
            if !candidate.isEmpty, candidate != ".", candidate != ".." {
                return candidate
            }
        }

        return prefix("Загрузка" + suffix, fitting: maximumFilenameBytes)
    }

    private static func prefix(_ value: String, fitting byteLimit: Int) -> String {
        guard byteLimit > 0 else { return "" }

        var result = ""
        var byteCount = 0
        for character in value {
            let characterBytes = String(character).utf8.count
            guard byteCount + characterBytes <= byteLimit else { break }
            result.append(character)
            byteCount += characterBytes
        }
        return result
    }

    private static func isBidiFormatControl(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x061C, 0x200E, 0x200F, 0x202A ... 0x202E, 0x2066 ... 0x2069:
            return true
        default:
            return false
        }
    }
}
