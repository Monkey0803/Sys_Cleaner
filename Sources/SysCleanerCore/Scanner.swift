import AppKit
import CryptoKit
import Foundation

public final class ScanControl: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    private let onProgress: (@Sendable (ScanProgress) -> Void)?
    private var stage: ScanStage = .discovering
    private var processedFiles = 0
    private var processedDirectories = 0
    private var processedBytes: Int64 = 0
    private var lastPublished = 0.0
    private var omitted = 0
    private var cancellationHandler: (() -> Void)?

    public init(onProgress: (@Sendable (ScanProgress) -> Void)? = nil) {
        self.onProgress = onProgress
    }
    public func cancel() {
        lock.lock()
        stopped = true
        let handler = cancellationHandler
        lock.unlock()
        handler?()
    }
    func setCancellationHandler(_ handler: (() -> Void)?) {
        lock.lock()
        cancellationHandler = handler
        let shouldCancel = stopped && handler != nil
        lock.unlock()
        if shouldCancel { handler?() }
    }
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    public var omittedCount: Int { lock.lock(); defer { lock.unlock() }; return omitted }
    public func recordOmitted(_ count: Int = 1) {
        lock.lock(); omitted += max(0, count); lock.unlock()
    }

    public func begin(_ stage: ScanStage, path: URL) {
        lock.lock()
        self.stage = stage
        processedFiles = 0
        processedDirectories = 0
        processedBytes = 0
        lastPublished = ProcessInfo.processInfo.systemUptime
        let snapshot = progress(path: path.path)
        lock.unlock()
        onProgress?(snapshot)
    }

    public func visited(_ path: URL, bytes: Int64? = nil) {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        if let bytes {
            processedFiles += 1
            processedBytes += bytes
        } else {
            processedDirectories += 1
        }
        let now = ProcessInfo.processInfo.systemUptime
        let shouldPublish = now - lastPublished >= 0.2
        if shouldPublish { lastPublished = now }
        let snapshot = shouldPublish ? progress(path: path.path) : nil
        lock.unlock()
        if let snapshot { onProgress?(snapshot) }
    }

    private func progress(path: String) -> ScanProgress {
        ScanProgress(stage: stage, processedFiles: processedFiles,
                     processedDirectories: processedDirectories,
                     processedBytes: processedBytes, currentPath: path)
    }
}

private final class DirectoryWorkQueue: @unchecked Sendable {
    private let condition = NSCondition()
    private var pending: [URL]
    private var outstanding = 1
    private let control: ScanControl

    init(root: URL, control: ScanControl) {
        pending = [root]
        self.control = control
    }

    func next() -> URL? {
        condition.lock()
        defer { condition.unlock() }
        while pending.isEmpty && outstanding > 0 && !control.isCancelled {
            condition.wait(until: Date().addingTimeInterval(0.05))
        }
        return control.isCancelled ? nil : pending.popLast()
    }

    func add(_ directory: URL) {
        condition.lock()
        pending.append(directory)
        outstanding += 1
        condition.signal()
        condition.unlock()
    }

    func finished() {
        condition.lock()
        outstanding -= 1
        if outstanding == 0 { condition.broadcast() }
        condition.unlock()
    }
}

private struct SpaceDirectoryUsage {
    var index = -1
    var logical: Int64 = 0
    var allocated: Int64 = 0
    var otherLogical: Int64 = 0
    var otherAllocated: Int64 = 0
    var remainingChildren = 0

    mutating func addFile(logical: Int64, allocated: Int64, isOther: Bool) {
        self.logical += logical
        self.allocated += allocated
        if isOther {
            otherLogical += logical
            otherAllocated += allocated
        }
    }

    mutating func addChild(_ child: SpaceDirectoryUsage) {
        logical += child.logical
        allocated += child.allocated
        remainingChildren -= 1
    }

    mutating func mergeAlias(_ alias: SpaceDirectoryUsage) {
        logical += alias.logical
        allocated += alias.allocated
        otherLogical += alias.otherLogical
        otherAllocated += alias.otherAllocated
    }
}

public enum FileScanner {
    public static func scan(_ request: ScanRequest, control: ScanControl = ScanControl()) -> ScanReport {
        var warnings: [String] = []
        var entries: [ScanEntry] = []
        let root = request.root.resolvingSymlinksInPath().standardizedFileURL
        control.begin(request.category == .uninstall ? .measuringApps : .discovering, path: root)
        switch request.category {
        case .space:
            return scanSpace(root: root, control: control, excludedPaths: request.excludedPaths,
                             useRust: request.useRustSpaceScanner, helperURL: request.rustHelperURL)
        case .large:
            let oldest = Date().addingTimeInterval(-Double(request.olderThanDays) * 86_400)
            walkFiles(under: root, control: control, warnings: &warnings,
                      parallel: true, excludedPaths: request.excludedPaths,
                      minimumFileBytes: request.minimumBytes) { url, stamp in
                guard stamp.size >= request.minimumBytes,
                      request.olderThanDays == 0 || Date(timeIntervalSince1970: Double(stamp.modifiedSeconds)) <= oldest
                else { return }
                entries.append(ScanEntry(url: url, scope: root, category: .large, stamp: stamp,
                                         estimatedBytes: stamp.size, note: "reviewLarge",
                                         canDelete: FileSafety.isSafeLocation(url, scope: root, category: .large)))
            }
        case .duplicates:
            var candidates: [(URL, FileStamp)] = []
            var limited = false
            walkFiles(under: root, control: control, warnings: &warnings,
                      parallel: true, excludedPaths: request.excludedPaths) { url, stamp in
                guard stamp.size > 0 else { return }
                if candidates.count < 100_000 { candidates.append((url, stamp)) }
                else { limited = true; control.recordOmitted() }
            }
            if limited { appendWarning("duplicateLimit", to: &warnings) }
            control.begin(.comparing, path: root)
            entries = findDuplicates(files: candidates, root: root, control: control,
                                     warnings: &warnings)
                .filter { entry in
                    guard let hash = entry.duplicateGroup else { return true }
                    return !request.ignoredDuplicateHashes.contains(hash)
                }
        case .systemCache:
            return scanCaches(category: .systemCache, locations: systemCacheLocations(), control: control,
                              excludedPaths: request.excludedPaths)
        case .developerCache:
            return XcodeStorage.derivedDataEntries(
                roots: [XcodeStorage.defaultDerivedDataRoot] + request.derivedDataRoots,
                excludedPaths: request.excludedPaths, control: control)
        case .uninstall:
            entries = scanApplications(control: control, excludedPaths: request.excludedPaths)
        case .orphans:
            entries = scanOrphanCandidates(control: control, warnings: &warnings,
                                           excludedPaths: request.excludedPaths)
        }
        if control.omittedCount > 0 && warnings.isEmpty {
            appendWarning("scanIncomplete", to: &warnings)
        }
        return ScanReport(entries: entries.sorted { $0.estimatedBytes > $1.estimatedBytes },
                          warnings: warnings, cancelled: control.isCancelled,
                          omittedCount: control.omittedCount)
    }

    private static func collectFiles(under root: URL, control: ScanControl, warnings: inout [String],
                                     includeApps: Bool = false) -> [(URL, FileStamp)] {
        var files: [(URL, FileStamp)] = []
        walkFiles(under: root, control: control, warnings: &warnings, includeApps: includeApps) { url, stamp in
            files.append((url, stamp))
        }
        return files
    }

    static func scanCaches(category: ScanCategory, locations: [URL], control: ScanControl = ScanControl(),
                           excludedPaths: [String] = []) -> ScanReport {
        precondition(category == .systemCache || category == .developerCache)
        var warnings: [String] = []
        var eligibleCount = 0
        var largest = LargestEntries(limit: 2_000)
        for location in locations where !control.isCancelled {
            walkFiles(under: location, control: control, warnings: &warnings,
                      checkCloud: false, parallel: true, excludedPaths: excludedPaths) { url, stamp in
                eligibleCount += 1
                largest.insert(ScanEntry(url: url, scope: location, category: category,
                                         stamp: stamp, estimatedBytes: stamp.size,
                                         note: location.lastPathComponent))
            }
        }
        if eligibleCount > 2_000 {
            appendWarning("listLimited", to: &warnings)
            control.recordOmitted(eligibleCount - 2_000)
        }
        return ScanReport(entries: largest.entries.sorted { $0.estimatedBytes > $1.estimatedBytes },
                          warnings: warnings, cancelled: control.isCancelled,
                          omittedCount: control.omittedCount)
    }

    private static func walkFiles(under root: URL, control: ScanControl, warnings: inout [String],
                                  includeApps: Bool = false, includeHardLinks: Bool = false,
                                  checkCloud: Bool = true, parallel: Bool = false,
                                  workers: Int = 4,
                                  excludedPaths: [String] = [],
                                  minimumFileBytes: Int64 = 0,
                                  onDirectory: @escaping (URL) -> Void = { _ in },
                                  onFile: @escaping (URL, FileStamp) -> Void) {
        guard !isExcluded(root, paths: excludedPaths) else { return }
        guard let rootInfo = FileSafety.metadata(at: root), rootInfo.isDirectory else {
            appendWarning("Cannot read \(root.path)", to: &warnings)
            control.recordOmitted()
            return
        }
        onDirectory(root)
        control.visited(root)
        if !parallel {
            var stack = [root]
            while let directory = stack.popLast(), !control.isCancelled {
                autoreleasepool {
                    let children: [URL]
                    do {
                        children = try FileManager.default.contentsOfDirectory(at: directory,
                                                                              includingPropertiesForKeys: nil)
                    } catch {
                        if warnings.count < 50 {
                            appendWarning("Cannot read \(directory.path): \(error.localizedDescription)", to: &warnings)
                        }
                        control.recordOmitted()
                        return
                    }
                    let usesRequestedPath = children.first.map {
                        $0.deletingLastPathComponent().path == directory.path
                    } ?? true
                    for child in children where !control.isCancelled {
                        let candidate = usesRequestedPath ? child :
                            directory.appendingPathComponent(child.lastPathComponent, isDirectory: false)
                        if candidate.lastPathComponent == ".Trash" || isExcluded(candidate, paths: excludedPaths) { continue }
                        guard let info = FileSafety.metadata(at: candidate), info.stamp.device == rootInfo.stamp.device else { continue }
                        let url = info.isDirectory
                            ? directory.appendingPathComponent(child.lastPathComponent, isDirectory: true) : candidate
                        if !info.isDirectory && (info.stamp.linkCount == 1 || includeHardLinks)
                            && info.stamp.size < minimumFileBytes {
                            control.visited(url, bytes: info.stamp.size)
                            continue
                        }
                        if checkCloud && FileSafety.isCloudPlaceholder(url) { continue }
                        if info.isDirectory {
                            if url.pathExtension == "app" && !includeApps { continue }
                            onDirectory(url)
                            control.visited(url)
                            stack.append(url)
                        } else if info.stamp.linkCount == 1 || includeHardLinks {
                            onFile(url, info.stamp)
                            control.visited(url, bytes: info.stamp.size)
                        }
                    }
                }
            }
            return
        }
        let work = DirectoryWorkQueue(root: root, control: control)
        let lock = NSLock()
        var localWarnings: [String] = []
        DispatchQueue.concurrentPerform(iterations: workers) { _ in
            let manager = FileManager()
            while let directory = work.next() {
                autoreleasepool {
                    defer { work.finished() }
                    let children: [URL]
                    do {
                        children = try manager.contentsOfDirectory(at: directory,
                                                                   includingPropertiesForKeys: nil)
                    } catch {
                        lock.lock()
                        if localWarnings.count < 50 {
                            appendWarning("Cannot read \(directory.path): \(error.localizedDescription)", to: &localWarnings)
                        }
                        control.recordOmitted()
                        lock.unlock()
                        return
                    }
                    let usesRequestedPath = children.first.map {
                        $0.deletingLastPathComponent().path == directory.path
                    } ?? true
                    for child in children where !control.isCancelled {
                        // FileManager may return /private/tmp for a directory requested through /tmp.
                        let candidate = usesRequestedPath ? child :
                            directory.appendingPathComponent(child.lastPathComponent, isDirectory: false)
                        if candidate.lastPathComponent == ".Trash" || isExcluded(candidate, paths: excludedPaths) { continue }
                        guard let info = FileSafety.metadata(at: candidate),
                              info.stamp.device == rootInfo.stamp.device else { continue }
                        let url = info.isDirectory
                            ? directory.appendingPathComponent(child.lastPathComponent, isDirectory: true) : candidate
                        if !info.isDirectory && (info.stamp.linkCount == 1 || includeHardLinks)
                            && info.stamp.size < minimumFileBytes {
                            control.visited(url, bytes: info.stamp.size)
                            continue
                        }
                        if checkCloud && FileSafety.isCloudPlaceholder(url) { continue }
                        if info.isDirectory {
                            if url.pathExtension == "app" && !includeApps { continue }
                            lock.lock()
                            onDirectory(url)
                            control.visited(url)
                            lock.unlock()
                            work.add(url)
                        } else if info.stamp.linkCount == 1 || includeHardLinks {
                            lock.lock()
                            onFile(url, info.stamp)
                            control.visited(url, bytes: info.stamp.size)
                            lock.unlock()
                        }
                    }
                }
            }
        }
        for warning in localWarnings { appendWarning(warning, to: &warnings) }
    }

    private static func scanSpace(root: URL, control: ScanControl,
                                  excludedPaths: [String], useRust: Bool,
                                  helperURL: URL?) -> ScanReport {
        var warnings: [String] = []
        var usage: [URL: SpaceDirectoryUsage] = [:]
        var directories: [URL] = []
        var visibleFiles: [SpaceItem] = []
        var zeroFiles: [SpaceItem] = []
        var count = 0
        var total: Int64 = 0
        var allocatedTotal: Int64 = 0
        var hiddenIndividualCount = 0
        let recordFile: (URL, Int64, Int64?) -> Void = { url, bytes, allocatedBytes in
            count += 1
            total += bytes
            allocatedTotal += allocatedBytes ?? 0
            let parent = url.deletingLastPathComponent()
            let isOther: Bool
            if bytes == 0 && zeroFiles.count < 10_000 {
                zeroFiles.append(SpaceItem(url: url, parent: parent, bytes: 0, isFolder: false,
                                           allocatedBytes: allocatedBytes))
                isOther = false
            } else if bytes >= 1_048_576 && visibleFiles.count < 10_000 {
                visibleFiles.append(SpaceItem(url: url, parent: parent, bytes: bytes, isFolder: false,
                                              allocatedBytes: allocatedBytes))
                isOther = false
            } else {
                isOther = true
                if bytes == 0 || bytes >= 1_048_576 { hiddenIndividualCount += 1 }
            }
            usage[parent, default: SpaceDirectoryUsage()].addFile(
                logical: bytes, allocated: allocatedBytes ?? 0, isOther: isOther)
        }
        var usedRust = false
        if useRust {
            switch RustSpaceScanner.read(root: root, excludedPaths: excludedPaths, control: control,
                                         helperOverride: helperURL) {
            case .completed(let listing):
                usedRust = true
                var cloudDirectories: [String] = []
                for path in listing.directories.sorted(by: { $0.split(separator: "/").count < $1.split(separator: "/").count })
                    where !control.isCancelled {
                    guard let url = listing.path(path, rebasedTo: root, isDirectory: true) else { continue }
                    if cloudDirectories.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { continue }
                    if FileSafety.isCloudPlaceholder(url) {
                        cloudDirectories.append(path)
                        continue
                    }
                    directories.append(url)
                    usage[url, default: SpaceDirectoryUsage()].index = directories.count - 1
                    control.visited(url)
                }
                let blockedDirectories = cloudDirectories
                let acceptedLock = NSLock()
                var acceptedFiles: [(URL, RustSpaceListing.File)] = []
                DispatchQueue.concurrentPerform(iterations: 4) { worker in
                    var local: [(URL, RustSpaceListing.File)] = []
                    for index in stride(from: worker, to: listing.files.count, by: 4) where !control.isCancelled {
                        autoreleasepool {
                            let file = listing.files[index]
                            if blockedDirectories.contains(where: { file.path.hasPrefix($0 + "/") }) { return }
                            guard let url = listing.path(file.path, rebasedTo: root),
                                  !FileSafety.isCloudPlaceholder(url) else { return }
                            local.append((url, file))
                        }
                    }
                    acceptedLock.lock()
                    acceptedFiles.append(contentsOf: local)
                    acceptedLock.unlock()
                }
                for (url, file) in acceptedFiles where !control.isCancelled {
                    recordFile(url, file.logical, file.allocated)
                    control.visited(url, bytes: file.logical)
                }
                for path in listing.omitted where !control.isCancelled {
                    if cloudDirectories.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { continue }
                    appendWarning("Cannot read \(path)", to: &warnings)
                    control.recordOmitted()
                }
            case .cancelled:
                return ScanReport(entries: [], warnings: [], cancelled: true)
            case .unavailable:
                break
            }
        }
        if !usedRust {
            walkFiles(under: root, control: control, warnings: &warnings,
                      includeApps: true, includeHardLinks: true, parallel: true,
                      workers: 6,
                      excludedPaths: excludedPaths,
                      onDirectory: { directory in
                          directories.append(directory)
                          usage[directory, default: SpaceDirectoryUsage()].index = directories.count - 1
                      }) { url, stamp in
                recordFile(url, stamp.size, stamp.allocatedBytes)
            }
        }
        // Some FileManager paths differ only in URL directory metadata (notably /tmp aliases).
        // Fold such file totals into the discovered directory before propagating upward.
        let aliases = usage.filter { $0.value.index < 0 }
        if !aliases.isEmpty {
            var byPath: [String: Int] = [:]
            if aliases.count > 8 {
                for (index, directory) in directories.enumerated() {
                    byPath[directory.path] = index
                }
            }
            for (url, alias) in aliases {
                let canonical = url.resolvingSymlinksInPath().path
                let index = aliases.count > 8 ? byPath[url.path] ?? byPath[canonical] :
                    directories.firstIndex(where: { $0.path == url.path || $0.path == canonical })
                if let index {
                    usage[directories[index], default: SpaceDirectoryUsage()].mergeAlias(alias)
                    usage.removeValue(forKey: url)
                }
            }
        }
        // Workers discover siblings in an arbitrary order. Propagate totals only after
        // every child directory has contributed to its parent.
        for directory in directories where directory != root {
            usage[directory.deletingLastPathComponent(), default: SpaceDirectoryUsage()].remainingChildren += 1
        }
        var ready = directories.filter { usage[$0]?.remainingChildren == 0 }
        while let directory = ready.popLast() {
            guard directory != root else { continue }
            let parent = directory.deletingLastPathComponent()
            let child = usage[directory, default: SpaceDirectoryUsage()]
            usage[parent, default: SpaceDirectoryUsage()].addChild(child)
            if usage[parent]?.remainingChildren == 0 { ready.append(parent) }
        }
        func directoryIndex(for url: URL) -> Int {
            if let index = usage[url]?.index, index >= 0 { return index }
            if url.path == root.path || url.resolvingSymlinksInPath().path == root.path { return 0 }
            return directories.firstIndex(where: { $0.path == url.path }) ?? 0
        }
        let nodes = directories.enumerated().map { index, url in
            let size = usage[url, default: SpaceDirectoryUsage()]
            let parentIndex = index == 0 ? 0 : directoryIndex(for: url.deletingLastPathComponent())
            return SpaceTree.Directory(name: url.lastPathComponent, parentIndex: parentIndex,
                                       bytes: size.logical, allocatedBytes: size.allocated,
                                       otherBytes: size.otherLogical,
                                       otherAllocatedBytes: size.otherAllocated)
        }
        let files = visibleFiles + zeroFiles
        let fileParents = files.map { directoryIndex(for: $0.parent) }
        let tree = SpaceTree(root: root, directories: nodes, files: files, fileParents: fileParents)
        if hiddenIndividualCount > 0 {
            appendWarning("spaceLimit", to: &warnings)
            control.recordOmitted(hiddenIndividualCount)
        }
        return ScanReport(entries: [], warnings: warnings, cancelled: control.isCancelled,
                          scannedFileCount: count, scannedBytes: total,
                          scannedAllocatedBytes: allocatedTotal,
                          omittedCount: control.omittedCount, spaceTree: tree)
    }

    private static func findDuplicates(files: [(URL, FileStamp)], root: URL, control: ScanControl,
                                       warnings: inout [String]) -> [ScanEntry] {
        let sized = Dictionary(grouping: files.filter { $0.1.size > 0 && $0.1.linkCount == 1 },
                               by: { $0.1.size })
        var fullCandidates: [(URL, FileStamp)] = []
        var partialCandidates: [(URL, FileStamp)] = []
        for (size, peers) in sized where peers.count > 1 {
            if size <= 16_384 { fullCandidates.append(contentsOf: peers) }
            else { partialCandidates.append(contentsOf: peers) }
        }

        // A sample hash only removes candidates; a full hash is still required for every shown group.
        let partialDigests = parallelDigests(partialCandidates, control: control, partial: true)
        var partialGroups: [PartialKey: [(URL, FileStamp)]] = [:]
        for (index, candidate) in partialCandidates.enumerated() where !control.isCancelled {
            let (url, stamp) = candidate
            if let digest = partialDigests[index], FileSafety.stamp(at: url) == stamp {
                partialGroups[PartialKey(size: stamp.size, digest: digest), default: []].append(candidate)
            } else {
                appendWarning("Changed or unreadable: \(url.path)", to: &warnings)
            }
        }
        for peers in partialGroups.values where peers.count > 1 {
            fullCandidates.append(contentsOf: peers)
        }

        let fullDigests = parallelDigests(fullCandidates, control: control, partial: false)
        var hashes: [PartialKey: [(URL, FileStamp)]] = [:]
        for (index, candidate) in fullCandidates.enumerated() where !control.isCancelled {
            let (url, stamp) = candidate
            if let digest = fullDigests[index], FileSafety.stamp(at: url) == stamp {
                hashes[PartialKey(size: stamp.size, digest: digest), default: []].append(candidate)
            } else {
                appendWarning("Changed or unreadable: \(url.path)", to: &warnings)
            }
        }

        var results: [ScanEntry] = []
        for (key, group) in hashes where group.count > 1 && !control.isCancelled {
            let sorted = group.sorted { $0.0.path < $1.0.path }
            for (index, element) in sorted.enumerated() {
                results.append(ScanEntry(url: element.0, scope: root, category: .duplicates,
                                         stamp: element.1, estimatedBytes: element.1.size,
                                         risk: .review, note: index == 0 ? "keepOriginal" : "duplicateCopy",
                                         duplicateGroup: key.digest,
                                         canDelete: index != 0 &&
                                            FileSafety.isSafeLocation(element.0, scope: root, category: .duplicates)))
            }
        }
        return results
    }

    private struct PartialKey: Hashable {
        let size: Int64
        let digest: String
    }

    private static func parallelDigests(_ files: [(URL, FileStamp)], control: ScanControl,
                                        partial: Bool) -> [String?] {
        guard !files.isEmpty else { return [] }
        // Keep the number of simultaneously open files bounded on large scans.
        let lock = NSLock()
        var nextIndex = 0
        var digests = [String?](repeating: nil, count: files.count)
        let workers = min(4, files.count)
        DispatchQueue.concurrentPerform(iterations: workers) { _ in
            while !control.isCancelled {
                lock.lock()
                let index = nextIndex
                nextIndex += 1
                lock.unlock()
                guard index < files.count else { break }
                let (url, stamp) = files[index]
                let digest = autoreleasepool {
                    partial ? partialHashFile(url, size: stamp.size, control: control) :
                              hashFile(url, control: control)
                }
                lock.lock()
                digests[index] = digest
                lock.unlock()
                if !partial { control.visited(url, bytes: stamp.size) }
            }
        }
        return digests
    }

    private static func partialHashFile(_ url: URL, size: Int64, control: ScanControl) -> String? {
        guard !control.isCancelled, let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        do {
            var hasher = SHA256()
            let chunk = min(Int64(4_096), size)
            let first = try handle.read(upToCount: Int(chunk)) ?? Data()
            guard first.count == chunk, !control.isCancelled else { return nil }
            hasher.update(data: first)
            try handle.seek(toOffset: UInt64(size - chunk))
            let last = try handle.read(upToCount: Int(chunk)) ?? Data()
            guard last.count == chunk, !control.isCancelled else { return nil }
            hasher.update(data: last)
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        } catch { return nil }
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

    private static func scanApplications(control: ScanControl, excludedPaths: [String]) -> [ScanEntry] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let roots = [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")]
        return scanApplications(roots: roots, control: control, excludedPaths: excludedPaths)
    }

    static func scanApplications(roots: [URL], control: ScanControl = ScanControl(),
                                 excludedPaths: [String] = []) -> [ScanEntry] {
        var entries: [ScanEntry] = []
        for root in roots where !control.isCancelled {
            guard let apps = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
                if FileManager.default.fileExists(atPath: root.path) { control.recordOmitted() }
                continue
            }
            for app in apps where app.pathExtension.lowercased() == "app" && !control.isCancelled &&
                !isExcluded(app, paths: excludedPaths) {
                guard let identifier = Bundle(url: app)?.bundleIdentifier,
                      let stamp = FileSafety.stamp(at: app), FileSafety.isDirectory(app),
                      FileSafety.isSafeLocation(app, scope: root, category: .uninstall) else { continue }
                let running = FileSafety.isApplicationRunning(app, identifier: identifier)
                control.visited(app)
                entries.append(ScanEntry(url: app, scope: root, category: .uninstall, stamp: stamp,
                                         estimatedBytes: 0, sizeIsKnown: false,
                                         risk: running ? .protected : .review,
                                         note: running ? "appRunning" : identifier,
                                         isDirectory: true, canDelete: false))
            }
        }
        return entries
    }

    private static func scanOrphanCandidates(control: ScanControl, warnings: inout [String],
                                              excludedPaths: [String]) -> [ScanEntry] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let appRoots = [URL(fileURLWithPath: "/Applications"),
                        URL(fileURLWithPath: "/System/Applications"),
                        home.appendingPathComponent("Applications")]
        let priorOmissions = control.omittedCount
        var installed = installedApplicationIdentifiers(in: appRoots, control: control)
        if control.omittedCount > priorOmissions {
            appendWarning("installedAppsIncomplete", to: &warnings)
            return []
        }
        installed.formUnion(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
            .map { $0.lowercased() })
        let library = home.appendingPathComponent("Library")
        let folderNames = ["Application Support", "Caches", "Containers",
                           "HTTPStorages", "WebKit", "Application Scripts",
                           "Saved Application State"]
        return scanOrphanCandidates(roots: folderNames.map { library.appendingPathComponent($0) },
                                    installedIdentifiers: installed, control: control, warnings: &warnings,
                                    excludedPaths: excludedPaths)
    }

    static func installedApplicationIdentifiers(in roots: [URL], control: ScanControl = ScanControl()) -> Set<String> {
        var identifiers: Set<String> = []
        var pending = roots.map { ($0, 0) }
        while let (directory, depth) = pending.popLast(), !control.isCancelled {
            guard let children = try? FileManager.default.contentsOfDirectory(at: directory,
                                                                               includingPropertiesForKeys: nil) else {
                if FileManager.default.fileExists(atPath: directory.path) { control.recordOmitted() }
                continue
            }
            for child in children where !control.isCancelled {
                guard FileSafety.isDirectory(child) else { continue }
                if child.pathExtension.lowercased() == "app" {
                    collectBundleIdentifiers(in: child, into: &identifiers, control: control)
                } else if depth < 3 {
                    pending.append((child, depth + 1))
                }
            }
        }
        return identifiers
    }

    private static func collectBundleIdentifiers(in app: URL, into identifiers: inout Set<String>,
                                                 control: ScanControl) {
        if let identifier = Bundle(url: app)?.bundleIdentifier { identifiers.insert(identifier.lowercased()) }
        let locations = ["Contents/PlugIns", "Contents/XPCServices", "Contents/Library/LoginItems",
                         "Contents/Helpers", "Contents/Library/Spotlight", "Contents/Library/QuickLook"]
        let bundleExtensions: Set<String> = ["app", "appex", "xpc", "qlgenerator", "mdimporter"]
        for location in locations where !control.isCancelled {
            var pending = [(app.appendingPathComponent(location), 0)]
            while let (directory, depth) = pending.popLast(), !control.isCancelled {
                guard let children = try? FileManager.default.contentsOfDirectory(at: directory,
                                                                                   includingPropertiesForKeys: nil) else {
                    if FileManager.default.fileExists(atPath: directory.path) { control.recordOmitted() }
                    continue
                }
                for child in children where !control.isCancelled {
                    guard FileSafety.isDirectory(child) else { continue }
                    if bundleExtensions.contains(child.pathExtension.lowercased()) {
                        if let identifier = Bundle(url: child)?.bundleIdentifier {
                            identifiers.insert(identifier.lowercased())
                        }
                    } else if depth < 3 {
                        pending.append((child, depth + 1))
                    }
                }
            }
        }
    }

    static func belongsToInstalledApp(_ identifier: String, installedIdentifiers: Set<String>) -> Bool {
        let candidate = identifier.lowercased()
        return installedIdentifiers.contains { installed in
            let known = installed.lowercased()
            return candidate == known || candidate.hasPrefix(known + ".") || known.hasPrefix(candidate + ".")
        }
    }

    static func scanOrphanCandidates(roots: [URL], installedIdentifiers: Set<String>,
                                     control: ScanControl = ScanControl(),
                                     excludedPaths: [String] = []) -> [ScanEntry] {
        var warnings: [String] = []
        return scanOrphanCandidates(roots: roots, installedIdentifiers: installedIdentifiers,
                                    control: control, warnings: &warnings,
                                    excludedPaths: excludedPaths)
    }

    private static func scanOrphanCandidates(roots: [URL], installedIdentifiers: Set<String>,
                                             control: ScanControl, warnings: inout [String],
                                             excludedPaths: [String]) -> [ScanEntry] {
        var entries: [ScanEntry] = []
        for root in roots where !control.isCancelled {
            guard let children = try? FileManager.default.contentsOfDirectory(at: root,
                                                                               includingPropertiesForKeys: nil) else {
                if FileManager.default.fileExists(atPath: root.path) {
                    appendWarning("Cannot read \(root.path)", to: &warnings)
                    control.recordOmitted()
                }
                continue
            }
            for child in children where !control.isCancelled && !isExcluded(child, paths: excludedPaths) {
                let name = child.lastPathComponent
                let identifier: String
                if root.lastPathComponent == "Preferences" {
                    guard child.pathExtension == "plist" else { continue }
                    identifier = child.deletingPathExtension().lastPathComponent
                } else if root.lastPathComponent == "HTTPStorages" && name.hasSuffix(".binarycookies") {
                    identifier = String(name.dropLast(".binarycookies".count))
                } else if root.lastPathComponent == "Saved Application State" {
                    guard name.hasSuffix(".savedState") else { continue }
                    identifier = String(name.dropLast(".savedState".count))
                } else {
                    identifier = name
                }
                let pieces = identifier.split(separator: ".")
                guard pieces.count >= 3,
                      ["com", "org", "net", "io", "app", "dev"].contains(String(pieces[0]).lowercased()),
                      !identifier.hasPrefix("com.apple."),
                      !belongsToInstalledApp(identifier, installedIdentifiers: installedIdentifiers),
                      identifier.range(of: "^[A-Za-z][A-Za-z0-9-]*(\\.[A-Za-z0-9_-]+){2,}$",
                                       options: .regularExpression) != nil,
                      let info = FileSafety.metadata(at: child) else { continue }
                let measuredBytes: Int64?
                var measuredAllocatedBytes: Int64?
                if info.isDirectory {
                    var measurementWarnings: [String] = []
                    var bytes: Int64 = 0
                    var allocated: Int64 = 0
                    walkFiles(under: child, control: control, warnings: &measurementWarnings,
                              includeApps: true, includeHardLinks: true, parallel: true,
                              excludedPaths: excludedPaths) { _, stamp in
                        bytes += stamp.size
                        allocated += stamp.allocatedBytes ?? 0
                    }
                    warnings.append(contentsOf: measurementWarnings)
                    measuredBytes = measurementWarnings.isEmpty && !control.isCancelled &&
                        FileSafety.stamp(at: child) == info.stamp ? bytes : nil
                    measuredAllocatedBytes = measuredBytes == nil ? nil : allocated
                } else {
                    control.visited(child, bytes: info.stamp.size)
                    measuredBytes = info.stamp.size
                    measuredAllocatedBytes = info.stamp.allocatedBytes
                }
                entries.append(ScanEntry(url: child, scope: root, category: .orphans,
                                         stamp: info.stamp,
                                         estimatedBytes: measuredBytes ?? 0,
                                         allocatedBytes: measuredAllocatedBytes,
                                         sizeIsKnown: measuredBytes != nil,
                                         note: "orphanCandidate", isDirectory: info.isDirectory,
                                         canDelete: false))
            }
        }
        return entries
    }

    static func applicationBundleSize(_ app: URL, control: ScanControl = ScanControl()) -> Int64? {
        applicationBundleMetrics(app, control: control)?.logicalBytes
    }

    static func applicationBundleMetrics(_ app: URL, control: ScanControl = ScanControl())
        -> (logicalBytes: Int64, allocatedBytes: Int64)? {
        var warnings: [String] = []
        var bytes: Int64 = 0
        var allocated: Int64 = 0
        walkFiles(under: app, control: control, warnings: &warnings,
                  includeApps: true, checkCloud: false) { _, stamp in
            bytes += stamp.size
            allocated += stamp.allocatedBytes ?? 0
        }
        return warnings.isEmpty && !control.isCancelled ? (bytes, allocated) : nil
    }

    public static func prepareApplication(_ app: ScanEntry, control: ScanControl = ScanControl(),
                                          excludedPaths: [String] = []) -> ScanReport {
        control.begin(.reviewingApp, path: app.url)
        var warnings: [String] = []
        guard app.category == .uninstall, app.isDirectory,
              let identifier = Bundle(url: app.url)?.bundleIdentifier,
              FileSafety.stamp(at: app.url) == app.stamp,
              !FileSafety.isApplicationRunning(app.url, identifier: identifier),
              let signature = directorySignature(app.url, control: control) else {
            return ScanReport(entries: [], warnings: ["changedOrRunning"], cancelled: control.isCancelled)
        }
        var prepared = [ScanEntry(url: app.url, scope: app.scope, category: .uninstall,
                                  stamp: app.stamp, estimatedBytes: signature.bytes,
                                  allocatedBytes: signature.allocatedBytes,
                                  note: identifier, isDirectory: true, directorySignature: signature.digest)]
        let library = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library")
        let candidates = ["Application Support", "Caches", "Containers", "Logs", "HTTPStorages",
                          "WebKit", "Application Scripts"]
            .map { library.appendingPathComponent($0).appendingPathComponent(identifier) }
            + [library.appendingPathComponent("Saved Application State").appendingPathComponent(identifier + ".savedState")]
        for candidate in candidates where !control.isCancelled && !isExcluded(candidate, paths: excludedPaths) {
            guard FileSafety.isDirectory(candidate) else { continue }
            for (file, stamp) in collectFiles(under: candidate, control: control, warnings: &warnings) {
                guard stamp.linkCount == 1 else { continue }
                prepared.append(ScanEntry(url: file, scope: candidate, category: .uninstall,
                                          stamp: stamp, estimatedBytes: stamp.size, note: identifier))
            }
        }
        let exactFiles = [library.appendingPathComponent("Preferences/\(identifier).plist"),
                          library.appendingPathComponent("LaunchAgents/\(identifier).plist")]
        for file in exactFiles where !control.isCancelled {
            if isExcluded(file, paths: excludedPaths) { continue }
            guard let stamp = FileSafety.stamp(at: file), !FileSafety.isDirectory(file), stamp.linkCount == 1 else { continue }
            prepared.append(ScanEntry(url: file, scope: file.deletingLastPathComponent(), category: .uninstall,
                                      stamp: stamp, estimatedBytes: stamp.size, note: identifier))
        }
        return ScanReport(entries: prepared, warnings: warnings, cancelled: control.isCancelled)
    }

    public static func directorySignature(_ root: URL, control: ScanControl = ScanControl())
        -> (digest: String, bytes: Int64, allocatedBytes: Int64)? {
        guard FileSafety.isDirectory(root) else { return nil }
        var warnings: [String] = []
        let files = collectFiles(under: root, control: control, warnings: &warnings, includeApps: true)
        guard warnings.isEmpty, !control.isCancelled else { return nil }
        var hasher = SHA256()
        var total: Int64 = 0
        var allocated: Int64 = 0
        for (url, stamp) in files.sorted(by: { $0.0.path < $1.0.path }) {
            guard !control.isCancelled, FileSafety.stamp(at: url) == stamp else { return nil }
            total += stamp.size
            allocated += stamp.allocatedBytes ?? 0
            let part = "\(url.path.dropFirst(root.path.count))|\(stamp.device)|\(stamp.inode)|\(stamp.size)|\(stamp.modifiedSeconds)|\(stamp.modifiedNanoseconds)"
            hasher.update(data: Data(part.utf8))
        }
        return (hasher.finalize().map { String(format: "%02x", $0) }.joined(), total, allocated)
    }

    private static func appendWarning(_ message: String, to warnings: inout [String]) {
        if warnings.count < 50 { warnings.append(message) }
    }

    private static func isExcluded(_ url: URL, paths: [String]) -> Bool {
        guard !paths.isEmpty else { return false }
        let candidate = url.standardizedFileURL.path
        return paths.contains { path in candidate == path || candidate.hasPrefix(path + "/") }
    }
}

private struct LargestEntries {
    let limit: Int
    private(set) var entries: [ScanEntry] = []

    mutating func insert(_ entry: ScanEntry) {
        if entries.count < limit {
            entries.append(entry)
            siftUp(from: entries.count - 1)
        } else if let smallest = entries.first, isSmaller(smallest, than: entry) {
            entries[0] = entry
            siftDown(from: 0)
        }
    }

    private func isSmaller(_ lhs: ScanEntry, than rhs: ScanEntry) -> Bool {
        lhs.estimatedBytes == rhs.estimatedBytes ? lhs.url.path > rhs.url.path : lhs.estimatedBytes < rhs.estimatedBytes
    }

    private mutating func siftUp(from index: Int) {
        var child = index
        while child > 0 {
            let parent = (child - 1) / 2
            guard isSmaller(entries[child], than: entries[parent]) else { break }
            entries.swapAt(child, parent)
            child = parent
        }
    }

    private mutating func siftDown(from index: Int) {
        var parent = index
        while true {
            let left = parent * 2 + 1
            guard left < entries.count else { break }
            let right = left + 1
            let child = right < entries.count && isSmaller(entries[right], than: entries[left]) ? right : left
            guard isSmaller(entries[child], than: entries[parent]) else { break }
            entries.swapAt(child, parent)
            parent = child
        }
    }
}
