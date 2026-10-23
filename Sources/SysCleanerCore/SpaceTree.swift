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

    public let id: UUID
    public let date: Date
    public let rootPath: String
    public let excludedPaths: [String]
    public let directoryCount: Int
    public let rootLogicalBytes: Int64
    public let rootAllocatedBytes: Int64
    public let directories: [Directory]

    public static func capture(tree: SpaceTree, excludedPaths: [String], date: Date = Date()) -> Self {
        let root = tree.root.standardizedFileURL.path
        var rootLogical: Int64 = 0
        var rootAllocated: Int64 = 0
        var directChildren: [Directory] = []
        var largest: [Directory] = []
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
                largest[0] = item
                siftDown(&largest, from: 0)
            }
        }
        return Self(id: UUID(), date: date, rootPath: root,
                    excludedPaths: Array(Set(excludedPaths)).sorted(), directoryCount: tree.directoryCount,
                    rootLogicalBytes: rootLogical, rootAllocatedBytes: rootAllocated,
                    directories: (directChildren + largest).sorted { $0.path < $1.path })
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

public enum SpaceGrowthComparison: Sendable {
    case noPrevious
    case sourcesChanged
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

    private static func compare(_ prior: SpaceScanSnapshot?, _ current: SpaceScanSnapshot) -> SpaceGrowthComparison {
        guard let prior else { return .noPrevious }
        guard prior.excludedPaths == current.excludedPaths else { return .sourcesChanged }
        let old = Dictionary(uniqueKeysWithValues: prior.directories.map { ($0.path, $0.logicalBytes) })
        let newSampleCount = current.directories.filter { old[$0.path] == nil }.count
        let growth = current.directories.compactMap { item -> SpaceGrowth? in
            guard let before = old[item.path], item.logicalBytes > before else { return nil }
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
