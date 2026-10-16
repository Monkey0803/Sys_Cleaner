import AppKit
import Darwin
import Foundation

public enum FileDeletion {
    public static func execute(_ entries: [ScanEntry], mode: DeleteMode) -> [DeleteResult] {
        entries.map { entry in
            if let reason = refusal(for: entry) {
                return DeleteResult(url: entry.url, success: false, message: reason)
            }
            do {
                switch mode {
                case .trash:
                    var destination: NSURL?
                    try FileManager.default.trashItem(at: entry.url, resultingItemURL: &destination)
                    return DeleteResult(url: entry.url, success: true, message: "movedToTrash",
                                        trashURL: destination as URL?)
                case .permanent:
                    try FileManager.default.removeItem(at: entry.url)
                    return DeleteResult(url: entry.url, success: true, message: "deleted")
                }
            } catch {
                return DeleteResult(url: entry.url, success: false, message: error.localizedDescription)
            }
        }
    }

    public static func refusal(for entry: ScanEntry) -> String? {
        guard entry.canDelete, entry.risk != .protected else { return "protected" }
        guard FileSafety.isSafeLocation(entry.url, scope: entry.scope, category: entry.category),
              FileSafety.isDirectory(entry.scope),
              !FileSafety.hasSymlinkInPath(entry.url, through: entry.scope) else { return "unsafePath" }
        guard !FileSafety.isCloudPlaceholder(entry.url) else { return "cloudPlaceholder" }
        guard let current = FileSafety.stamp(at: entry.url), current == entry.stamp,
              current.linkCount == 1 || entry.isDirectory else { return "changed" }
        if entry.category == .uninstall && !entry.isDirectory &&
            NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == entry.note }) {
            return "changedOrRunning"
        }
        if entry.isDirectory {
            guard entry.category == .uninstall,
                  let identifier = Bundle(url: entry.url)?.bundleIdentifier,
                  !FileSafety.isApplicationRunning(entry.url, identifier: identifier),
                  let signature = FileScanner.directorySignature(entry.url),
                  signature.digest == entry.directorySignature else { return "changedOrRunning" }
        } else {
            if entry.category == .systemCache {
                let relative = entry.url.path.dropFirst(entry.scope.path.count).drop(while: { $0 == "/" })
                if let owner = relative.split(separator: "/").first,
                   NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == String(owner) }) {
                    return "fileInUse"
                }
            }
            if entry.category == .developerCache && entry.url.path.contains("/Xcode/DerivedData/") &&
                NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == "com.apple.dt.Xcode" }) {
                return "fileInUse"
            }
            let recent = Date().timeIntervalSince1970 - Double(current.modifiedSeconds) < 900
            if (entry.category == .systemCache || entry.category == .developerCache) && recent { return "recentlyUsed" }
            if isOpenByAnotherProcess(entry.url) { return "fileInUse" }
        }
        return nil
    }

    private static func isOpenByAnotherProcess(_ url: URL) -> Bool {
        let executable = URL(fileURLWithPath: "/usr/sbin/lsof")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { return false }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["-t", "--", url.path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return true
        }
    }
}

public enum FileRestoration {
    /// Returns a localized message key (or a system error) on failure.
    public static func restore(_ item: CleanupHistoryItem, category: ScanCategory) -> String? {
        guard item.canRestore, let trashPath = item.trashPath,
              let scopePath = item.scopePath, let expectedStamp = item.trashStamp else {
            return "restoreUnavailable"
        }
        let original = URL(fileURLWithPath: item.path).standardizedFileURL
        let trash = URL(fileURLWithPath: trashPath).standardizedFileURL
        let scope = URL(fileURLWithPath: scopePath).standardizedFileURL
        guard let trashRoot = trustedTrashRoot(for: trash),
              FileSafety.isDirectory(trashRoot),
              !FileSafety.hasSymlinkInPath(trash, through: trashRoot),
              FileSafety.isSafeLocation(original, scope: scope, category: category),
              FileSafety.isDirectory(scope),
              FileSafety.isDirectory(original.deletingLastPathComponent()),
              !FileSafety.hasSymlinkInPath(original.deletingLastPathComponent(), through: scope)
        else { return "unsafePath" }
        var existing = stat()
        guard lstat(original.path, &existing) != 0 else { return "restoreConflict" }
        guard FileSafety.stamp(at: trash) == expectedStamp else { return "restoreChanged" }
        do {
            try FileManager.default.moveItem(at: trash, to: original)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private static func trustedTrashRoot(for trash: URL) -> URL? {
        let path = trash.path
        let homeTrash = FileManager.default.homeDirectoryForCurrentUser
            .resolvingSymlinksInPath().standardizedFileURL.appendingPathComponent(".Trash")
        if path.hasPrefix(homeTrash.path + "/") { return homeTrash }
        let volumePrefix = "/Volumes/"
        let component = "/.Trashes/\(getuid())/"
        guard path.hasPrefix(volumePrefix), let range = path.range(of: component) else { return nil }
        return URL(fileURLWithPath: String(path[..<range.upperBound].dropLast()))
    }
}
