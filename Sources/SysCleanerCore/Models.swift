import Foundation

public enum ScanCategory: String, CaseIterable, Identifiable, Sendable {
    case space, large, duplicates, systemCache, developerCache, uninstall
    public var id: String { rawValue }
}

public enum RiskLevel: String, Sendable {
    case low, review, protected
}

public struct FileStamp: Equatable, Sendable {
    public let device: UInt64
    public let inode: UInt64
    public let size: Int64
    public let modifiedSeconds: Int64
    public let modifiedNanoseconds: Int64
    public let linkCount: UInt64

    public init(device: UInt64, inode: UInt64, size: Int64, modifiedSeconds: Int64,
                modifiedNanoseconds: Int64, linkCount: UInt64) {
        self.device = device
        self.inode = inode
        self.size = size
        self.modifiedSeconds = modifiedSeconds
        self.modifiedNanoseconds = modifiedNanoseconds
        self.linkCount = linkCount
    }
}

public struct ScanEntry: Identifiable, Sendable {
    public let id: UUID
    public let url: URL
    public let scope: URL
    public let category: ScanCategory
    public let stamp: FileStamp
    public let estimatedBytes: Int64
    public let risk: RiskLevel
    public let note: String
    public let duplicateGroup: String?
    public let isDirectory: Bool
    public let canDelete: Bool
    public let directorySignature: String?

    public init(url: URL, scope: URL, category: ScanCategory, stamp: FileStamp,
                estimatedBytes: Int64, risk: RiskLevel = .review, note: String = "",
                duplicateGroup: String? = nil, isDirectory: Bool = false,
                canDelete: Bool = true, directorySignature: String? = nil) {
        self.id = UUID()
        self.url = url
        self.scope = scope
        self.category = category
        self.stamp = stamp
        self.estimatedBytes = estimatedBytes
        self.risk = risk
        self.note = note
        self.duplicateGroup = duplicateGroup
        self.isDirectory = isDirectory
        self.canDelete = canDelete
        self.directorySignature = directorySignature
    }
}

public struct ScanRequest: Sendable {
    public let category: ScanCategory
    public let root: URL
    public let minimumBytes: Int64
    public let olderThanDays: Int

    public init(category: ScanCategory, root: URL, minimumBytes: Int64 = 100 * 1_024 * 1_024,
                olderThanDays: Int = 0) {
        self.category = category
        self.root = root
        self.minimumBytes = minimumBytes
        self.olderThanDays = olderThanDays
    }
}

public struct ScanReport: Sendable {
    public let entries: [ScanEntry]
    public let spaceItems: [SpaceItem]
    public let scannedFileCount: Int
    public let scannedBytes: Int64
    public let warnings: [String]
    public let cancelled: Bool
    public init(entries: [ScanEntry], warnings: [String], cancelled: Bool,
                spaceItems: [SpaceItem] = [], scannedFileCount: Int? = nil, scannedBytes: Int64? = nil) {
        self.entries = entries
        self.spaceItems = spaceItems
        self.scannedFileCount = scannedFileCount ?? entries.count
        self.scannedBytes = scannedBytes ?? entries.reduce(0) { $0 + $1.estimatedBytes }
        self.warnings = warnings
        self.cancelled = cancelled
    }
}

public struct SpaceItem: Identifiable, Sendable {
    public let id: String
    public let url: URL
    public let parent: URL
    public let bytes: Int64
    public let isFolder: Bool
    public let isOther: Bool

    public init(url: URL, parent: URL, bytes: Int64, isFolder: Bool, isOther: Bool = false) {
        self.id = url.path + (isOther ? "#other" : "")
        self.url = url
        self.parent = parent
        self.bytes = bytes
        self.isFolder = isFolder
        self.isOther = isOther
    }
}

public enum DeleteMode: Sendable, Equatable { case trash, permanent }

public struct DeleteResult: Sendable {
    public let url: URL
    public let success: Bool
    public let message: String
    public let trashURL: URL?
    public init(url: URL, success: Bool, message: String, trashURL: URL? = nil) {
        self.url = url
        self.success = success
        self.message = message
        self.trashURL = trashURL
    }
}
