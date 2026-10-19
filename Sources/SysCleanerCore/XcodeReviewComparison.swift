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
