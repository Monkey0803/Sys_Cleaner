import Foundation

public enum ScanCategory: String, CaseIterable, Identifiable, Sendable {
    case overview, space, large, duplicates, downloads, systemCache, developerCache, uninstall, orphans, icloud
    public var id: String { rawValue }
}

public enum RiskLevel: String, Hashable, Sendable {
    case low, review, protected
}

public struct FileStamp: Codable, Equatable, Sendable {
    public let device: UInt64
    public let inode: UInt64
    public let size: Int64
    public let modifiedSeconds: Int64
    public let modifiedNanoseconds: Int64
    public let changedSeconds: Int64?
    public let changedNanoseconds: Int64?
    public let linkCount: UInt64
    /// Allocated blocks are an estimate: APFS clones can share those blocks.
    public let allocatedBytes: Int64?

    public init(device: UInt64, inode: UInt64, size: Int64, modifiedSeconds: Int64,
                modifiedNanoseconds: Int64, linkCount: UInt64, allocatedBytes: Int64? = nil,
                changedSeconds: Int64? = nil, changedNanoseconds: Int64? = nil) {
        self.device = device
        self.inode = inode
        self.size = size
        self.modifiedSeconds = modifiedSeconds
        self.modifiedNanoseconds = modifiedNanoseconds
        self.changedSeconds = changedSeconds
        self.changedNanoseconds = changedNanoseconds
        self.linkCount = linkCount
        self.allocatedBytes = allocatedBytes
    }

    public static func == (lhs: FileStamp, rhs: FileStamp) -> Bool {
        lhs.device == rhs.device && lhs.inode == rhs.inode && lhs.size == rhs.size &&
            lhs.modifiedSeconds == rhs.modifiedSeconds &&
            lhs.modifiedNanoseconds == rhs.modifiedNanoseconds && lhs.linkCount == rhs.linkCount &&
            (lhs.changedSeconds == nil || rhs.changedSeconds == nil ||
             (lhs.changedSeconds == rhs.changedSeconds && lhs.changedNanoseconds == rhs.changedNanoseconds))
    }
}

public struct ScanEntry: Identifiable, Sendable {
    public let id: UUID
    public let url: URL
    public let scope: URL
    public let category: ScanCategory
    public let stamp: FileStamp
    public let estimatedBytes: Int64
    public let allocatedBytes: Int64?
    public let sizeIsKnown: Bool
    public let risk: RiskLevel
    public let note: String
    public let lastUsedDate: Date?
    public let duplicateGroup: String?
    public let isDirectory: Bool
    public let canDelete: Bool
    public let directorySignature: String?

    public init(id: UUID = UUID(), url: URL, scope: URL, category: ScanCategory, stamp: FileStamp,
                estimatedBytes: Int64, allocatedBytes: Int64? = nil, sizeIsKnown: Bool = true,
                risk: RiskLevel = .review, note: String = "", lastUsedDate: Date? = nil,
                duplicateGroup: String? = nil, isDirectory: Bool = false,
                canDelete: Bool = true, directorySignature: String? = nil) {
        self.id = id
        self.url = url
        self.scope = scope
        self.category = category
        self.stamp = stamp
        self.estimatedBytes = estimatedBytes
        self.allocatedBytes = sizeIsKnown ? (allocatedBytes ?? stamp.allocatedBytes) : nil
        self.sizeIsKnown = sizeIsKnown
        self.risk = risk
        self.note = note
        self.lastUsedDate = lastUsedDate
        self.duplicateGroup = duplicateGroup
        self.isDirectory = isDirectory
        self.canDelete = canDelete
        self.directorySignature = directorySignature
    }

    public func withEstimatedBytes(_ bytes: Int64, allocatedBytes: Int64? = nil) -> ScanEntry {
        ScanEntry(id: id, url: url, scope: scope, category: category, stamp: stamp,
                  estimatedBytes: bytes, allocatedBytes: allocatedBytes,
                  sizeIsKnown: true, risk: risk, note: note, lastUsedDate: lastUsedDate,
                  duplicateGroup: duplicateGroup,
                  isDirectory: isDirectory, canDelete: canDelete, directorySignature: directorySignature)
    }
}

public struct ScanRequest: Sendable {
    public let category: ScanCategory
    public let root: URL
    public let minimumBytes: Int64
    public let olderThanDays: Int
    public let excludedPaths: [String]
    public let ignoredDuplicateHashes: Set<String>
    public let derivedDataRoots: [URL]
    public let useRustSpaceScanner: Bool
    public let rustHelperURL: URL?

    public init(category: ScanCategory, root: URL, minimumBytes: Int64 = 100 * 1_024 * 1_024,
                olderThanDays: Int = 0, excludedPaths: [String] = [],
                ignoredDuplicateHashes: Set<String> = [], derivedDataRoots: [URL] = [],
                useRustSpaceScanner: Bool = false, rustHelperURL: URL? = nil) {
        self.category = category
        self.root = root
        self.minimumBytes = minimumBytes
        self.olderThanDays = olderThanDays
        self.excludedPaths = excludedPaths
        self.ignoredDuplicateHashes = ignoredDuplicateHashes
        self.derivedDataRoots = derivedDataRoots
        self.useRustSpaceScanner = useRustSpaceScanner
        self.rustHelperURL = rustHelperURL
    }
}

public struct ScanReport: Sendable {
    public let entries: [ScanEntry]
    private let storedSpaceItems: [SpaceItem]
    public let spaceTree: SpaceTree?
    public var spaceItems: [SpaceItem] { spaceTree?.allItems() ?? storedSpaceItems }
    public let scannedFileCount: Int
    public let scannedBytes: Int64
    public let scannedAllocatedBytes: Int64?
    public let omittedCount: Int
    public let warnings: [String]
    public let cancelled: Bool
    /// The space view may limit individually displayed files while retaining
    /// their bytes in every directory total. That limit does not invalidate a
    /// directory-size snapshot; unreadable paths and other omissions do.
    public static func spaceTotalsAreComplete(warnings: [String], omittedCount: Int) -> Bool {
        if warnings.isEmpty { return omittedCount == 0 }
        return warnings.allSatisfy { $0 == "spaceLimit" }
    }
    public var hasCompleteSpaceTotals: Bool {
        spaceTree != nil && !cancelled &&
            Self.spaceTotalsAreComplete(warnings: warnings, omittedCount: omittedCount)
    }
    public init(entries: [ScanEntry], warnings: [String], cancelled: Bool,
                spaceItems: [SpaceItem] = [], scannedFileCount: Int? = nil, scannedBytes: Int64? = nil,
                scannedAllocatedBytes: Int64? = nil, omittedCount: Int = 0,
                spaceTree: SpaceTree? = nil) {
        self.entries = entries
        self.storedSpaceItems = spaceItems
        self.spaceTree = spaceTree
        self.scannedFileCount = scannedFileCount ?? entries.count
        self.scannedBytes = scannedBytes ?? entries.reduce(0) { $0 + $1.estimatedBytes }
        self.scannedAllocatedBytes = scannedAllocatedBytes ??
            (entries.allSatisfy { $0.allocatedBytes != nil } ? entries.reduce(0) { $0 + ($1.allocatedBytes ?? 0) } : nil)
        self.omittedCount = omittedCount
        self.warnings = warnings
        self.cancelled = cancelled
    }
}

public enum CleanupOverviewOperation: Hashable, Sendable {
    case trash, cloudEviction, simulator
}

public struct CleanupOverviewItem: Sendable {
    public let path: String
    public let displayName: String?
    public let category: ScanCategory
    public let estimatedBytes: Int64
    public let isDirectory: Bool
    public let operation: CleanupOverviewOperation
    public let risk: RiskLevel

    public init(path: String, category: ScanCategory, estimatedBytes: Int64,
                isDirectory: Bool, operation: CleanupOverviewOperation, risk: RiskLevel = .review,
                displayName: String? = nil) {
        self.path = path
        self.displayName = displayName
        self.category = category
        self.estimatedBytes = max(0, estimatedBytes)
        self.isDirectory = isDirectory
        self.operation = operation
        self.risk = risk
    }
}

public struct CleanupOverviewSource: Sendable {
    public let category: ScanCategory
    public let entries: [ScanEntry]
    public let incomplete: Bool
    public let omittedCount: Int

    public init(category: ScanCategory, entries: [ScanEntry], incomplete: Bool, omittedCount: Int = 0) {
        self.category = category
        self.entries = entries
        self.incomplete = incomplete
        self.omittedCount = omittedCount
    }
}

public struct CleanupOverviewSection: Identifiable, Sendable {
    public var id: ScanCategory { category }
    public let category: ScanCategory
    public let scanned: Bool
    public let incomplete: Bool
    public let omittedCount: Int
    public let candidateCount: Int
    public let estimatedBytes: Int64
}

public struct CleanupOverviewSnapshot: Sendable {
    public let sections: [CleanupOverviewSection]
    public let localEstimate: Int64
    public let cloudEstimate: Int64
    public let duplicateCount: Int
    public let candidates: [CleanupOverviewItem]
    public let largestCandidates: [CleanupOverviewItem]

    public static func make(sources: [CleanupOverviewSource],
                            supplemental: [CleanupOverviewItem] = [],
                            supplementalScanned: Set<ScanCategory> = [],
                            supplementalIncomplete: Set<ScanCategory> = []) -> Self {
        let order: [ScanCategory] = [.downloads, .duplicates, .large, .systemCache,
                                     .developerCache, .uninstall, .icloud, .space, .orphans]
        let sourceByCategory = Dictionary(uniqueKeysWithValues: sources.map { ($0.category, $0) })
        var candidates = supplemental
        for source in sources {
            for entry in source.entries where entry.canDelete && entry.risk != .protected && entry.sizeIsKnown {
                let operation: CleanupOverviewOperation = source.category == .icloud ? .cloudEviction : .trash
                guard source.category != .icloud || entry.allocatedBytes != nil else { continue }
                candidates.append(CleanupOverviewItem(
                    path: entry.url.standardizedFileURL.path, category: source.category,
                    estimatedBytes: operation == .cloudEviction ? (entry.allocatedBytes ?? 0)
                        : (entry.allocatedBytes ?? entry.estimatedBytes),
                    isDirectory: entry.isDirectory, operation: operation, risk: entry.risk))
            }
        }
        // A selected directory already contains its descendants. Sorting parents first
        // also prevents a file found in two scan categories from inflating the estimate.
        let ordered = candidates.sorted { left, right in
            if left.isDirectory != right.isDirectory { return left.isDirectory }
            if left.path.count != right.path.count { return left.path.count < right.path.count }
            let leftOrder = order.firstIndex(of: left.category) ?? order.count
            let rightOrder = order.firstIndex(of: right.category) ?? order.count
            if left.path != right.path { return left.path < right.path }
            if leftOrder != rightOrder { return leftOrder < rightOrder }
            return left.estimatedBytes < right.estimatedBytes
        }
        var seenPaths = Set<String>()
        var directories = Set<String>()
        var unique: [CleanupOverviewItem] = []
        var duplicates = 0
        for item in ordered {
            let path = URL(fileURLWithPath: item.path).standardizedFileURL.path
            var parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
            var covered = false
            while parent != "/" {
                if directories.contains(parent) { covered = true; break }
                parent = URL(fileURLWithPath: parent).deletingLastPathComponent().path
            }
            guard seenPaths.insert(path).inserted && !covered else {
                duplicates += 1
                continue
            }
            if item.isDirectory { directories.insert(path) }
            unique.append(item)
        }
        let sections = order.map { category in
            let members = unique.filter { $0.category == category }
            let source = sourceByCategory[category]
            return CleanupOverviewSection(
                category: category, scanned: source != nil || supplementalScanned.contains(category),
                incomplete: (source?.incomplete ?? false) || supplementalIncomplete.contains(category),
                omittedCount: source?.omittedCount ?? 0,
                candidateCount: members.count,
                estimatedBytes: members.reduce(0) { $0 + $1.estimatedBytes })
        }
        let ranked = unique.sorted {
            $0.estimatedBytes == $1.estimatedBytes ? $0.path < $1.path :
                $0.estimatedBytes > $1.estimatedBytes
        }
        return Self(sections: sections,
                    localEstimate: unique.filter { $0.operation != .cloudEviction }
                        .reduce(0) { $0 + $1.estimatedBytes },
                    cloudEstimate: unique.filter { $0.operation == .cloudEviction }
                        .reduce(0) { $0 + $1.estimatedBytes }, duplicateCount: duplicates,
                    candidates: ranked, largestCandidates: Array(ranked.prefix(20)))
    }
}

public enum ScanDiagnosticKind: String, Sendable {
    case unreadable, changed, limited, displayLimited, unavailable, other
}

public struct ScanDiagnostic: Identifiable, Sendable {
    public let id: String
    public let kind: ScanDiagnosticKind
    public let path: String?
    public let detail: String

    public static func make(warnings: [String], omittedCount: Int) -> [ScanDiagnostic] {
        var issues = warnings.enumerated().map { index, warning -> ScanDiagnostic in
            let kind: ScanDiagnosticKind
            let path: String?
            if warning.hasPrefix("Cannot read ") {
                kind = .unreadable
                path = String(warning.dropFirst("Cannot read ".count)).components(separatedBy: ": ").first
            } else if warning.hasPrefix("Changed or unreadable: ") {
                kind = .changed
                path = String(warning.dropFirst("Changed or unreadable: ".count))
            } else if warning.hasPrefix("Cannot verify ") {
                kind = .changed
                path = String(warning.dropFirst("Cannot verify ".count))
            } else if warning.hasPrefix("Invalid root ") || warning.hasPrefix("Invalid archive root ") {
                kind = .unavailable
                path = String(warning.dropFirst(warning.hasPrefix("Invalid archive root ") ?
                    "Invalid archive root ".count : "Invalid root ".count))
            } else if warning == "spaceLimit" {
                kind = .displayLimited
                path = nil
            } else if ["listLimited", "duplicateLimit", "scanIncomplete"].contains(warning) {
                kind = .limited
                path = nil
            } else if warning == "icloudUnavailable" || warning == "installedAppsIncomplete" {
                kind = .unavailable
                path = nil
            } else {
                kind = .other
                path = nil
            }
            return ScanDiagnostic(id: "\(index):\(warning)", kind: kind, path: path, detail: warning)
        }
        if omittedCount > 0 && warnings.isEmpty {
            issues.append(ScanDiagnostic(id: "omitted", kind: .limited, path: nil,
                                         detail: "scanIncomplete"))
        }
        return issues
    }
}

public enum ScanStage: String, Sendable {
    case discovering, measuringApps, comparing, reviewingApp
}

public struct ScanProgress: Sendable {
    public let stage: ScanStage
    public let processedFiles: Int
    public let processedDirectories: Int
    public let processedBytes: Int64
    public let currentPath: String

    public init(stage: ScanStage, processedFiles: Int, processedDirectories: Int,
                processedBytes: Int64, currentPath: String) {
        self.stage = stage
        self.processedFiles = processedFiles
        self.processedDirectories = processedDirectories
        self.processedBytes = processedBytes
        self.currentPath = currentPath
    }
}

public struct SpaceItem: Identifiable, Sendable {
    public var id: String { url.path + (isOther ? "#other" : "") }
    public let url: URL
    public let parent: URL
    public let bytes: Int64
    public let allocatedBytes: Int64?
    public let isFolder: Bool
    public let isOther: Bool

    public init(url: URL, parent: URL, bytes: Int64, isFolder: Bool, isOther: Bool = false,
                allocatedBytes: Int64? = nil) {
        self.url = url
        self.parent = parent
        self.bytes = bytes
        self.allocatedBytes = allocatedBytes
        self.isFolder = isFolder
        self.isOther = isOther
    }
}

public enum ScanSortField: String, CaseIterable, Sendable {
    case size, name, modified
}

public enum ScanSortDirection: String, CaseIterable, Sendable {
    case ascending, descending
}

public struct ScanSortSelection: Equatable, Sendable {
    public var field: ScanSortField
    public var direction: ScanSortDirection

    public init(field: ScanSortField = .size, direction: ScanSortDirection = .descending) {
        self.field = field
        self.direction = direction
    }
}

public enum ScanEntryFilter: String, CaseIterable, Sendable {
    case all, selectable, locked, images, videos, documents, archives, folders, other
}

public enum ScanResultFiltering {
    public static func entries(_ entries: [ScanEntry], category: ScanCategory,
                               query: String, filter: ScanEntryFilter) -> [ScanEntry] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !search.isEmpty || filter != .all else { return entries }

        func matches(_ entry: ScanEntry) -> Bool {
            let matchesSearch = search.isEmpty ||
                entry.url.path.localizedCaseInsensitiveContains(search) ||
                (category == .uninstall && entry.note.localizedCaseInsensitiveContains(search))
            return matchesSearch && matchesFilter(entry, filter: filter)
        }

        if category == .duplicates {
            let matchingGroups = Set(entries.filter(matches).map { $0.duplicateGroup ?? $0.url.path })
            return entries.filter { matchingGroups.contains($0.duplicateGroup ?? $0.url.path) }
        }
        return entries.filter(matches)
    }

    private static func matchesFilter(_ entry: ScanEntry, filter: ScanEntryFilter) -> Bool {
        switch filter {
        case .all: return true
        case .selectable: return entry.canDelete
        case .locked: return !entry.canDelete
        case .folders: return entry.isDirectory
        case .images, .videos, .documents, .archives, .other:
            guard !entry.isDirectory else { return false }
            let ext = entry.url.pathExtension.lowercased()
            let kind: ScanEntryFilter
            if ["jpg", "jpeg", "png", "heic", "webp", "gif", "tif", "tiff", "bmp"].contains(ext) {
                kind = .images
            } else if ["mov", "mp4", "m4v", "mkv", "avi", "webm"].contains(ext) {
                kind = .videos
            } else if ["pdf", "txt", "md", "rtf", "doc", "docx", "pages", "xls", "xlsx", "numbers", "csv", "ppt", "pptx", "key"].contains(ext) {
                kind = .documents
            } else if ["zip", "7z", "rar", "tar", "gz", "bz2", "xz", "dmg", "pkg"].contains(ext) {
                kind = .archives
            } else {
                kind = .other
            }
            return kind == filter
        }
    }
}

public enum ScanResultGrouping {
    public static func duplicateGroups(_ entries: [ScanEntry]) -> [[ScanEntry]] {
        var groups: [[ScanEntry]] = []
        var positions: [String: Int] = [:]
        for entry in entries {
            let key = entry.duplicateGroup ?? entry.url.path
            if let index = positions[key] {
                groups[index].append(entry)
            } else {
                positions[key] = groups.count
                groups.append([entry])
            }
        }
        return groups
    }

    public static func selectableIDs(in group: [ScanEntry]) -> Set<UUID> {
        Set(group.filter { $0.canDelete && $0.note != "keepOriginal" }.map(\.id))
    }
}

public enum ScanSorting {
    public static func entries(_ entries: [ScanEntry], category: ScanCategory,
                               selection: ScanSortSelection) -> [ScanEntry] {
        guard category == .duplicates else {
            return entries.sorted { entryLess($0, $1, category: category, selection: selection) }
        }
        let groups = Dictionary(grouping: entries) { $0.duplicateGroup ?? $0.url.path }
        let orderedGroups = groups.values.sorted { lhs, rhs in
            let left = retainedEntry(in: lhs)
            let right = retainedEntry(in: rhs)
            return entryLess(left, right, category: category, selection: selection)
        }
        return orderedGroups.flatMap { group in
            let retained = group.filter { $0.note == "keepOriginal" }
            let copies = group.filter { $0.note != "keepOriginal" }
                .sorted { entryLess($0, $1, category: category, selection: selection) }
            return retained.sorted { $0.url.path < $1.url.path } + copies
        }
    }

    public static func spaceItems(_ items: [SpaceItem], selection: ScanSortSelection,
                                  otherName: String) -> [SpaceItem] {
        items.sorted { lhs, rhs in
            let comparison: ComparisonResult
            switch selection.field {
            case .name:
                comparison = (lhs.isOther ? otherName : lhs.url.lastPathComponent)
                    .localizedCaseInsensitiveCompare(rhs.isOther ? otherName : rhs.url.lastPathComponent)
            case .size, .modified:
                comparison = compare(lhs.bytes, rhs.bytes)
            }
            return less(comparison, direction: selection.direction, leftPath: lhs.id, rightPath: rhs.id)
        }
    }

    private static func retainedEntry(in group: [ScanEntry]) -> ScanEntry {
        group.first { $0.note == "keepOriginal" } ?? group.min { $0.url.path < $1.url.path }!
    }

    private static func entryLess(_ lhs: ScanEntry, _ rhs: ScanEntry, category: ScanCategory,
                                  selection: ScanSortSelection) -> Bool {
        if (category == .uninstall || category == .orphans) && selection.field == .size {
            let leftUnknown = !lhs.sizeIsKnown ||
                (category == .uninstall && lhs.isDirectory && lhs.directorySignature == nil && lhs.estimatedBytes == 0)
            let rightUnknown = !rhs.sizeIsKnown ||
                (category == .uninstall && rhs.isDirectory && rhs.directorySignature == nil && rhs.estimatedBytes == 0)
            if leftUnknown != rightUnknown { return !leftUnknown }
        }
        let comparison: ComparisonResult
        switch selection.field {
        case .size:
            comparison = compare(lhs.estimatedBytes, rhs.estimatedBytes)
        case .name:
            comparison = lhs.url.lastPathComponent.localizedCaseInsensitiveCompare(rhs.url.lastPathComponent)
        case .modified:
            comparison = compare(lhs.stamp.modifiedSeconds, rhs.stamp.modifiedSeconds)
                .flatMapSame { compare(lhs.stamp.modifiedNanoseconds, rhs.stamp.modifiedNanoseconds) }
        }
        return less(comparison, direction: selection.direction,
                    leftPath: lhs.url.path, rightPath: rhs.url.path)
    }

    private static func compare(_ lhs: Int64, _ rhs: Int64) -> ComparisonResult {
        lhs == rhs ? .orderedSame : (lhs < rhs ? .orderedAscending : .orderedDescending)
    }

    private static func less(_ result: ComparisonResult, direction: ScanSortDirection,
                             leftPath: String, rightPath: String) -> Bool {
        if result == .orderedSame { return leftPath < rightPath }
        return direction == .ascending ? result == .orderedAscending : result == .orderedDescending
    }
}

private extension ComparisonResult {
    func flatMapSame(_ other: () -> ComparisonResult) -> ComparisonResult {
        self == .orderedSame ? other() : self
    }
}

public enum DeleteMode: Sendable, Equatable { case trash, permanent }

public enum DeletionCapacityScope {
    /// A single volume reading cannot represent a batch spanning volumes.
    public static func commonScope(for entries: [ScanEntry]) -> URL? {
        guard let first = entries.first,
              entries.allSatisfy({ $0.stamp.device == first.stamp.device }) else { return nil }
        return first.scope
    }
}

public struct DeleteResult: Sendable {
    public enum Status: Sendable { case success, skipped, failed }
    public let url: URL
    public let success: Bool
    public let message: String
    public let trashURL: URL?
    public let trashSignature: String?
    public var status: Status {
        if success { return .success }
        let refusals: Set<String> = ["protected", "unsafePath", "cloudPlaceholder", "changed",
                                     "changedOrRunning", "recentlyUsed", "fileInUse"]
        return refusals.contains(message) ? .skipped : .failed
    }
    public init(url: URL, success: Bool, message: String, trashURL: URL? = nil,
                trashSignature: String? = nil) {
        self.url = url
        self.success = success
        self.message = message
        self.trashURL = trashURL
        self.trashSignature = trashSignature
    }
}

public struct CleanupHistoryItem: Codable, Identifiable, Sendable {
    public let id: UUID
    public let path: String
    public let estimatedBytes: Int64
    public let success: Bool
    public let message: String
    public let trashPath: String?
    public let scopePath: String?
    public let trashStamp: FileStamp?
    public let trashSignature: String?
    public var restoredAt: Date?

    public var canRestore: Bool {
        success && message == "movedToTrash" && trashPath != nil && scopePath != nil &&
            trashStamp != nil && restoredAt == nil
    }

    public init(path: String, estimatedBytes: Int64, success: Bool,
                message: String, trashPath: String?, scopePath: String? = nil,
                trashStamp: FileStamp? = nil, trashSignature: String? = nil,
                restoredAt: Date? = nil) {
        self.id = UUID()
        self.path = path
        self.estimatedBytes = estimatedBytes
        self.success = success
        self.message = message
        self.trashPath = trashPath
        self.scopePath = scopePath
        self.trashStamp = trashStamp
        self.trashSignature = trashSignature
        self.restoredAt = restoredAt
    }
}

public struct CleanupHistoryRecord: Codable, Identifiable, Sendable {
    public let id: UUID
    public let date: Date
    public let category: String
    public let mode: String
    public var items: [CleanupHistoryItem]

    public init(date: Date = Date(), category: String, mode: String,
                items: [CleanupHistoryItem]) {
        self.id = UUID()
        self.date = date
        self.category = category
        self.mode = mode
        self.items = items
    }
}

public enum CleanupHistoryStorage {
    public static func load(from url: URL) throws -> [CleanupHistoryRecord] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([CleanupHistoryRecord].self, from: Data(contentsOf: url))
    }

    public static func save(_ records: [CleanupHistoryRecord], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(Array(records.prefix(50))).write(to: url, options: .atomic)
    }
}
