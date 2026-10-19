import Foundation

public struct XcodeArchive: Identifiable, Sendable {
    public let url: URL
    public let name: String
    public let created: Date?
    public let logicalBytes: Int64
    public let allocatedBytes: Int64
    public var id: String { url.path }
}

public struct XcodeStorageInventory<Item: Sendable>: Sendable {
    public let items: [Item]
    public let warnings: [String]
    public let readableSourceCount: Int
    public var isComplete: Bool { warnings.isEmpty }

    public init(items: [Item], warnings: [String], readableSourceCount: Int = 0) {
        self.items = items
        self.warnings = warnings
        self.readableSourceCount = readableSourceCount
    }
}

public struct XcodeDeviceSupport: Identifiable, Sendable {
    public let url: URL
    public let logicalBytes: Int64
    public let allocatedBytes: Int64
    public let modified: Date?
    public var id: String { url.path }
    public var name: String { url.lastPathComponent }
}

public struct XcodeReadOnlyItem: Identifiable, Sendable {
    public let url: URL
    public let name: String
    public let logicalBytes: Int64
    public let allocatedBytes: Int64
    public let isComplete: Bool
    public let stamp: FileStamp
    public let directorySignature: String?
    public var id: String { url.path }
}

public struct XcodeReadOnlyReport: Sendable {
    public let items: [XcodeReadOnlyItem]
    public let warnings: [String]
    public let cancelled: Bool
    public let readableSourceCount: Int
    public var isComplete: Bool { !cancelled && warnings.isEmpty }
}

public struct XcodeSimulatorRuntime: Identifiable, Sendable {
    public let id: String
    public let runtimeIdentifier: String?
    public let path: String?
    public let name: String
    public let version: String
    public let build: String
    public let state: String
    public let logicalBytes: Int64?
    public let lastUsed: Date?
}

public struct XcodeRuntimeAssociation: Sendable {
    public let deviceCount: Int
    public let bootedDeviceCount: Int
    public let matchingImageCount: Int
}

public struct XcodeSimulator: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let runtime: String
    public let state: String
    public let isAvailable: Bool
    public let lastUsed: Date?
    public let dataPath: URL?
    public let dataBytes: Int64?
    public var canDelete: Bool { state == "Shutdown" }
    public var runtimeName: String {
        let name = runtime.components(separatedBy: ".").last ?? runtime
        let parts = name.split(separator: "-")
        guard parts.count > 1 else { return name }
        return "\(parts[0]) \(parts.dropFirst().joined(separator: "."))"
    }
}

public struct XcodeProjectGroup: Identifiable, Sendable {
    public let id: String
    public let projectPath: String?
    public let entries: [ScanEntry]
    public var logicalBytes: Int64 { entries.reduce(0) { $0 + $1.estimatedBytes } }
    public var allocatedBytes: Int64? {
        guard entries.allSatisfy({ $0.allocatedBytes != nil }) else { return nil }
        return entries.reduce(0) { $0 + ($1.allocatedBytes ?? 0) }
    }
    public var lastActivity: Date {
        entries.map { $0.lastUsedDate ?? Date(timeIntervalSince1970: Double($0.stamp.modifiedSeconds)) }
            .max() ?? .distantPast
    }
}

public enum XcodeStorage {
    public static var defaultDerivedDataRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Developer/Xcode/DerivedData")
    }

    public static var defaultArchivesRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Developer/Xcode/Archives")
    }

    public static var defaultDeviceSupportRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Developer/Xcode/iOS DeviceSupport")
    }

    public static var defaultXcodeRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Developer/Xcode")
    }

    public static var defaultDeveloperRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Developer")
    }

    private static let sharedCacheNames = ["CompilationCache.noindex", "ModuleCache.noindex",
        "SDKStatCaches.noindex", "SDKExplicitPrecompiledModules", "SymbolCache.noindex"]
    /// Recreated by the isolated Xcode 27.1 build in docs/XcodeCacheValidation.md.
    public static let rebuildVerifiedCacheNames: Set<String> = ["CompilationCache.noindex", "ModuleCache.noindex",
        "SDKStatCaches.noindex", "SDKExplicitPrecompiledModules"]
    private static let additionalXcodeNames = ["DeviceLogs", "DocumentationCache",
        "DocumentationIndex", "Products"]
    private static let additionalDeveloperNames = ["DVTDownloads", "XCTestDevices"]

    public static func sharedCacheInventory(derivedDataRoots: [URL],
                                            control: ScanControl = ScanControl()) -> XcodeReadOnlyReport {
        var candidates: [(String, URL)] = []
        var warnings: [String] = []
        var seenRoots = Set<String>()
        for supplied in derivedDataRoots {
            let root = supplied.standardizedFileURL
            guard FileManager.default.fileExists(atPath: root.path) else { continue }
            guard isAllowedDerivedDataRoot(root) else {
                warnings.append("Invalid root \(root.path)")
                continue
            }
            guard seenRoots.insert(root.path).inserted else { continue }
            for name in sharedCacheNames {
                candidates.append((name, root.appendingPathComponent(name)))
            }
        }
        return readOnlyInventory(candidates: candidates, warnings: warnings, control: control)
    }

    public static func additionalDataInventory(xcodeRoot: URL = defaultXcodeRoot,
                                               developerRoot: URL = defaultDeveloperRoot,
                                               control: ScanControl = ScanControl()) -> XcodeReadOnlyReport {
        let candidates = additionalXcodeNames.map { ($0, xcodeRoot.appendingPathComponent($0)) }
            + additionalDeveloperNames.map { ($0, developerRoot.appendingPathComponent($0)) }
        return readOnlyInventory(candidates: candidates, warnings: [], control: control)
    }

    private static func readOnlyInventory(candidates: [(String, URL)], warnings initialWarnings: [String],
                                          control: ScanControl) -> XcodeReadOnlyReport {
        var items: [XcodeReadOnlyItem] = []
        var warnings = initialWarnings
        var seenPaths = Set<String>()
        var seenIdentities = Set<String>()
        var measuredPaths: [String] = []
        var readableSources = 0
        if let first = candidates.first { control.begin(.discovering, path: first.1) }
        for (name, supplied) in candidates where !control.isCancelled {
            let url = supplied.standardizedFileURL
            guard FileManager.default.fileExists(atPath: url.path) ||
                    (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil else { continue }
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
            let path = resolved.hasSuffix("/") ? String(resolved.dropLast()) : resolved
            guard !FileSafety.hasSymlinkInPath(url, through: FileManager.default.homeDirectoryForCurrentUser),
                  let metadata = FileSafety.metadata(at: url), metadata.isDirectory else {
                warnings.append("Cannot verify \(url.path)")
                continue
            }
            let identity = "\(metadata.stamp.device):\(metadata.stamp.inode)"
            guard seenPaths.insert(path).inserted, seenIdentities.insert(identity).inserted else { continue }
            guard !measuredPaths.contains(where: { path.hasPrefix($0 + "/") || $0.hasPrefix(path + "/") }) else {
                warnings.append("Overlapping root \(url.path)")
                continue
            }
            measuredPaths.append(path)
            readableSources += 1
            let measured = measuredReadOnlyDirectory(url, control: control)
            let signature = measured.complete && rebuildVerifiedCacheNames.contains(name)
                ? FileScanner.directorySignature(url, control: control) : nil
            let complete = measured.complete &&
                (!rebuildVerifiedCacheNames.contains(name) ||
                 (signature != nil && signature?.bytes == measured.logical &&
                  signature?.allocatedBytes == measured.allocated && FileSafety.stamp(at: url) == metadata.stamp))
            if !complete && !control.isCancelled { warnings.append("Cannot verify \(url.path)") }
            items.append(XcodeReadOnlyItem(url: url, name: name, logicalBytes: measured.logical,
                                           allocatedBytes: measured.allocated, isComplete: complete,
                                           stamp: metadata.stamp,
                                           directorySignature: complete ? signature?.digest : nil))
        }
        return XcodeReadOnlyReport(items: items.sorted { $0.logicalBytes > $1.logicalBytes },
                                   warnings: warnings, cancelled: control.isCancelled,
                                   readableSourceCount: readableSources)
    }

    public static func cacheDeletionEntry(for item: XcodeReadOnlyItem,
                                          derivedDataRoots: [URL]) -> ScanEntry? {
        guard item.isComplete, rebuildVerifiedCacheNames.contains(item.name),
              item.url.lastPathComponent == item.name, let signature = item.directorySignature else { return nil }
        let root = item.url.deletingLastPathComponent().standardizedFileURL
        guard derivedDataRoots.contains(where: { $0.standardizedFileURL.path == root.path }),
              isAllowedDerivedDataRoot(root),
              !FileSafety.hasSymlinkInPath(item.url, through: root) else { return nil }
        return ScanEntry(url: item.url, scope: root, category: .developerCache, stamp: item.stamp,
                         estimatedBytes: item.logicalBytes, allocatedBytes: item.allocatedBytes,
                         note: "verifiedSharedCache", isDirectory: true, directorySignature: signature)
    }

    private static func measuredReadOnlyDirectory(_ root: URL,
                                                   control: ScanControl) -> (logical: Int64, allocated: Int64, complete: Bool) {
        var logical: Int64 = 0
        var allocated: Int64 = 0
        var complete = true
        guard let before = FileSafety.stamp(at: root) else { return (0, 0, false) }
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil,
                errorHandler: { _, _ in complete = false; return true }) else { return (0, 0, false) }
        for case let url as URL in enumerator {
            if control.isCancelled { complete = false; break }
            guard let info = FileSafety.metadata(at: url) else {
                complete = false
                enumerator.skipDescendants()
                continue
            }
            if info.isDirectory {
                control.visited(url)
            } else {
                logical += info.stamp.size
                allocated += info.stamp.allocatedBytes ?? 0
                control.visited(url, bytes: info.stamp.size)
            }
        }
        if FileSafety.stamp(at: root) != before { complete = false }
        return (logical, allocated, complete)
    }

    public static func isAllowedDerivedDataRoot(_ suppliedRoot: URL) -> Bool {
        let root = suppliedRoot.standardizedFileURL
        let home = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().standardizedFileURL
        guard root.lastPathComponent == "DerivedData", root.path.hasPrefix(home.path + "/"),
              FileSafety.isDirectory(root),
              !FileSafety.hasSymlinkInPath(root, through: home) else { return false }
        let protectedRoots = [defaultArchivesRoot, defaultDeviceSupportRoot,
                              home.appendingPathComponent("Library/Developer/CoreSimulator/Devices")]
            + sharedCacheNames.map { defaultDerivedDataRoot.appendingPathComponent($0) }
            + additionalXcodeNames.map { defaultXcodeRoot.appendingPathComponent($0) }
            + additionalDeveloperNames.map { defaultDeveloperRoot.appendingPathComponent($0) }
        return !protectedRoots.contains { protected in
            let path = protected.standardizedFileURL.path
            return root.path == path || root.path.hasPrefix(path + "/")
        }
    }

    private static func projectMetadata(in derivedData: URL) -> (path: String?, lastUsed: Date?) {
        let info = derivedData.appendingPathComponent("info.plist")
        guard let data = try? Data(contentsOf: info),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any] else { return (nil, nil) }
        let path = (plist["WorkspacePath"] as? String) ?? (plist["ProjectPath"] as? String)
        return (path?.isEmpty == false ? path : nil, plist["LastAccessedDate"] as? Date)
    }

    public static func sortedByRecentUse(_ entries: [ScanEntry]) -> [ScanEntry] {
        entries.sorted { left, right in
            let leftDate = left.lastUsedDate
                ?? Date(timeIntervalSince1970: Double(left.stamp.modifiedSeconds))
            let rightDate = right.lastUsedDate
                ?? Date(timeIntervalSince1970: Double(right.stamp.modifiedSeconds))
            return leftDate == rightDate ? left.url.path < right.url.path : leftDate > rightDate
        }
    }

    public static func projectGroups(_ entries: [ScanEntry]) -> [XcodeProjectGroup] {
        let buckets = Dictionary(grouping: entries) { entry in
            entry.note.isEmpty ? "unknown:\(entry.url.path)"
                : "project:\(URL(fileURLWithPath: entry.note).standardizedFileURL.path)"
        }
        return buckets.map { id, members in
            XcodeProjectGroup(id: id, projectPath: members.first?.note.isEmpty == false ? members.first?.note : nil,
                              entries: members.sorted { $0.url.path < $1.url.path })
        }
    }

    public static func isProjectDirectory(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        guard !name.hasSuffix(".noindex") else { return false }
        if FileManager.default.fileExists(atPath: url.appendingPathComponent("info.plist").path) { return true }
        return name.range(of: "-[a-z]{28}$", options: .regularExpression) != nil
    }

    public static func derivedDataEntries(roots: [URL], excludedPaths: [String] = [],
                                          control: ScanControl = ScanControl()) -> ScanReport {
        var entries: [ScanEntry] = []
        var warnings: [String] = []
        var seenRoots = Set<String>()
        var scannedRoots: [String] = []
        var seenDirectories = Set<String>()
        for suppliedRoot in roots.sorted(by: { left, right in
            left.path.count == right.path.count ? left.path < right.path : left.path.count < right.path.count
        }) where !control.isCancelled {
            let root = suppliedRoot.resolvingSymlinksInPath().standardizedFileURL
            guard FileManager.default.fileExists(atPath: suppliedRoot.path) else {
                if suppliedRoot.standardizedFileURL.path != defaultDerivedDataRoot.standardizedFileURL.path {
                    warnings.append("Cannot read \(suppliedRoot.path)")
                    control.recordOmitted()
                }
                continue
            }
            guard isAllowedDerivedDataRoot(suppliedRoot) else {
                warnings.append("Invalid root \(suppliedRoot.path)")
                control.recordOmitted()
                continue
            }
            guard seenRoots.insert(root.path).inserted else { continue }
            if scannedRoots.contains(where: { root.path.hasPrefix($0 + "/") || $0.hasPrefix(root.path + "/") }) {
                warnings.append("Overlapping root \(root.path)")
                control.recordOmitted()
                continue
            }
            guard let children = try? FileManager.default.contentsOfDirectory(at: root,
                    includingPropertiesForKeys: nil) else {
                if FileManager.default.fileExists(atPath: root.path) {
                    warnings.append("Cannot read \(root.path)")
                    control.recordOmitted()
                }
                continue
            }
            scannedRoots.append(root.path)
            for child in children where !control.isCancelled {
                let child = URL(fileURLWithPath: child.path, isDirectory: false)
                guard !sharedCacheNames.contains(child.lastPathComponent),
                      FileSafety.isDirectory(child), isProjectDirectory(child),
                      !excludedPaths.contains(where: { child.path == $0 || child.path.hasPrefix($0 + "/") }),
                      FileSafety.isSafeLocation(child, scope: root, category: .developerCache),
                      let before = FileSafety.stamp(at: child) else { continue }
                let identity = "\(before.device):\(before.inode)"
                guard !seenDirectories.contains(identity) else { continue }
                let omittedBefore = control.omittedCount
                guard let metrics = FileScanner.directorySignature(child, control: control),
                      FileSafety.stamp(at: child) == before else {
                    if !control.isCancelled {
                        warnings.append("Cannot verify \(child.path)")
                        if control.omittedCount == omittedBefore { control.recordOmitted() }
                    }
                    continue
                }
                let metadata = projectMetadata(in: child)
                seenDirectories.insert(identity)
                entries.append(ScanEntry(url: child, scope: root, category: .developerCache,
                    stamp: before, estimatedBytes: metrics.bytes,
                    allocatedBytes: metrics.allocatedBytes, risk: .review,
                    note: metadata.path ?? "", lastUsedDate: metadata.lastUsed, isDirectory: true,
                    directorySignature: metrics.digest))
            }
        }
        return ScanReport(entries: entries.sorted { $0.estimatedBytes > $1.estimatedBytes },
                          warnings: warnings, cancelled: control.isCancelled,
                          omittedCount: control.omittedCount)
    }

    public static func archives(at root: URL = defaultArchivesRoot) -> [XcodeArchive] {
        archiveInventory(at: root).items
    }

    public static func isAllowedArchivesRoot(_ suppliedRoot: URL) -> Bool {
        let root = suppliedRoot.standardizedFileURL
        guard root.path != "/", root.path != FileManager.default.homeDirectoryForCurrentUser.path,
              FileSafety.isDirectory(root),
              !FileSafety.hasSymlinkInPath(root, through: URL(fileURLWithPath: "/")) else { return false }
        let otherSources = [defaultDerivedDataRoot, defaultDeviceSupportRoot,
                            FileManager.default.homeDirectoryForCurrentUser
                                .appendingPathComponent("Library/Developer/CoreSimulator/Devices")]
        return !otherSources.contains { source in
            let path = source.standardizedFileURL.path
            return root.path == path || root.path.hasPrefix(path + "/") || path.hasPrefix(root.path + "/")
        }
    }

    public static func archiveInventory(roots: [URL]) -> XcodeStorageInventory<XcodeArchive> {
        var items: [XcodeArchive] = []
        var warnings: [String] = []
        var scanned: [String] = []
        var identities = Set<String>()
        var readableSourceCount = 0
        for supplied in roots {
            let root = supplied.standardizedFileURL
            guard !scanned.contains(root.path) else { continue }
            if root.path == defaultArchivesRoot.standardizedFileURL.path &&
                !FileManager.default.fileExists(atPath: root.path) { continue }
            guard isAllowedArchivesRoot(root) else {
                warnings.append("Invalid archive root \(root.path)")
                continue
            }
            guard !scanned.contains(where: { root.path.hasPrefix($0 + "/") || $0.hasPrefix(root.path + "/") }) else {
                warnings.append("Overlapping root \(root.path)")
                continue
            }
            guard let stamp = FileSafety.stamp(at: root) else {
                warnings.append("Cannot verify \(root.path)")
                continue
            }
            let identity = "\(stamp.device):\(stamp.inode)"
            guard identities.insert(identity).inserted else { continue }
            scanned.append(root.path)
            let inventory = archiveInventory(at: root)
            items.append(contentsOf: inventory.items)
            warnings.append(contentsOf: inventory.warnings)
            if !inventory.warnings.contains("Cannot read \(root.path)") &&
                !inventory.warnings.contains("Cannot verify \(root.path)") {
                readableSourceCount += 1
            }
        }
        return XcodeStorageInventory(items: items.sorted {
            ($0.created ?? .distantPast) > ($1.created ?? .distantPast)
        }, warnings: warnings, readableSourceCount: readableSourceCount)
    }

    public static func archiveInventory(at root: URL = defaultArchivesRoot) -> XcodeStorageInventory<XcodeArchive> {
        guard FileManager.default.fileExists(atPath: root.path) else {
            return XcodeStorageInventory(items: [], warnings: [])
        }
        guard isAllowedArchivesRoot(root), let beforeRoot = FileSafety.stamp(at: root) else {
            return XcodeStorageInventory(items: [], warnings: ["Cannot verify \(root.path)"])
        }
        guard let days = try? FileManager.default.contentsOfDirectory(at: root,
                includingPropertiesForKeys: nil) else {
            return XcodeStorageInventory(items: [], warnings: ["Cannot read \(root.path)"])
        }
        var warnings: [String] = []
        let archives = days.flatMap { day -> [XcodeArchive] in
            guard FileSafety.isDirectory(day) else {
                if FileSafety.hasSymlinkInPath(day, through: root) {
                    warnings.append("Cannot verify \(day.path)")
                }
                return []
            }
            guard !FileSafety.hasSymlinkInPath(day, through: root),
                  let beforeDay = FileSafety.stamp(at: day) else {
                warnings.append("Cannot verify \(day.path)")
                return []
            }
            guard let children = try? FileManager.default.contentsOfDirectory(at: day,
                    includingPropertiesForKeys: nil) else {
                warnings.append("Cannot read \(day.path)")
                return []
            }
            let result = children.compactMap { url -> XcodeArchive? in
                guard url.pathExtension == "xcarchive" else { return nil }
                guard FileSafety.isDirectory(url) else {
                    if FileSafety.hasSymlinkInPath(url, through: root) {
                        warnings.append("Cannot verify \(url.path)")
                    }
                    return nil
                }
                guard !FileSafety.hasSymlinkInPath(url, through: root),
                      let beforeArchive = FileSafety.stamp(at: url) else {
                    warnings.append("Cannot verify \(url.path)")
                    return nil
                }
                let infoURL = url.appendingPathComponent("Info.plist")
                let data = try? Data(contentsOf: infoURL)
                let info = data.flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) }
                    as? [String: Any]
                let app = info?["ApplicationProperties"] as? [String: Any]
                let name = (app?["ApplicationPath"] as? String).map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }
                    ?? url.deletingPathExtension().lastPathComponent
                let size = directorySize(url)
                if !size.complete || FileSafety.stamp(at: url) != beforeArchive {
                    warnings.append("Cannot verify \(url.path)")
                }
                return XcodeArchive(url: url, name: name, created: info?["CreationDate"] as? Date,
                                    logicalBytes: size.logical, allocatedBytes: size.allocated)
            }
            if FileSafety.stamp(at: day) != beforeDay { warnings.append("Cannot verify \(day.path)") }
            return result
        }.sorted { ($0.created ?? .distantPast) > ($1.created ?? .distantPast) }
        if FileSafety.stamp(at: root) != beforeRoot { warnings.append("Cannot verify \(root.path)") }
        return XcodeStorageInventory(items: archives, warnings: warnings)
    }

    public static func deviceSupportInventory(
        at root: URL = defaultDeviceSupportRoot
    ) -> XcodeStorageInventory<XcodeDeviceSupport> {
        guard FileManager.default.fileExists(atPath: root.path) else {
            return XcodeStorageInventory(items: [], warnings: [])
        }
        guard let children = try? FileManager.default.contentsOfDirectory(at: root,
                includingPropertiesForKeys: nil) else {
            return XcodeStorageInventory(items: [], warnings: ["Cannot read \(root.path)"])
        }
        var warnings: [String] = []
        let items = children.compactMap { url -> XcodeDeviceSupport? in
            guard FileSafety.isDirectory(url) else { return nil }
            let size = directorySize(url)
            if !size.complete { warnings.append("Cannot verify \(url.path)") }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            return XcodeDeviceSupport(url: url, logicalBytes: size.logical,
                                      allocatedBytes: size.allocated, modified: modified)
        }.sorted { $0.logicalBytes > $1.logicalBytes }
        return XcodeStorageInventory(items: items, warnings: warnings)
    }

    private static func directorySize(_ root: URL) -> (logical: Int64, allocated: Int64, complete: Bool) {
        var logical: Int64 = 0
        var allocated: Int64 = 0
        var complete = true
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil, errorHandler: { _, _ in
                complete = false
                return true
            }) else { return (0, 0, false) }
        for case let url as URL in enumerator {
            guard let info = FileSafety.metadata(at: url) else {
                complete = false
                enumerator.skipDescendants()
                continue
            }
            if !info.isDirectory {
                logical += info.stamp.size
                allocated += info.stamp.allocatedBytes ?? 0
            }
        }
        return (logical, allocated, complete)
    }

    public static func parseRuntimeImages(_ data: Data) throws -> [XcodeSimulatorRuntime] {
        struct Image: Decodable {
            let identifier: String
            let runtimeIdentifier: String?
            let path: String?
            let version: String?
            let build: String?
            let state: String?
            let sizeBytes: Int64?
            let lastUsedAt: Date?
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([String: Image].self, from: data).values.map { image in
            let platform = image.runtimeIdentifier?.components(separatedBy: ".").last?
                .components(separatedBy: "-").first ?? "Simulator"
            return XcodeSimulatorRuntime(id: image.identifier,
                                         runtimeIdentifier: image.runtimeIdentifier,
                                         path: image.path, name: platform,
                                         version: image.version ?? "", build: image.build ?? "",
                                         state: image.state ?? "", logicalBytes: image.sizeBytes,
                                         lastUsed: image.lastUsedAt)
        }.sorted { ($0.logicalBytes ?? 0) > ($1.logicalBytes ?? 0) }
    }

    public static func runtimeAssociation(
        for runtime: XcodeSimulatorRuntime,
        among runtimes: [XcodeSimulatorRuntime],
        devices: [XcodeSimulator]
    ) -> XcodeRuntimeAssociation? {
        guard let identifier = runtime.runtimeIdentifier, !identifier.isEmpty else { return nil }
        let matchingDevices = devices.filter { $0.runtime == identifier }
        return XcodeRuntimeAssociation(
            deviceCount: matchingDevices.count,
            bootedDeviceCount: matchingDevices.filter { $0.state == "Booted" }.count,
            matchingImageCount: runtimes.filter { $0.runtimeIdentifier == identifier }.count)
    }

    public static func runtimeImages() throws -> [XcodeSimulatorRuntime] {
        try parseRuntimeImages(runSimctl(["runtime", "list", "-j"]))
    }

    public static func parseSimulators(_ data: Data) throws -> [XcodeSimulator] {
        struct Device: Decodable {
            let udid: String
            let name: String
            let state: String
            let isAvailable: Bool?
            let lastUsedAt: Date?
            let dataPath: String?
            let dataPathSize: Int64?
        }
        struct Listing: Decodable { let devices: [String: [Device]] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Listing.self, from: data).devices.flatMap { runtime, devices in
            devices.map { device in
                XcodeSimulator(id: device.udid, name: device.name, runtime: runtime,
                               state: device.state, isAvailable: device.isAvailable ?? false,
                               lastUsed: device.lastUsedAt,
                               dataPath: device.dataPath.map { URL(fileURLWithPath: $0) },
                               dataBytes: device.dataPathSize)
            }
        }.sorted { ($0.dataBytes ?? 0) > ($1.dataBytes ?? 0) }
    }

    public static func simulators() throws -> [XcodeSimulator] {
        try parseSimulators(runSimctl(["list", "devices", "--json"]))
    }

    public static func deleteSimulator(id: String) throws {
        try validateSimulatorDeletion(id: id, in: simulators())
        _ = try runSimctl(["delete", id])
    }

    public static func validateSimulatorDeletion(id: String, in devices: [XcodeSimulator]) throws {
        guard UUID(uuidString: id) != nil,
              let current = devices.first(where: { $0.id == id }), current.canDelete else {
            throw XcodeStorageError.deviceChanged
        }
    }

    private static func runSimctl(_ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl"] + arguments
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let message = error.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw XcodeStorageError.simctlFailed(String(data: message, encoding: .utf8) ?? "simctl failed")
        }
        return data
    }
}

public enum XcodeStorageError: Error, LocalizedError {
    case deviceChanged
    case simctlFailed(String)
    public var errorDescription: String? {
        switch self {
        case .deviceChanged: "Simulator state changed. Refresh the list before deleting."
        case .simctlFailed(let detail): detail
        }
    }
}
