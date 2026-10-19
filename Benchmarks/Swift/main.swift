import Darwin
import Foundation
import SysCleanerCore

private struct Totals: Codable {
    var logical: Int64 = 0
    var allocated: Int64 = 0
}

private struct Output: Codable {
    var files = 0
    var directories = 0
    var logical: Int64 = 0
    var allocated: Int64 = 0
    var omitted = 0
    var cancelled = false
    var folders: [String: Totals]?
}

private final class WorkQueue: @unchecked Sendable {
    private let condition = NSCondition()
    private var pending: [URL]
    private var outstanding = 1
    private var stopped = false

    init(root: URL) { pending = [root] }
    var cancelled: Bool { condition.lock(); defer { condition.unlock() }; return stopped }
    func cancel() { condition.lock(); stopped = true; condition.broadcast(); condition.unlock() }
    func next() -> URL? {
        condition.lock()
        defer { condition.unlock() }
        while pending.isEmpty && outstanding > 0 && !stopped { condition.wait() }
        return stopped ? nil : pending.popLast()
    }
    func add(_ url: URL) {
        condition.lock()
        if !stopped { pending.append(url); outstanding += 1; condition.signal() }
        condition.unlock()
    }
    func finished() {
        condition.lock()
        outstanding -= 1
        if outstanding == 0 { condition.broadcast() }
        condition.unlock()
    }
}

private func metadata(_ url: URL) -> stat? {
    var info = stat()
    return lstat(url.path, &info) == 0 ? info : nil
}

private func isCloudPlaceholderUsingFileManager(_ url: URL, manager: FileManager) -> Bool {
    guard manager.isUbiquitousItem(at: url) else { return false }
    let status = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
    return status?.ubiquitousItemDownloadingStatus != URLUbiquitousItemDownloadingStatus.current
}

private func isCloudPlaceholderUsingNSURL(_ url: URL) -> Bool {
    var value: AnyObject?
    do {
        try (url as NSURL).getResourceValue(&value, forKey: .isUbiquitousItemKey)
    } catch {
        return false
    }
    guard (value as? NSNumber)?.boolValue == true else { return false }
    let status = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
    return status?.ubiquitousItemDownloadingStatus != URLUbiquitousItemDownloadingStatus.current
}

private func scanMatched(root: URL, workers: Int, cancelAfter: Int?, manifest: Bool,
                         excluded: String?, local: Bool = false,
                         calculateTotals: Bool = true, checkCloud: Bool = false,
                         prefetchCloud: Bool = false, useFileManagerCloudCheck: Bool = false,
                         useNSURLCloudCheck: Bool = false) -> Output {
    guard let rootInfo = metadata(root), (rootInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else {
        return Output(omitted: 1)
    }
    let queue = WorkQueue(root: root)
    let lock = NSLock()
    var result = Output(directories: 1)
    var directoryTotals: [String: Totals] = [root.path: Totals()]
    var visitedFiles = 0
    DispatchQueue.concurrentPerform(iterations: workers) { _ in
        let manager = FileManager()
        var partial = Output()
        var partialTotals: [String: Totals] = [:]
        while let directory = queue.next() {
            autoreleasepool {
                defer { queue.finished() }
                let children: [URL]
                do {
                    children = try manager.contentsOfDirectory(
                        at: directory,
                        includingPropertiesForKeys: prefetchCloud ? [.isUbiquitousItemKey] : nil)
                } catch {
                    if local { partial.omitted += 1 }
                    else { lock.lock(); result.omitted += 1; lock.unlock() }
                    return
                }
                let usesRequestedPath = children.first.map {
                    $0.deletingLastPathComponent().path == directory.path
                } ?? true
                for child in children where !queue.cancelled {
                    let candidate = usesRequestedPath ? child : directory.appendingPathComponent(
                        child.lastPathComponent, isDirectory: false)
                    if candidate.lastPathComponent == ".Trash" { continue }
                    if let excluded, candidate.path == excluded || candidate.path.hasPrefix(excluded + "/") { continue }
                    guard let info = metadata(candidate) else {
                        if local { partial.omitted += 1 }
                        else { lock.lock(); result.omitted += 1; lock.unlock() }
                        continue
                    }
                    if info.st_dev != rootInfo.st_dev ||
                        (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFLNK) { continue }
                    let isDirectory = (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR)
                    let url = isDirectory
                        ? directory.appendingPathComponent(child.lastPathComponent, isDirectory: true)
                        : candidate
                    if checkCloud {
                        let checkURL = usesRequestedPath ? child : url
                        let placeholder: Bool
                        if useFileManagerCloudCheck {
                            placeholder = isCloudPlaceholderUsingFileManager(checkURL, manager: manager)
                        } else if useNSURLCloudCheck {
                            placeholder = isCloudPlaceholderUsingNSURL(checkURL)
                        } else {
                            placeholder = FileSafety.isCloudPlaceholder(checkURL)
                        }
                        if placeholder { continue }
                    }
                    if isDirectory {
                        if local {
                            partial.directories += 1
                            partialTotals[url.path] = Totals()
                        } else {
                            lock.lock()
                            result.directories += 1
                            directoryTotals[url.path] = Totals()
                            lock.unlock()
                        }
                        queue.add(url)
                    } else {
                        let size = Int64(info.st_size)
                        let allocated = Int64(info.st_blocks) * 512
                        let shouldCancel: Bool
                        if local {
                            partial.files += 1
                            partial.logical += size
                            partial.allocated += allocated
                            partialTotals[directory.path, default: Totals()].logical += size
                            partialTotals[directory.path, default: Totals()].allocated += allocated
                            if let cancelAfter {
                                lock.lock()
                                visitedFiles += 1
                                shouldCancel = visitedFiles >= cancelAfter
                                lock.unlock()
                            } else { shouldCancel = false }
                        } else {
                            lock.lock()
                            result.files += 1
                            result.logical += size
                            result.allocated += allocated
                            directoryTotals[directory.path, default: Totals()].logical += size
                            directoryTotals[directory.path, default: Totals()].allocated += allocated
                            shouldCancel = cancelAfter.map { result.files >= $0 } ?? false
                            lock.unlock()
                        }
                        if shouldCancel { queue.cancel() }
                    }
                }
            }
        }
        if local {
            lock.lock()
            result.files += partial.files
            result.directories += partial.directories
            result.logical += partial.logical
            result.allocated += partial.allocated
            result.omitted += partial.omitted
            for (path, bytes) in partialTotals {
                directoryTotals[path, default: Totals()].logical += bytes.logical
                directoryTotals[path, default: Totals()].allocated += bytes.allocated
            }
            lock.unlock()
        }
    }
    result.cancelled = queue.cancelled
    if !calculateTotals { return result }
    var remainingChildren: [String: Int] = [:]
    for directory in directoryTotals.keys where directory != root.path {
        let parent = URL(fileURLWithPath: directory, isDirectory: true).deletingLastPathComponent().path
        remainingChildren[parent, default: 0] += 1
    }
    var ready = directoryTotals.keys.filter { remainingChildren[$0, default: 0] == 0 }
    while let directory = ready.popLast() {
        guard directory != root.path else { continue }
        let parent = URL(fileURLWithPath: directory, isDirectory: true).deletingLastPathComponent().path
        let child = directoryTotals[directory] ?? Totals()
        directoryTotals[parent, default: Totals()].logical += child.logical
        directoryTotals[parent, default: Totals()].allocated += child.allocated
        remainingChildren[parent, default: 0] -= 1
        if remainingChildren[parent] == 0 { ready.append(parent) }
    }
    if manifest { result.folders = directoryTotals }
    return result
}

private func scanProduction(root: URL, manifest: Bool, excluded: String?,
                            useRust: Bool, helper: URL?, navigationBenchmark: Bool) -> Output {
    let report = FileScanner.scan(ScanRequest(category: .space, root: root,
                                              excludedPaths: excluded.map { [$0] } ?? [],
                                              useRustSpaceScanner: useRust, rustHelperURL: helper))
    if navigationBenchmark, let tree = report.spaceTree {
        // Deliberately materialize the old flat list only for this comparison.
        let flat = report.spaceItems
        let targets = [root, root.appendingPathComponent("Library", isDirectory: true)]
            .filter { !tree.children(of: $0).isEmpty }
        let rounds = 10
        var flatCount = 0
        let flatStart = ProcessInfo.processInfo.systemUptime
        for _ in 0..<rounds {
            for folder in targets {
                flatCount += flat.filter { $0.parent.path == folder.path }.count
            }
        }
        let flatSeconds = ProcessInfo.processInfo.systemUptime - flatStart
        var indexedCount = 0
        let indexedStart = ProcessInfo.processInfo.systemUptime
        for _ in 0..<rounds {
            for folder in targets { indexedCount += tree.children(of: folder).count }
        }
        let indexedSeconds = ProcessInfo.processInfo.systemUptime - indexedStart
        precondition(flatCount == indexedCount)
        fputs(String(format: "navigation: %d lookups; flat %.3fs; indexed %.3fs; items %d\n",
                     rounds * targets.count, flatSeconds, indexedSeconds, flatCount), stderr)
    }
    var folders: [String: Totals] = [:]
    let directoryCount: Int
    if let tree = report.spaceTree {
        directoryCount = tree.directoryCount
        if manifest {
            tree.forEachDirectory { url, logical, allocated in
                folders[url.path] = Totals(logical: logical, allocated: allocated)
            }
        }
    } else {
        for folder in report.spaceItems where folder.isFolder {
            folders[folder.url.path] = Totals(logical: folder.bytes, allocated: folder.allocatedBytes ?? 0)
        }
        directoryCount = folders.count + 1
    }
    if manifest {
        folders[root.path] = Totals(logical: report.scannedBytes,
                                    allocated: report.scannedAllocatedBytes ?? 0)
    }
    return Output(files: report.scannedFileCount, directories: directoryCount,
                  logical: report.scannedBytes, allocated: report.scannedAllocatedBytes ?? 0,
                  omitted: report.omittedCount, cancelled: report.cancelled,
                  folders: manifest ? folders : nil)
}

let arguments = CommandLine.arguments
guard arguments.count >= 4, let workers = Int(arguments[3]), [1, 4, 6, 8].contains(workers),
      ["matched", "matched-local", "production", "production-rust"].contains(arguments[1]) else {
    fputs("usage: ScanBenchmark matched|matched-local|production|production-rust ROOT 1|4|6|8 [--manifest] [--navigation-benchmark] [--no-totals] [--check-cloud] [--prefetch-cloud] [--filemanager-cloud] [--nsurl-cloud] [--exclude PATH] [--helper PATH]\n", stderr)
    exit(2)
}
let root = URL(fileURLWithPath: arguments[2]).resolvingSymlinksInPath().standardizedFileURL
let manifest = arguments.contains("--manifest")
let calculateTotals = !arguments.contains("--no-totals")
let checkCloud = arguments.contains("--check-cloud")
let prefetchCloud = arguments.contains("--prefetch-cloud")
let useFileManagerCloudCheck = arguments.contains("--filemanager-cloud")
let useNSURLCloudCheck = arguments.contains("--nsurl-cloud")
if manifest && !calculateTotals {
    fputs("--manifest requires directory totals\n", stderr)
    exit(2)
}
if !calculateTotals && ["production", "production-rust"].contains(arguments[1]) {
    fputs("--no-totals is only available for matched traversals\n", stderr)
    exit(2)
}
if checkCloud && ["production", "production-rust"].contains(arguments[1]) {
    fputs("--check-cloud is only available for matched traversals\n", stderr)
    exit(2)
}
if prefetchCloud && !checkCloud {
    fputs("--prefetch-cloud requires --check-cloud\n", stderr)
    exit(2)
}
if useFileManagerCloudCheck && !checkCloud {
    fputs("--filemanager-cloud requires --check-cloud\n", stderr)
    exit(2)
}
if useNSURLCloudCheck && !checkCloud {
    fputs("--nsurl-cloud requires --check-cloud\n", stderr)
    exit(2)
}
if useFileManagerCloudCheck && useNSURLCloudCheck {
    fputs("choose one cloud-check implementation\n", stderr)
    exit(2)
}
let cancelAfter = arguments.firstIndex(of: "--cancel-after").flatMap { index in
    arguments.indices.contains(index + 1) ? Int(arguments[index + 1]) : nil
}
let excluded = arguments.firstIndex(of: "--exclude").flatMap { index in
    arguments.indices.contains(index + 1) ? URL(fileURLWithPath: arguments[index + 1]).resolvingSymlinksInPath().standardizedFileURL.path : nil
}
let helper = arguments.firstIndex(of: "--helper").flatMap { index in
    arguments.indices.contains(index + 1) ? URL(fileURLWithPath: arguments[index + 1]) : nil
}
private let output = ["production", "production-rust"].contains(arguments[1]) ?
    scanProduction(root: root, manifest: manifest, excluded: excluded,
                   useRust: arguments[1] == "production-rust", helper: helper,
                   navigationBenchmark: arguments.contains("--navigation-benchmark")) :
    scanMatched(root: root, workers: workers, cancelAfter: cancelAfter, manifest: manifest,
                excluded: excluded, local: arguments[1] == "matched-local",
                calculateTotals: calculateTotals, checkCloud: checkCloud,
                prefetchCloud: prefetchCloud, useFileManagerCloudCheck: useFileManagerCloudCheck,
                useNSURLCloudCheck: useNSURLCloudCheck)
let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys]
do {
    let data = try encoder.encode(output)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([10]))
} catch {
    fputs("cannot encode results: \(error)\n", stderr)
    exit(1)
}
