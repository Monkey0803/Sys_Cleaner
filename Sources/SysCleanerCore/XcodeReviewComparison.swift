import Foundation

public enum XcodeReviewCategory: String, CaseIterable, Sendable {
    case projects, sharedCaches, simulators, archives, runtimes, deviceSupport, otherData
}

public struct XcodeReviewMeasure: Equatable, Sendable {
    public let count: Int
    public let estimatedBytes: Int64?
    public let complete: Bool

    public init(count: Int, estimatedBytes: Int64?, complete: Bool) {
        self.count = count
        self.estimatedBytes = estimatedBytes
        self.complete = complete
    }
}

public struct XcodeReviewSnapshot: Sendable {
    public let measures: [XcodeReviewCategory: XcodeReviewMeasure]

    public init(measures: [XcodeReviewCategory: XcodeReviewMeasure]) {
        self.measures = measures
    }

    /// A comparison is meaningful only for the same complete source on both sides.
    public func comparison(to newer: Self, category: XcodeReviewCategory)
        -> (before: XcodeReviewMeasure, after: XcodeReviewMeasure)? {
        guard let before = measures[category], let after = newer.measures[category],
              before.complete, after.complete else { return nil }
        return (before, after)
    }
}

public struct XcodeProjectSnapshot: Codable, Sendable {
    public struct Project: Codable, Sendable {
        public let id: String
        public let directoryPaths: [String]
        public let logicalBytes: Int64
    }

    public let scanID: UUID
    public let capturedAt: Date
    public let sourcePaths: [String]
    public let excludedPaths: [String]
    public let projects: [Project]

    public static func capture(report: ScanReport, scanID: UUID, capturedAt: Date,
                               roots: [URL], excludedPaths: [String]) -> Self? {
        guard !report.cancelled, report.warnings.isEmpty, report.omittedCount == 0 else { return nil }
        let projects = XcodeStorage.projectGroups(report.entries).compactMap { group -> Project? in
            guard group.projectPath != nil else { return nil }
            return Project(id: group.id, directoryPaths: group.entries.map { $0.url.standardizedFileURL.path },
                           logicalBytes: group.logicalBytes)
        }.sorted { $0.id < $1.id }
        return Self(scanID: scanID, capturedAt: capturedAt,
                    sourcePaths: Array(Set(roots.map { $0.standardizedFileURL.path })).sorted(),
                    excludedPaths: Array(Set(excludedPaths)).sorted(), projects: projects)
    }
}

public enum XcodeProjectTrend: Equatable, Sendable {
    case increased(Int64), decreased(Int64), unchanged, newProject, reattributed
}

public enum XcodeProjectComparison: Sendable {
    case noPrevious
    case sourcesChanged
    case comparable(previousDate: Date, trends: [String: XcodeProjectTrend], disappearedCount: Int)

    public func trend(for id: String) -> XcodeProjectTrend? {
        if case .comparable(_, let trends, _) = self { return trends[id] }
        return nil
    }
}

public struct XcodeProjectHistory: Codable, Sendable {
    public private(set) var snapshots: [XcodeProjectSnapshot]

    public init(snapshots: [XcodeProjectSnapshot] = []) {
        self.snapshots = snapshots
    }

    public mutating func record(_ current: XcodeProjectSnapshot) -> XcodeProjectComparison {
        guard snapshots.last?.scanID != current.scanID else { return .noPrevious }
        let comparison: XcodeProjectComparison
        if let previous = snapshots.last {
            if previous.sourcePaths != current.sourcePaths || previous.excludedPaths != current.excludedPaths {
                comparison = .sourcesChanged
            } else {
                let prior = Dictionary(uniqueKeysWithValues: previous.projects.map { ($0.id, $0) })
                let currentIDs = Set(current.projects.map(\.id))
                let currentDirectoryPaths = Set(current.projects.flatMap(\.directoryPaths))
                var trends: [String: XcodeProjectTrend] = [:]
                for project in current.projects {
                    if let before = prior[project.id] {
                        let delta = project.logicalBytes - before.logicalBytes
                        trends[project.id] = delta > 0 ? .increased(delta)
                            : delta < 0 ? .decreased(-delta) : .unchanged
                    } else if previous.projects.contains(where: {
                        !Set($0.directoryPaths).isDisjoint(with: project.directoryPaths)
                    }) {
                        trends[project.id] = .reattributed
                    } else {
                        trends[project.id] = .newProject
                    }
                }
                comparison = .comparable(previousDate: previous.capturedAt, trends: trends,
                    disappearedCount: previous.projects.filter {
                        !currentIDs.contains($0.id) &&
                        Set($0.directoryPaths).isDisjoint(with: currentDirectoryPaths)
                    }.count)
            }
        } else {
            comparison = .noPrevious
        }
        snapshots.append(current)
        if snapshots.count > 30 { snapshots.removeFirst(snapshots.count - 30) }
        return comparison
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
