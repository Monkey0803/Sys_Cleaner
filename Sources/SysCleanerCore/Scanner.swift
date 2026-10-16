import AppKit
import CryptoKit
import Foundation

public final class ScanControl: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    public init() {}
    public func cancel() { lock.lock(); stopped = true; lock.unlock() }
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
}

public enum FileScanner {
    public static func scan(_ request: ScanRequest, control: ScanControl = ScanControl()) -> ScanReport {
        var warnings: [String] = []
        var entries: [ScanEntry] = []
        let root = request.root.resolvingSymlinksInPath().standardizedFileURL
        switch request.category {
        case .space:
            return scanSpace(root: root, control: control)
        case .large:
            let oldest = Date().addingTimeInterval(-Double(request.olderThanDays) * 86_400)
            walkFiles(under: root, control: control, warnings: &warnings) { url, stamp in
                guard stamp.size >= request.minimumBytes,
                      request.olderThanDays == 0 || Date(timeIntervalSince1970: Double(stamp.modifiedSeconds)) <= oldest
                else { return }
                entries.append(ScanEntry(url: url, scope: root, category: .large, stamp: stamp,
                                         estimatedBytes: stamp.size, note: "reviewLarge",
                                         canDelete: FileSafety.isSafeLocation(url, scope: root, category: .large)))
            }
        case .duplicates:
            var candidates: [URL] = []
            var limited = false
            walkFiles(under: root, control: control, warnings: &warnings) { url, stamp in
                guard stamp.size > 0 else { return }
                if candidates.count < 100_000 { candidates.append(url) } else { limited = true }
            }
            if limited { appendWarning("duplicateLimit", to: &warnings) }
            entries = findDuplicates(files: candidates, root: root, control: control, warnings: &warnings)
        case .systemCache, .developerCache:
            let locations = request.category == .systemCache ? systemCacheLocations() : developerCacheLocations()
            var eligibleCount = 0
            for location in locations where !control.isCancelled {
                walkFiles(under: location, control: control, warnings: &warnings, checkCloud: false) { url, stamp in
                    eligibleCount += 1
                    entries.append(ScanEntry(url: url, scope: location, category: request.category,
                                             stamp: stamp, estimatedBytes: stamp.size,
                                             note: location.lastPathComponent))
                    if entries.count > 4_000 {
                        entries.sort { $0.estimatedBytes > $1.estimatedBytes }
                        entries.removeLast(entries.count - 2_000)
                    }
                }
            }
            if eligibleCount > 2_000 {
                entries.sort { $0.estimatedBytes > $1.estimatedBytes }
                entries = Array(entries.prefix(2_000))
                appendWarning("listLimited", to: &warnings)
            }
        case .uninstall:
            entries = scanApplications(control: control)
        }
        return ScanReport(entries: entries.sorted { $0.estimatedBytes > $1.estimatedBytes },
                          warnings: warnings, cancelled: control.isCancelled)
    }

    private static func collectFiles(under root: URL, control: ScanControl, warnings: inout [String],
                                     includeApps: Bool = false) -> [URL] {
        var files: [URL] = []
        walkFiles(under: root, control: control, warnings: &warnings, includeApps: includeApps) { url, _ in
            files.append(url)
        }
        return files
    }

    private static func walkFiles(under root: URL, control: ScanControl, warnings: inout [String],
                                  includeApps: Bool = false, includeHardLinks: Bool = false,
                                  checkCloud: Bool = true,
                                  onFile: (URL, FileStamp) -> Void) {
        guard FileSafety.isDirectory(root), let rootStamp = FileSafety.stamp(at: root) else {
            appendWarning("Cannot read \(root.path)", to: &warnings)
            return
        }
        var stack = [root]
        while let directory = stack.popLast(), !control.isCancelled {
            let children: [URL]
            do {
                children = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil,
                                                                       options: [])
            } catch {
                appendWarning("Cannot read \(directory.path): \(error.localizedDescription)", to: &warnings)
                continue
            }
            for url in children where !control.isCancelled {
                if url.lastPathComponent == ".Trash" { continue }
                guard let stamp = FileSafety.stamp(at: url), stamp.device == rootStamp.device else { continue }
                if checkCloud && FileSafety.isCloudPlaceholder(url) { continue }
                if FileSafety.isDirectory(url) {
                    if url.pathExtension == "app" && !includeApps { continue }
                    stack.append(url)
                } else if stamp.linkCount == 1 || includeHardLinks {
                    onFile(url, stamp)
                }
            }
        }
    }

    private static func scanSpace(root: URL, control: ScanControl) -> ScanReport {
        var warnings: [String] = []
        var directoryTotals: [URL: Int64] = [:]
        var otherTotals: [URL: Int64] = [:]
        var visibleFiles: [SpaceItem] = []
        var count = 0
        var total: Int64 = 0
        walkFiles(under: root, control: control, warnings: &warnings,
                  includeApps: true, includeHardLinks: true) { url, stamp in
            count += 1
            total += stamp.size
            let parent = url.deletingLastPathComponent()
            if stamp.size >= 1_048_576 && visibleFiles.count < 10_000 {
                visibleFiles.append(SpaceItem(url: url, parent: parent, bytes: stamp.size, isFolder: false))
            } else {
                otherTotals[parent, default: 0] += stamp.size
            }
            var ancestor = parent
            while ancestor.path == root.path || ancestor.path.hasPrefix(root.path + "/") {
                directoryTotals[ancestor, default: 0] += stamp.size
                if ancestor.path == root.path { break }
                ancestor.deleteLastPathComponent()
            }
        }
        let folders = directoryTotals.compactMap { url, bytes -> SpaceItem? in
            guard url != root else { return nil }
            return SpaceItem(url: url, parent: url.deletingLastPathComponent(), bytes: bytes, isFolder: true)
        }
        let others = otherTotals.map { parent, bytes in
            SpaceItem(url: parent.appendingPathComponent("__other_files__"), parent: parent,
                      bytes: bytes, isFolder: false, isOther: true)
        }
        if visibleFiles.count == 10_000 { appendWarning("spaceLimit", to: &warnings) }
        return ScanReport(entries: [], warnings: warnings, cancelled: control.isCancelled,
                          spaceItems: folders + visibleFiles + others,
                          scannedFileCount: count, scannedBytes: total)
    }

    private static func findDuplicates(files: [URL], root: URL, control: ScanControl,
                                       warnings: inout [String]) -> [ScanEntry] {
        let sized = Dictionary(grouping: files.compactMap { url -> (URL, FileStamp)? in
            guard let stamp = FileSafety.stamp(at: url), stamp.size > 0, stamp.linkCount == 1 else { return nil }
            return (url, stamp)
        }, by: { $0.1.size })
        var results: [ScanEntry] = []
        for (_, peers) in sized where peers.count > 1 && !control.isCancelled {
            var hashes: [String: [(URL, FileStamp)]] = [:]
            for (url, stamp) in peers where !control.isCancelled {
                if let digest = hashFile(url, control: control), FileSafety.stamp(at: url) == stamp {
                    hashes[digest, default: []].append((url, stamp))
                } else {
                    appendWarning("Changed or unreadable: \(url.path)", to: &warnings)
                }
            }
            for (digest, group) in hashes where group.count > 1 {
                let sorted = group.sorted { $0.0.path < $1.0.path }
                for (index, element) in sorted.enumerated() {
                    results.append(ScanEntry(url: element.0, scope: root, category: .duplicates,
                                             stamp: element.1, estimatedBytes: element.1.size,
                                             risk: .review, note: index == 0 ? "keepOriginal" : "duplicateCopy",
                                             duplicateGroup: digest,
                                             canDelete: index != 0 &&
                                                FileSafety.isSafeLocation(element.0, scope: root, category: .duplicates)))
                }
            }
        }
        return results
    }

    private static func hashFile(_ url: URL, control: ScanControl) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        do {
            while !control.isCancelled {
                let data = try handle.read(upToCount: 1_048_576) ?? Data()
                if data.isEmpty { return hasher.finalize().map { String(format: "%02x", $0) }.joined() }
                hasher.update(data: data)
            }
        } catch { return nil }
        return nil
    }

    private static func systemCacheLocations() -> [URL] {
        let library = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library")
        return [library.appendingPathComponent("Caches"), library.appendingPathComponent("Logs")]
    }

    private static func developerCacheLocations() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [home.appendingPathComponent("Library/Developer/Xcode/DerivedData"),
                home.appendingPathComponent("Library/Caches/org.swift.swiftpm"),
                home.appendingPathComponent("Library/Caches/Homebrew")]
    }

    private static func scanApplications(control: ScanControl) -> [ScanEntry] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let roots = [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")]
        var entries: [ScanEntry] = []
        for root in roots where !control.isCancelled {
            guard let apps = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { continue }
            for app in apps where app.pathExtension.lowercased() == "app" && !control.isCancelled {
                guard let identifier = Bundle(url: app)?.bundleIdentifier,
                      let stamp = FileSafety.stamp(at: app), FileSafety.isDirectory(app),
                      FileSafety.isSafeLocation(app, scope: root, category: .uninstall) else { continue }
                let running = NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == identifier }
                entries.append(ScanEntry(url: app, scope: root, category: .uninstall, stamp: stamp,
                                         estimatedBytes: 0, risk: running ? .protected : .review,
                                         note: running ? "appRunning" : identifier,
                                         isDirectory: true, canDelete: false))
            }
        }
        return entries
    }

    public static func prepareApplication(_ app: ScanEntry, control: ScanControl = ScanControl()) -> ScanReport {
        var warnings: [String] = []
        guard app.category == .uninstall, app.isDirectory,
              let identifier = Bundle(url: app.url)?.bundleIdentifier,
              FileSafety.stamp(at: app.url) == app.stamp,
              !NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == identifier }),
              let signature = directorySignature(app.url, control: control) else {
            return ScanReport(entries: [], warnings: ["changedOrRunning"], cancelled: control.isCancelled)
        }
        var prepared = [ScanEntry(url: app.url, scope: app.scope, category: .uninstall,
                                  stamp: app.stamp, estimatedBytes: signature.bytes,
                                  note: identifier, isDirectory: true, directorySignature: signature.digest)]
        let library = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library")
        let candidates = ["Application Support", "Caches", "Containers", "Logs", "HTTPStorages",
                          "WebKit", "Application Scripts"]
            .map { library.appendingPathComponent($0).appendingPathComponent(identifier) }
            + [library.appendingPathComponent("Saved Application State").appendingPathComponent(identifier + ".savedState")]
        for candidate in candidates where !control.isCancelled {
            guard FileSafety.isDirectory(candidate) else { continue }
            for file in collectFiles(under: candidate, control: control, warnings: &warnings) {
                guard let stamp = FileSafety.stamp(at: file), stamp.linkCount == 1 else { continue }
                prepared.append(ScanEntry(url: file, scope: candidate, category: .uninstall,
                                          stamp: stamp, estimatedBytes: stamp.size, note: identifier))
            }
        }
        let exactFiles = [library.appendingPathComponent("Preferences/\(identifier).plist"),
                          library.appendingPathComponent("LaunchAgents/\(identifier).plist")]
        for file in exactFiles where !control.isCancelled {
            guard let stamp = FileSafety.stamp(at: file), !FileSafety.isDirectory(file), stamp.linkCount == 1 else { continue }
            prepared.append(ScanEntry(url: file, scope: file.deletingLastPathComponent(), category: .uninstall,
                                      stamp: stamp, estimatedBytes: stamp.size, note: identifier))
        }
        return ScanReport(entries: prepared, warnings: warnings, cancelled: control.isCancelled)
    }

    public static func directorySignature(_ root: URL, control: ScanControl = ScanControl()) -> (digest: String, bytes: Int64)? {
        guard FileSafety.isDirectory(root) else { return nil }
        var warnings: [String] = []
        let files = collectFiles(under: root, control: control, warnings: &warnings, includeApps: true)
        guard warnings.isEmpty, !control.isCancelled else { return nil }
        var hasher = SHA256()
        var total: Int64 = 0
        for url in files.sorted(by: { $0.path < $1.path }) {
            guard let stamp = FileSafety.stamp(at: url) else { return nil }
            total += stamp.size
            let part = "\(url.path.dropFirst(root.path.count))|\(stamp.device)|\(stamp.inode)|\(stamp.size)|\(stamp.modifiedSeconds)|\(stamp.modifiedNanoseconds)"
            hasher.update(data: Data(part.utf8))
        }
        return (hasher.finalize().map { String(format: "%02x", $0) }.joined(), total)
    }

    private static func appendWarning(_ message: String, to warnings: inout [String]) {
        if warnings.count < 50 { warnings.append(message) }
    }
}
