import Foundation

public struct SpacePieSlice: Identifiable {
    public let id: String
    public let item: SpaceItem?
    public let bytes: Int64
    public let fraction: Double

    public var isOther: Bool { item == nil }
}

public enum SpacePie {
    public static func slices(_ items: [SpaceItem], individualLimit: Int = 6) -> [SpacePieSlice] {
        guard individualLimit > 0 else { return [] }
        let positive = items.filter { $0.bytes > 0 }
        let sorted = positive.filter { !$0.isOther }.sorted {
            if $0.bytes != $1.bytes { return $0.bytes > $1.bytes }
            return $0.id < $1.id
        }
        let visible = Array(sorted.prefix(individualLimit))
        let total = positive.reduce(Int64(0)) { $0 + $1.bytes }
        guard total > 0 else { return [] }

        var result = visible.map {
            SpacePieSlice(id: $0.id, item: $0, bytes: $0.bytes,
                          fraction: Double($0.bytes) / Double(total))
        }
        let otherBytes = total - visible.reduce(Int64(0)) { $0 + $1.bytes }
        if otherBytes > 0 {
            result.append(SpacePieSlice(id: "#other", item: nil, bytes: otherBytes,
                                        fraction: Double(otherBytes) / Double(total)))
        }
        result.sort {
            if $0.bytes != $1.bytes { return $0.bytes > $1.bytes }
            if $0.isOther != $1.isOther { return !$0.isOther }
            return $0.id < $1.id
        }
        return result
    }

    public static func slice(at fraction: Double, in slices: [SpacePieSlice]) -> SpacePieSlice? {
        guard fraction >= 0, fraction < 1 else { return nil }
        var upperBound = 0.0
        for slice in slices {
            upperBound += slice.fraction
            if fraction < upperBound { return slice }
        }
        return slices.last // Account for floating-point rounding at the final boundary.
    }
}
