import Foundation

/// Compact, read-only space scan results. Directory URLs and display items are
/// materialized only for the folder currently being shown.
public struct SpaceTree: Sendable {
    public struct Directory: Sendable {
        public let name: String
        public let parentIndex: Int
        public let bytes: Int64
        public let allocatedBytes: Int64
        public let otherBytes: Int64
        public let otherAllocatedBytes: Int64

        public init(name: String, parentIndex: Int, bytes: Int64, allocatedBytes: Int64,
                    otherBytes: Int64, otherAllocatedBytes: Int64) {
            self.name = name
            self.parentIndex = parentIndex
            self.bytes = bytes
            self.allocatedBytes = allocatedBytes
            self.otherBytes = otherBytes
            self.otherAllocatedBytes = otherAllocatedBytes
        }
    }

    public let root: URL
    public let directoryCount: Int
    public var hasDisplayItems: Bool {
        directories.count > 1 || !files.isEmpty || directories[0].otherBytes > 0
    }
    private let directories: [Directory]
    private let files: [SpaceItem]
    private let offsets: [Int]
    // Nonnegative values are directory indices; negative values encode file indices.
    private let children: [Int]

    public init(root: URL, directories: [Directory], files: [SpaceItem], fileParents: [Int]) {
        precondition(!directories.isEmpty && files.count == fileParents.count)
        self.root = root
        self.directoryCount = directories.count
        self.directories = directories
        self.files = files

        var counts = [Int](repeating: 0, count: directories.count)
        for directory in directories.dropFirst() {
            precondition((0..<directories.count).contains(directory.parentIndex),
                         "Invalid directory parent \(directory.parentIndex) in \(directories.count)")
            counts[directory.parentIndex] += 1
        }
        for parent in fileParents {
            precondition((0..<directories.count).contains(parent),
                         "Invalid file parent \(parent) in \(directories.count)")
            counts[parent] += 1
        }
        var offsets = [Int](repeating: 0, count: directories.count + 1)
        for index in directories.indices { offsets[index + 1] = offsets[index] + counts[index] }
        var cursor = Array(offsets.dropLast())
        var children = [Int](repeating: 0, count: offsets[directories.count])
        for index in directories.indices.dropFirst() {
            let parent = directories[index].parentIndex
            children[cursor[parent]] = index
            cursor[parent] += 1
        }
        for (index, parent) in fileParents.enumerated() {
            children[cursor[parent]] = -index - 1
            cursor[parent] += 1
        }
        self.offsets = offsets
        self.children = children
    }

    public func children(of folder: URL) -> [SpaceItem] {
        guard let index = directoryIndex(for: folder) else { return [] }
        var result: [SpaceItem] = []
        result.reserveCapacity(offsets[index + 1] - offsets[index] + 1)
        for position in offsets[index]..<offsets[index + 1] {
            let child = children[position]
            if child < 0 {
                result.append(files[-child - 1])
            } else {
                let directory = directories[child]
                result.append(SpaceItem(url: folder.appendingPathComponent(directory.name, isDirectory: true),
                                        parent: folder, bytes: directory.bytes, isFolder: true,
                                        allocatedBytes: directory.allocatedBytes))
            }
        }
        let directory = directories[index]
        if directory.otherBytes > 0 {
            result.append(SpaceItem(url: folder.appendingPathComponent("__other_files__"),
                                    parent: folder, bytes: directory.otherBytes, isFolder: false,
                                    isOther: true, allocatedBytes: directory.otherAllocatedBytes))
        }
        return result
    }

    /// Locate an item in this scan's display set without consulting the live file system.
    /// Files counted only in "Other files" cannot be focused individually.
    public func displayFolder(containing path: URL, isDirectory: Bool) -> URL? {
        let item = path.standardizedFileURL
        if isDirectory && item.path == root.standardizedFileURL.path { return root }
        let parent = item.deletingLastPathComponent()
        guard let index = directoryIndex(for: parent) else { return nil }
        if isDirectory {
            guard (offsets[index]..<offsets[index + 1]).contains(where: {
                let child = children[$0]
                return child >= 0 && directories[child].name == item.lastPathComponent
            }) else { return nil }
        } else {
            guard (offsets[index]..<offsets[index + 1]).contains(where: {
                let child = children[$0]
                return child < 0 && files[-child - 1].url.standardizedFileURL == item
            }) else { return nil }
        }
        return parent
    }

    /// Used by explicit full-result exports and small test fixtures, not by the App.
    public func allItems() -> [SpaceItem] {
        var urls = [URL](repeating: root, count: directories.count)
        var result: [SpaceItem] = []
        result.reserveCapacity(directories.count - 1 + files.count)
        for index in directories.indices.dropFirst() {
            let directory = directories[index]
            let parent = urls[directory.parentIndex]
            let url = parent.appendingPathComponent(directory.name, isDirectory: true)
            urls[index] = url
            result.append(SpaceItem(url: url, parent: parent, bytes: directory.bytes,
                                    isFolder: true, allocatedBytes: directory.allocatedBytes))
        }
        result.append(contentsOf: files)
        for index in directories.indices where directories[index].otherBytes > 0 {
            let directory = directories[index]
            let parent = urls[index]
            result.append(SpaceItem(url: parent.appendingPathComponent("__other_files__"),
                                    parent: parent, bytes: directory.otherBytes, isFolder: false,
                                    isOther: true, allocatedBytes: directory.otherAllocatedBytes))
        }
        return result
    }

    public func forEachDirectory(_ body: (URL, Int64, Int64) -> Void) {
        var urls = [URL](repeating: root, count: directories.count)
        for index in directories.indices {
            let directory = directories[index]
            if index > 0 {
                urls[index] = urls[directory.parentIndex].appendingPathComponent(
                    directory.name, isDirectory: true)
            }
            body(urls[index], directory.bytes, directory.allocatedBytes)
        }
    }

    /// This is the scan's bounded individual-file display set, not every file
    /// counted in directory totals.
    public func forEachDisplayedFile(_ body: (SpaceItem) -> Void) {
        for file in files { body(file) }
    }

    private func directoryIndex(for folder: URL) -> Int? {
        if folder.path == root.path { return 0 }
        var components: [String] = []
        var cursor = folder
        while cursor.path != root.path {
            let parent = cursor.deletingLastPathComponent()
            guard parent.path != cursor.path else { return nil }
            components.append(cursor.lastPathComponent)
            cursor = parent
        }
        var index = 0
        for name in components.reversed() {
            guard let child = (offsets[index]..<offsets[index + 1]).lazy
                .map({ children[$0] })
                .first(where: { $0 >= 0 && directories[$0].name == name }) else { return nil }
            index = child
        }
        return index
    }
}

/// A bounded directory sample for comparing complete space scans of the same root.
/// Root children are always retained; deeper entries are limited to the largest 2,000.
public struct SpaceScanSnapshot: Codable, Sendable {
    public struct Directory: Codable, Sendable {
        public let path: String
        public let logicalBytes: Int64
        public let allocatedBytes: Int64
    }

    public struct File: Codable, Sendable {
        public let path: String
        public let logicalBytes: Int64
    }

    public let id: UUID
    public let date: Date
    public let rootPath: String
    public let excludedPaths: [String]
    public let directoryCount: Int
    public let rootLogicalBytes: Int64
    public let rootAllocatedBytes: Int64
    public let directories: [Directory]
    /// Nil in older saved snapshots, which were only recorded for complete scans.
    public let unreadablePaths: [String]?
    public let unlocatedUnreadableCount: Int?
    public let sampleLimitedParents: [String]?
    public let files: [File]?

    public static func capture(report: ScanReport, excludedPaths: [String], date: Date = Date()) -> Self? {
        guard !report.cancelled, let tree = report.spaceTree else { return nil }
        let root = tree.root.standardizedFileURL.path
        let paths = Set(ScanDiagnostic.make(warnings: report.warnings,
                                            omittedCount: report.omittedCount).compactMap { issue -> String? in
            guard issue.kind == .unreadable || issue.kind == .changed,
                  let path = issue.path else { return nil }
            let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
            return normalized == root || normalized.hasPrefix(root + "/") ? normalized : nil
        })
        let unreadableCount = report.spaceCoverage?.unreadableCount ??
            (report.hasCompleteSpaceTotals ? 0 : report.omittedCount)
        return capture(tree: tree, excludedPaths: excludedPaths, date: date,
                       unreadablePaths: Array(paths),
                       unlocatedUnreadableCount: max(0, unreadableCount - paths.count))
    }

    public static func capture(tree: SpaceTree, excludedPaths: [String], date: Date = Date(),
                               unreadablePaths: [String] = [], unlocatedUnreadableCount: Int = 0) -> Self {
        let root = tree.root.standardizedFileURL.path
        var rootLogical: Int64 = 0
        var rootAllocated: Int64 = 0
        var directChildren: [Directory] = []
        var largest: [Directory] = []
        var sampleLimitedParents = Set<String>()
        func noteSampleLimit(_ item: Directory) {
            if sampleLimitedParents.count < 100 {
                sampleLimitedParents.insert(URL(fileURLWithPath: item.path)
                    .deletingLastPathComponent().standardizedFileURL.path)
            }
        }
        tree.forEachDirectory { url, logical, allocated in
            let path = url.standardizedFileURL.path
            if path == root {
                rootLogical = logical
                rootAllocated = allocated
                return
            }
            let item = Directory(path: path, logicalBytes: logical, allocatedBytes: allocated)
            if url.deletingLastPathComponent().standardizedFileURL.path == root {
                directChildren.append(item)
            } else if largest.count < 2_000 {
                largest.append(item)
                siftUp(&largest, from: largest.count - 1)
            } else if let smallest = largest.first, ranksBelow(smallest, item) {
                noteSampleLimit(smallest)
                largest[0] = item
                siftDown(&largest, from: 0)
            } else {
                noteSampleLimit(item)
            }
        }
        var displayedFiles: [File] = []
        tree.forEachDisplayedFile { file in
            if !file.isOther && file.bytes >= 1_048_576 {
                displayedFiles.append(File(path: file.url.standardizedFileURL.path,
                                           logicalBytes: file.bytes))
            }
        }
        let fileSample = displayedFiles.sorted {
            $0.logicalBytes == $1.logicalBytes ? $0.path < $1.path :
                $0.logicalBytes > $1.logicalBytes
        }.prefix(2_000).sorted { $0.path < $1.path }
        return Self(id: UUID(), date: date, rootPath: root,
                    excludedPaths: Array(Set(excludedPaths)).sorted(), directoryCount: tree.directoryCount,
                    rootLogicalBytes: rootLogical, rootAllocatedBytes: rootAllocated,
                    directories: (directChildren + largest).sorted { $0.path < $1.path },
                    unreadablePaths: Array(Set(unreadablePaths)).sorted(),
                    unlocatedUnreadableCount: max(0, unlocatedUnreadableCount),
                    sampleLimitedParents: sampleLimitedParents.sorted(),
                    files: Array(fileSample))
    }

    private static func ranksBelow(_ lhs: Directory, _ rhs: Directory) -> Bool {
        lhs.logicalBytes == rhs.logicalBytes ? lhs.path > rhs.path : lhs.logicalBytes < rhs.logicalBytes
    }

    private static func siftUp(_ values: inout [Directory], from index: Int) {
        var child = index
        while child > 0 {
            let parent = (child - 1) / 2
            guard ranksBelow(values[child], values[parent]) else { break }
            values.swapAt(child, parent)
            child = parent
        }
    }

    private static func siftDown(_ values: inout [Directory], from index: Int) {
        var parent = index
        while true {
            let left = parent * 2 + 1
            guard left < values.count else { break }
            let right = left + 1
            let child = right < values.count && ranksBelow(values[right], values[left]) ? right : left
            guard ranksBelow(values[child], values[parent]) else { break }
            values.swapAt(child, parent)
            parent = child
        }
    }
}

public struct SpaceGrowth: Sendable {
    public let path: String
    public let previousBytes: Int64
    public let currentBytes: Int64
    public var increase: Int64 { currentBytes - previousBytes }
}

public struct SpaceDirectoryChange: Sendable {
    public let path: String
    public let previousBytes: Int64?
    public let currentBytes: Int64?
    public var hasComparableDelta: Bool { previousBytes != nil && currentBytes != nil }
}

public struct SpaceFileChange: Sendable {
    public let path: String
    public let previousBytes: Int64?
    public let currentBytes: Int64?
    public var hasComparableDelta: Bool { previousBytes != nil && currentBytes != nil }
}

public struct SpaceComparisonUncertainty: Sendable {
    public let unreadablePaths: [String]
    public let unlocatedUnreadableCount: Int
    public let sampleLimited: Bool
    public let sampleLimitedParents: [String]
}

public enum SpaceGrowthComparison: Sendable {
    case noPrevious
    case sourcesChanged
    case invalidSelection
    case comparable(previousDate: Date, currentDate: Date, rootPath: String,
                    previousTotal: Int64, currentTotal: Int64,
                    sampledCount: Int, directoryCount: Int, newSampleCount: Int,
                    growth: [SpaceGrowth])
}

public struct SpaceScanHistory: Codable, Sendable {
    public private(set) var snapshots: [SpaceScanSnapshot]

    public init(snapshots: [SpaceScanSnapshot] = []) { self.snapshots = snapshots }

    public mutating func record(_ current: SpaceScanSnapshot) -> SpaceGrowthComparison {
        guard snapshots.last?.id != current.id else { return .noPrevious }
        let prior = snapshots.last { $0.rootPath == current.rootPath }
        let result = Self.compare(prior, current)
        snapshots.append(current)
        if snapshots.count > 20 { snapshots.removeFirst(snapshots.count - 20) }
        return result
    }

    public var latestComparison: SpaceGrowthComparison {
        guard let current = snapshots.last else { return .noPrevious }
        return Self.compare(snapshots.dropLast().last { $0.rootPath == current.rootPath }, current)
    }

    public func comparison(olderID: UUID, newerID: UUID) -> SpaceGrowthComparison {
        guard let olderIndex = snapshots.firstIndex(where: { $0.id == olderID }),
              let newerIndex = snapshots.firstIndex(where: { $0.id == newerID }),
              olderIndex < newerIndex else { return .invalidSelection }
        return Self.compare(snapshots[olderIndex], snapshots[newerIndex])
    }

    public func uncertainty(olderID: UUID, newerID: UUID) -> SpaceComparisonUncertainty? {
        guard let older = snapshots.first(where: { $0.id == olderID }),
              let newer = snapshots.first(where: { $0.id == newerID }),
              older.rootPath == newer.rootPath,
              older.excludedPaths == newer.excludedPaths else { return nil }
        return Self.uncertainty(older, newer)
    }

    private static func uncertainty(_ older: SpaceScanSnapshot,
                                    _ newer: SpaceScanSnapshot) -> SpaceComparisonUncertainty {
        SpaceComparisonUncertainty(
            unreadablePaths: Array(Set((older.unreadablePaths ?? []) +
                                       (newer.unreadablePaths ?? []))).sorted(),
            unlocatedUnreadableCount: max(older.unlocatedUnreadableCount ?? 0,
                                          newer.unlocatedUnreadableCount ?? 0),
            sampleLimited: older.directories.count < older.directoryCount - 1 ||
                           newer.directories.count < newer.directoryCount - 1,
            sampleLimitedParents: Array(Set((older.sampleLimitedParents ?? []) +
                                            (newer.sampleLimitedParents ?? []))).sorted())
    }

    private static func isUncertain(_ path: String, _ uncertainty: SpaceComparisonUncertainty) -> Bool {
        uncertainty.unlocatedUnreadableCount > 0 || uncertainty.unreadablePaths.contains {
            $0 == path || $0.hasPrefix(path + "/") || path.hasPrefix($0 + "/")
        }
    }

    /// Only paths present in both bounded samples have a trustworthy delta.
    public func directoryChanges(olderID: UUID, newerID: UUID, under path: String)
        -> [SpaceDirectoryChange] {
        guard let olderIndex = snapshots.firstIndex(where: { $0.id == olderID }),
              let newerIndex = snapshots.firstIndex(where: { $0.id == newerID }),
              olderIndex < newerIndex else { return [] }
        let older = snapshots[olderIndex], newer = snapshots[newerIndex]
        guard older.rootPath == newer.rootPath, older.excludedPaths == newer.excludedPaths else { return [] }
        let uncertainty = Self.uncertainty(older, newer)
        let prefix = path.hasSuffix("/") ? path : path + "/"
        let old = Dictionary(uniqueKeysWithValues: older.directories.map { ($0.path, $0.logicalBytes) })
        let current = Dictionary(uniqueKeysWithValues: newer.directories.map { ($0.path, $0.logicalBytes) })
        return Set(old.keys).union(current.keys).filter { $0.hasPrefix(prefix) }.map { candidate in
            if Self.isUncertain(candidate, uncertainty) {
                return SpaceDirectoryChange(path: candidate, previousBytes: nil, currentBytes: nil)
            }
            return SpaceDirectoryChange(path: candidate, previousBytes: old[candidate],
                                        currentBytes: current[candidate])
        }.filter { !$0.hasComparableDelta || $0.previousBytes != $0.currentBytes }.sorted {
            let left = abs(($0.currentBytes ?? 0) - ($0.previousBytes ?? 0))
            let right = abs(($1.currentBytes ?? 0) - ($1.previousBytes ?? 0))
            return left == right ? $0.path < $1.path : left > right
        }
    }

    public func fileChanges(olderID: UUID, newerID: UUID, under path: String) -> [SpaceFileChange] {
        guard let olderIndex = snapshots.firstIndex(where: { $0.id == olderID }),
              let newerIndex = snapshots.firstIndex(where: { $0.id == newerID }),
              olderIndex < newerIndex else { return [] }
        let older = snapshots[olderIndex], newer = snapshots[newerIndex]
        guard older.rootPath == newer.rootPath, older.excludedPaths == newer.excludedPaths,
              let olderFiles = older.files, let newerFiles = newer.files else { return [] }
        let uncertainty = Self.uncertainty(older, newer)
        let prefix = path.hasSuffix("/") ? path : path + "/"
        let old = Dictionary(uniqueKeysWithValues: olderFiles.map { ($0.path, $0.logicalBytes) })
        let current = Dictionary(uniqueKeysWithValues: newerFiles.map { ($0.path, $0.logicalBytes) })
        return Set(old.keys).union(current.keys).filter { $0.hasPrefix(prefix) }.compactMap { candidate in
            guard !Self.isUncertain(candidate, uncertainty) else { return nil }
            let change = SpaceFileChange(path: candidate, previousBytes: old[candidate],
                                         currentBytes: current[candidate])
            return change.previousBytes != change.currentBytes ? change : nil
        }.sorted {
            let left = abs(($0.currentBytes ?? 0) - ($0.previousBytes ?? 0))
            let right = abs(($1.currentBytes ?? 0) - ($1.previousBytes ?? 0))
            return left == right ? $0.path < $1.path : left > right
        }
    }

    private static func compare(_ prior: SpaceScanSnapshot?, _ current: SpaceScanSnapshot) -> SpaceGrowthComparison {
        guard let prior else { return .noPrevious }
        guard prior.rootPath == current.rootPath,
              prior.excludedPaths == current.excludedPaths else { return .sourcesChanged }
        let uncertainty = Self.uncertainty(prior, current)
        let old = Dictionary(uniqueKeysWithValues: prior.directories.map { ($0.path, $0.logicalBytes) })
        let newSampleCount = current.directories.filter { old[$0.path] == nil }.count
        let growth = current.directories.compactMap { item -> SpaceGrowth? in
            guard !Self.isUncertain(item.path, uncertainty),
                  let before = old[item.path], item.logicalBytes > before else { return nil }
            return SpaceGrowth(path: item.path, previousBytes: before, currentBytes: item.logicalBytes)
        }.sorted {
            $0.increase == $1.increase ? $0.path < $1.path : $0.increase > $1.increase
        }
        return .comparable(previousDate: prior.date, currentDate: current.date,
                           rootPath: current.rootPath, previousTotal: prior.rootLogicalBytes,
                           currentTotal: current.rootLogicalBytes,
                           sampledCount: current.directories.count,
                           directoryCount: current.directoryCount, newSampleCount: newSampleCount,
                           growth: growth)
    }

    public static func load(from url: URL) throws -> Self {
        guard FileManager.default.fileExists(atPath: url.path) else { return Self() }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}

/// A volume comparison is meaningful only for a complete scan of that volume's root.
/// File block totals and APFS volume usage have different accounting rules, so the
/// signed difference is a diagnostic, never a claim that the bytes can be deleted.
public enum SpaceAccounting: Equatable, Sendable {
    case folderOnly
    case incomplete
    case compared(volumeUsedBytes: Int64, scannedAllocatedBytes: Int64, differenceBytes: Int64)

    public static func assess(scanRootPath: String, volumeRootPath: String?,
                              volumeUsedBytes: Int64?, scannedAllocatedBytes: Int64?,
                              complete: Bool) -> Self {
        guard scanRootPath == volumeRootPath, let used = volumeUsedBytes, used >= 0 else {
            return .folderOnly
        }
        guard complete, let scanned = scannedAllocatedBytes, scanned >= 0 else {
            return .incomplete
        }
        return .compared(volumeUsedBytes: used, scannedAllocatedBytes: scanned,
                         differenceBytes: used - scanned)
    }
}
