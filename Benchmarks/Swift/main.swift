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

private func scanMatched(root: URL, workers: Int, cancelAfter: Int?, manifest: Bool,
                         excluded: String?) -> Output {
    guard let rootInfo = metadata(root), (rootInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else {
        return Output(omitted: 1)
    }
    let queue = WorkQueue(root: root)
    let lock = NSLock()
    var result = Output(directories: 1)
    var directoryTotals: [String: Totals] = [root.path: Totals()]
    DispatchQueue.concurrentPerform(iterations: workers) { _ in
        let manager = FileManager()
        while let directory = queue.next() {
            autoreleasepool {
                defer { queue.finished() }
                let children: [URL]
                do {
                    children = try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                } catch {
                    lock.lock(); result.omitted += 1; lock.unlock()
                    return
                }
                for child in children where !queue.cancelled {
                    let url = directory.appendingPathComponent(child.lastPathComponent)
                    if url.lastPathComponent == ".Trash" { continue }
                    if let excluded, url.path == excluded || url.path.hasPrefix(excluded + "/") { continue }
                    guard let info = metadata(url) else {
                        lock.lock(); result.omitted += 1; lock.unlock()
                        continue
                    }
                    if info.st_dev != rootInfo.st_dev ||
                        (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFLNK) { continue }
                    if (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) {
                        lock.lock()
                        result.directories += 1
                        directoryTotals[url.path] = Totals()
                        lock.unlock()
                        queue.add(url)
                    } else {
                        let size = Int64(info.st_size)
                        let allocated = Int64(info.st_blocks) * 512
                        lock.lock()
                        result.files += 1
                        result.logical += size
                        result.allocated += allocated
                        directoryTotals[directory.path, default: Totals()].logical += size
                        directoryTotals[directory.path, default: Totals()].allocated += allocated
                        let shouldCancel = cancelAfter.map { result.files >= $0 } ?? false
                        lock.unlock()
                        if shouldCancel { queue.cancel() }
                    }
                }
            }
        }
    }
    result.cancelled = queue.cancelled
    let directories = directoryTotals.keys.sorted {
        let left = $0.split(separator: "/").count
        let right = $1.split(separator: "/").count
        return left == right ? $0 < $1 : left > right
    }
    for directory in directories where directory != root.path {
        let parent = URL(fileURLWithPath: directory).deletingLastPathComponent().path
        let child = directoryTotals[directory] ?? Totals()
        directoryTotals[parent, default: Totals()].logical += child.logical
        directoryTotals[parent, default: Totals()].allocated += child.allocated
    }
    if manifest { result.folders = directoryTotals }
    return result
}

private func scanProduction(root: URL, manifest: Bool, excluded: String?,
                            useRust: Bool, helper: URL?) -> Output {
    let report = FileScanner.scan(ScanRequest(category: .space, root: root,
                                              excludedPaths: excluded.map { [$0] } ?? [],
                                              useRustSpaceScanner: useRust, rustHelperURL: helper))
    var folders: [String: Totals] = [:]
    for folder in report.spaceItems where folder.isFolder {
        folders[folder.url.path] = Totals(logical: folder.bytes, allocated: folder.allocatedBytes ?? 0)
    }
    folders[root.path] = Totals(logical: report.scannedBytes,
                                allocated: report.scannedAllocatedBytes ?? 0)
    return Output(files: report.scannedFileCount, directories: folders.count,
                  logical: report.scannedBytes, allocated: report.scannedAllocatedBytes ?? 0,
                  omitted: report.omittedCount, cancelled: report.cancelled,
                  folders: manifest ? folders : nil)
}

let arguments = CommandLine.arguments
guard arguments.count >= 4, let workers = Int(arguments[3]), [1, 4, 8].contains(workers),
      ["matched", "production", "production-rust"].contains(arguments[1]) else {
    fputs("usage: ScanBenchmark matched|production|production-rust ROOT 1|4|8 [--manifest] [--exclude PATH] [--helper PATH]\n", stderr)
    exit(2)
}
let root = URL(fileURLWithPath: arguments[2]).resolvingSymlinksInPath().standardizedFileURL
let manifest = arguments.contains("--manifest")
let cancelAfter = arguments.firstIndex(of: "--cancel-after").flatMap { index in
    arguments.indices.contains(index + 1) ? Int(arguments[index + 1]) : nil
}
let excluded = arguments.firstIndex(of: "--exclude").flatMap { index in
    arguments.indices.contains(index + 1) ? URL(fileURLWithPath: arguments[index + 1]).resolvingSymlinksInPath().standardizedFileURL.path : nil
}
let helper = arguments.firstIndex(of: "--helper").flatMap { index in
    arguments.indices.contains(index + 1) ? URL(fileURLWithPath: arguments[index + 1]) : nil
}
private let output = arguments[1] != "matched" ?
    scanProduction(root: root, manifest: manifest, excluded: excluded,
                   useRust: arguments[1] == "production-rust", helper: helper) :
    scanMatched(root: root, workers: workers, cancelAfter: cancelAfter, manifest: manifest,
                excluded: excluded)
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
