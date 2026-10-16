import AppKit
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
                  !NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == identifier }),
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
