import Darwin
import Foundation

public enum FileSafety {
    public static func stamp(at url: URL) -> FileStamp? {
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & mode_t(S_IFMT)) != mode_t(S_IFLNK) else { return nil }
        return FileStamp(device: UInt64(info.st_dev), inode: UInt64(info.st_ino),
                         size: Int64(info.st_size), modifiedSeconds: Int64(info.st_mtimespec.tv_sec),
                         modifiedNanoseconds: Int64(info.st_mtimespec.tv_nsec),
                         linkCount: UInt64(info.st_nlink))
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
        guard let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]),
              values.isUbiquitousItem == true else { return false }
        return values.ubiquitousItemDownloadingStatus != URLUbiquitousItemDownloadingStatus.current
    }
}
