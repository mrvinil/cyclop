import Foundation

enum DownloadRequestError: Error, Equatable {
    case empty
    case unsupportedScheme
    case missingHost
    case malformedURL
    case credentialsNotSupported
}

enum DownloadRequestParser {
    static func parse(_ raw: String) throws -> URL {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            throw DownloadRequestError.empty
        }

        guard let schemeSeparator = value.firstIndex(of: ":") else {
            throw DownloadRequestError.unsupportedScheme
        }
        let scheme = value[..<schemeSeparator]
        guard scheme.caseInsensitiveCompare("http") == .orderedSame
                || scheme.caseInsensitiveCompare("https") == .orderedSame else {
            throw DownloadRequestError.unsupportedScheme
        }

        guard let url = URL(string: value, encodingInvalidCharacters: false) else {
            throw DownloadRequestError.malformedURL
        }
        guard let host = url.host, !host.isEmpty else {
            throw DownloadRequestError.missingHost
        }
        guard url.user == nil, url.password == nil else {
            throw DownloadRequestError.credentialsNotSupported
        }

        return url
    }
}
