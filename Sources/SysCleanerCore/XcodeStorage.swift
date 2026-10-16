import Foundation

public struct XcodeArchive: Identifiable, Sendable {
    public let url: URL
    public let name: String
    public let created: Date?
    public let logicalBytes: Int64
    public let allocatedBytes: Int64
    public var id: String { url.path }
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

public enum XcodeStorage {
    public static var defaultDerivedDataRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Developer/Xcode/DerivedData")
    }

    public static var defaultArchivesRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Developer/Xcode/Archives")
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
        var seen = Set<String>()
        for suppliedRoot in roots where !control.isCancelled {
            let root = suppliedRoot.resolvingSymlinksInPath().standardizedFileURL
            let home = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().standardizedFileURL.path
            guard root.lastPathComponent == "DerivedData", root.path.hasPrefix(home + "/"),
                  !FileSafety.hasSymlinkInPath(suppliedRoot, through: URL(fileURLWithPath: home)) else { continue }
            guard seen.insert(root.path).inserted else { continue }
            guard let children = try? FileManager.default.contentsOfDirectory(at: root,
                    includingPropertiesForKeys: nil) else {
                if FileManager.default.fileExists(atPath: root.path) { warnings.append("Cannot read \(root.path)") }
                continue
            }
            for child in children where !control.isCancelled {
                let child = URL(fileURLWithPath: child.path, isDirectory: false)
                guard FileSafety.isDirectory(child), isProjectDirectory(child),
                      !excludedPaths.contains(where: { child.path == $0 || child.path.hasPrefix($0 + "/") }),
                      FileSafety.isSafeLocation(child, scope: root, category: .developerCache),
                      let before = FileSafety.stamp(at: child) else { continue }
                guard let metrics = FileScanner.directorySignature(child, control: control),
                      FileSafety.stamp(at: child) == before else {
                    if !control.isCancelled { warnings.append("Cannot read \(child.path)"); control.recordOmitted() }
                    continue
                }
                let metadata = projectMetadata(in: child)
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
        guard let days = try? FileManager.default.contentsOfDirectory(at: root,
                includingPropertiesForKeys: nil) else { return [] }
        return days.flatMap { day -> [XcodeArchive] in
            guard let children = try? FileManager.default.contentsOfDirectory(at: day,
                    includingPropertiesForKeys: nil) else { return [] }
            return children.compactMap { url in
                guard url.pathExtension == "xcarchive", FileSafety.isDirectory(url) else { return nil }
                let infoURL = url.appendingPathComponent("Info.plist")
                let data = try? Data(contentsOf: infoURL)
                let info = data.flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) }
                    as? [String: Any]
                let app = info?["ApplicationProperties"] as? [String: Any]
                let name = (app?["ApplicationPath"] as? String).map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }
                    ?? url.deletingPathExtension().lastPathComponent
                let size = directorySize(url)
                return XcodeArchive(url: url, name: name, created: info?["CreationDate"] as? Date,
                                    logicalBytes: size.0, allocatedBytes: size.1)
            }
        }.sorted { ($0.created ?? .distantPast) > ($1.created ?? .distantPast) }
    }

    private static func directorySize(_ root: URL) -> (Int64, Int64) {
        var logical: Int64 = 0
        var allocated: Int64 = 0
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return (0, 0) }
        for case let url as URL in enumerator {
            guard let info = FileSafety.metadata(at: url) else { enumerator.skipDescendants(); continue }
            if !info.isDirectory {
                logical += info.stamp.size
                allocated += info.stamp.allocatedBytes ?? 0
            }
        }
        return (logical, allocated)
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
