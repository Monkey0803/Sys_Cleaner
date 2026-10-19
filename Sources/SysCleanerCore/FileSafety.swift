import AppKit
import Darwin
import Foundation

public enum FileSafety {
    public static func isApplicationRunning(_ app: URL, identifier: String) -> Bool {
        return NSWorkspace.shared.runningApplications.contains { running in
            matchesRunningApplication(app, identifier: identifier,
                                      runningIdentifier: running.bundleIdentifier,
                                      runningBundle: running.bundleURL)
        }
    }

    static func matchesRunningApplication(_ app: URL, identifier: String,
                                          runningIdentifier: String?, runningBundle: URL?) -> Bool {
        guard runningIdentifier == identifier else { return false }
        guard let runningBundle else { return true }
        let runningPath = runningBundle.resolvingSymlinksInPath().standardizedFileURL.path
        let appPath = app.resolvingSymlinksInPath().standardizedFileURL.path
        return runningPath == appPath || runningPath.hasPrefix(appPath + "/")
    }

    static func metadata(at url: URL) -> (stamp: FileStamp, isDirectory: Bool)? {
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & mode_t(S_IFMT)) != mode_t(S_IFLNK) else { return nil }
        let stamp = FileStamp(device: UInt64(info.st_dev), inode: UInt64(info.st_ino),
                              size: Int64(info.st_size), modifiedSeconds: Int64(info.st_mtimespec.tv_sec),
                              modifiedNanoseconds: Int64(info.st_mtimespec.tv_nsec),
                              linkCount: UInt64(info.st_nlink),
                              allocatedBytes: Int64(info.st_blocks) * 512,
                              changedSeconds: Int64(info.st_ctimespec.tv_sec),
                              changedNanoseconds: Int64(info.st_ctimespec.tv_nsec))
        return (stamp, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR))
    }

    public static func stamp(at url: URL) -> FileStamp? {
        metadata(at: url)?.stamp
    }

    public static func isDirectory(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR)
    }

    public static func isSafeLocation(_ url: URL, scope: URL, category: ScanCategory) -> Bool {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        let base = scope.resolvingSymlinksInPath().standardizedFileURL.path
        guard path != base, path.hasPrefix(base + "/"),
              !path.split(separator: "/").contains(".."),
              !path.contains("/.Trash/") else { return false }

        let systemRoots = ["/System", "/usr", "/bin", "/sbin", "/private", "/Library"]
        if systemRoots.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { return false }
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        if path == home || path == "/" { return false }
        if category != .uninstall && path.split(separator: "/").dropLast().contains(where: {
            $0.hasSuffix(".app") || $0.hasSuffix(".xcarchive")
        }) {
            return false
        }
        if path.hasPrefix("/Applications/") {
            return category == .uninstall && path.hasSuffix(".app") &&
                !path.hasPrefix("/Applications/Utilities/")
        }
        return path.hasPrefix(home + "/") || category == .space || category == .large || category == .duplicates
    }

    public static func hasSymlinkInPath(_ url: URL, through scope: URL) -> Bool {
        let base = scope.resolvingSymlinksInPath().standardizedFileURL.path
        var current = url.standardizedFileURL
        while current.path != base && current.path != "/" {
            var info = stat()
            if lstat(current.path, &info) != 0 || (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFLNK) {
                return true
            }
            current.deleteLastPathComponent()
        }
        return current.path != base
    }

    public static func isCloudPlaceholder(_ url: URL) -> Bool {
        guard let ubiquitous = try? url.resourceValues(forKeys: [.isUbiquitousItemKey]),
              ubiquitous.isUbiquitousItem == true else { return false }
        let status = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
        return status?.ubiquitousItemDownloadingStatus != URLUbiquitousItemDownloadingStatus.current
    }
}
