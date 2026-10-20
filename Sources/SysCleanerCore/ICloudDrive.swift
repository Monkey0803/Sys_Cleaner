import Darwin
import Foundation

/// iCloud Drive inspection and local-copy eviction. This never reads file contents.
public enum ICloudDrive {
    public static var root: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
            .standardizedFileURL
    }

    public struct State: Equatable, Sendable {
        public enum Download: Equatable, Sendable { case current, stale, remote, unknown }
        public let isUbiquitous: Bool
        public let download: Download
        public let uploaded: Bool?
        public let uploading: Bool?
        public let conflicts: Bool?

        public init(isUbiquitous: Bool, download: Download, uploaded: Bool?,
                    uploading: Bool?, conflicts: Bool?) {
            self.isUbiquitous = isUbiquitous
            self.download = download
            self.uploaded = uploaded
            self.uploading = uploading
            self.conflicts = conflicts
        }

        public var canEvict: Bool {
            isUbiquitous && download == .current && uploaded == true &&
                uploading == false && conflicts == false
        }

        public var note: String {
            if !isUbiquitous { return "icloudNotSynced" }
            if conflicts == true { return "icloudConflict" }
            if uploading == true || uploaded == false { return "icloudUploading" }
            if download == .remote { return "icloudRemote" }
            if uploaded == nil || uploading == nil || conflicts == nil { return "icloudUnknown" }
            switch download {
            case .current: return "icloudCurrent"
            case .stale: return "icloudStale"
            case .remote: return "icloudRemote"
            case .unknown: return "icloudUnknown"
            }
        }
    }

    public static func state(at url: URL) -> State? {
        let keys: Set<URLResourceKey> = [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
            .ubiquitousItemIsUploadedKey, .ubiquitousItemIsUploadingKey,
            .ubiquitousItemHasUnresolvedConflictsKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
        let download: State.Download
        switch values.ubiquitousItemDownloadingStatus {
        case .current: download = .current
        case .downloaded: download = .stale
        case .notDownloaded: download = .remote
        default: download = .unknown
        }
        return State(isUbiquitous: values.isUbiquitousItem == true, download: download,
                     uploaded: values.ubiquitousItemIsUploaded,
                     uploading: values.ubiquitousItemIsUploading,
                     conflicts: values.ubiquitousItemHasUnresolvedConflicts)
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 &&
            (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG)
    }

    public static func scan(control: ScanControl = ScanControl(), at scope: URL = root,
                            readState: (URL) -> State? = state(at:),
                            listChildren: (URL) throws -> [URL] = {
                                try FileManager.default.contentsOfDirectory(
                                    at: $0, includingPropertiesForKeys: nil)
                            }) -> ScanReport {
        let scope = scope.standardizedFileURL
        guard let rootInfo = FileSafety.metadata(at: scope), rootInfo.isDirectory else {
            return ScanReport(entries: [], warnings: ["icloudUnavailable"], cancelled: false,
                              scannedFileCount: 0, scannedBytes: 0, scannedAllocatedBytes: 0,
                              omittedCount: 1)
        }
        var entries: [ScanEntry] = []
        var warnings: [String] = []
        var omitted = 0
        var count = 0
        var logical: Int64 = 0
        var allocated: Int64 = 0
        var stack = [scope]
        while let directory = stack.popLast(), !control.isCancelled {
            autoreleasepool {
                let children: [URL]
                do {
                    children = try listChildren(directory)
                } catch {
                    omitted += 1
                    if warnings.count < 50 {
                        warnings.append("Cannot read \(directory.path): \(error.localizedDescription)")
                    }
                    return
                }
                for child in children where !control.isCancelled {
                    autoreleasepool {
                        if child.lastPathComponent == ".Trash" { return }
                        guard let info = FileSafety.metadata(at: child),
                              info.stamp.device == rootInfo.stamp.device else {
                            omitted += 1
                            return
                        }
                        let item = info.isDirectory
                            ? directory.appendingPathComponent(child.lastPathComponent, isDirectory: true)
                            : child
                        let state = readState(item)
                        let localBytes = state?.download == .remote ? 0 : (info.stamp.allocatedBytes ?? 0)
                        let eligible = !info.isDirectory && info.stamp.linkCount == 1 &&
                            localBytes > 0 && state?.canEvict == true && isRegularFile(item)
                        entries.append(ScanEntry(url: item, scope: scope, category: .icloud,
                            stamp: info.stamp, estimatedBytes: info.isDirectory ? 0 : info.stamp.size,
                            allocatedBytes: info.isDirectory ? nil : localBytes,
                            risk: eligible ? .review : .protected,
                            note: info.isDirectory ? "icloudFolder" : (state?.note ?? "icloudUnknown"),
                            isDirectory: info.isDirectory, canDelete: eligible))
                        if info.isDirectory {
                            control.visited(item)
                            // A cloud directory may report notDownloaded even when its
                            // child names are available locally. Try metadata enumeration.
                            stack.append(item)
                        } else {
                            count += 1
                            logical += info.stamp.size
                            allocated += localBytes
                            control.visited(item, bytes: info.stamp.size)
                        }
                    }
                }
            }
        }
        if omitted > 0 && warnings.isEmpty { warnings = ["scanIncomplete"] }
        control.recordOmitted(omitted)
        return ScanReport(entries: entries, warnings: warnings, cancelled: control.isCancelled,
                          scannedFileCount: count, scannedBytes: logical,
                          scannedAllocatedBytes: allocated, omittedCount: omitted)
    }

    public static func evict(_ entry: ScanEntry, scope: URL = root,
                             readState: (URL) -> State? = state(at:),
                             perform: (URL) throws -> Void = { try FileManager.default.evictUbiquitousItem(at: $0) }) -> DeleteResult {
        let scope = scope.standardizedFileURL
        guard entry.category == .icloud, !entry.isDirectory, entry.canDelete,
              entry.scope.standardizedFileURL == scope,
              entry.url.standardizedFileURL.path.hasPrefix(scope.path + "/"),
              FileSafety.isDirectory(scope),
              !FileSafety.hasSymlinkInPath(entry.url, through: scope) else {
            return DeleteResult(url: entry.url, success: false, message: "unsafePath")
        }
        guard let current = FileSafety.metadata(at: entry.url), !current.isDirectory,
              current.stamp == entry.stamp, current.stamp.linkCount == 1,
              isRegularFile(entry.url),
              readState(entry.url)?.canEvict == true else {
            return DeleteResult(url: entry.url, success: false, message: "changed")
        }
        do {
            try perform(entry.url)
            return DeleteResult(url: entry.url, success: true, message: "icloudLocalRemoved")
        } catch {
            return DeleteResult(url: entry.url, success: false, message: error.localizedDescription)
        }
    }
}
