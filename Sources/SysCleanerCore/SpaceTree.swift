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
