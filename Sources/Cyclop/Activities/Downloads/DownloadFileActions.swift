import AppKit
import Foundation

enum DownloadFileActionError: Error, Equatable {
    case missingFile
    case operationFailed
}

struct DownloadFileActions {
    let open: (URL) -> Result<Void, DownloadFileActionError>
    let reveal: (URL) -> Result<Void, DownloadFileActionError>

    static func live(
        fileManager: FileManager = .default,
        workspace: NSWorkspace = .shared
    ) -> Self {
        Self(
            open: { url in
                guard isExistingFile(url, fileManager: fileManager) else {
                    return .failure(.missingFile)
                }
                return workspace.open(url)
                    ? .success(())
                    : .failure(.operationFailed)
            },
            reveal: { url in
                guard isExistingFile(url, fileManager: fileManager) else {
                    return .failure(.missingFile)
                }
                return workspace.selectFile(
                    url.path,
                    inFileViewerRootedAtPath: ""
                ) ? .success(()) : .failure(.operationFailed)
            }
        )
    }

    private static func isExistingFile(
        _ url: URL,
        fileManager: FileManager
    ) -> Bool {
        guard url.isFileURL, url.path.hasPrefix("/") else { return false }
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
    }
}
