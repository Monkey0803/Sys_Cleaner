import CoreGraphics
import Foundation

public struct SpaceTreemapCell: Identifiable {
    public let id: String
    public let item: SpaceItem?
    public let bytes: Int64
    public let frame: CGRect

    public var isRemainder: Bool { item == nil }
}

public enum SpaceTreemap {
    private struct Node {
        let item: SpaceItem?
        let bytes: Int64
        let area: CGFloat
        var id: String { item?.id ?? "#remaining" }
    }

    public static func layout(_ items: [SpaceItem], in size: CGSize, limit: Int = 18) -> [SpaceTreemapCell] {
        guard size.width > 0, size.height > 0, limit > 0 else { return [] }
        let sorted = items.filter { $0.bytes > 0 }.sorted { $0.bytes > $1.bytes }
        guard !sorted.isEmpty else { return [] }
        let visibleCount = min(sorted.count, sorted.count > limit ? max(0, limit - 1) : limit)
        let visible = Array(sorted.prefix(visibleCount))
        let remainder = sorted.dropFirst(visibleCount).reduce(Int64(0)) { $0 + $1.bytes }
        let total = Double(sorted.reduce(Int64(0)) { $0 + $1.bytes })
        var pending = visible.map { Node(item: $0, bytes: $0.bytes,
                                         area: CGFloat(Double($0.bytes) / total) * size.width * size.height) }
        if remainder > 0 {
            pending.append(Node(item: nil, bytes: remainder,
                                area: CGFloat(Double(remainder) / total) * size.width * size.height))
        }

        var available = CGRect(origin: .zero, size: size)
        var row: [Node] = []
        var cells: [SpaceTreemapCell] = []
        while !pending.isEmpty {
            let next = pending[0]
            let shortSide = min(available.width, available.height)
            if row.isEmpty || worstAspect(row + [next], shortSide: shortSide) <= worstAspect(row, shortSide: shortSide) {
                row.append(pending.removeFirst())
            } else {
                place(row, in: &available, into: &cells)
                row.removeAll(keepingCapacity: true)
            }
        }
        if !row.isEmpty { place(row, in: &available, into: &cells) }
        return cells
    }

    private static func worstAspect(_ nodes: [Node], shortSide: CGFloat) -> CGFloat {
        guard !nodes.isEmpty, shortSide > 0 else { return .infinity }
        let sum = nodes.reduce(CGFloat(0)) { $0 + $1.area }
        guard let smallest = nodes.map(\.area).min(), let largest = nodes.map(\.area).max(),
              smallest > 0 else { return .infinity }
        let square = shortSide * shortSide
        return max(square * largest / (sum * sum), (sum * sum) / (square * smallest))
    }

    private static func place(_ nodes: [Node], in available: inout CGRect,
                              into cells: inout [SpaceTreemapCell]) {
        let area = nodes.reduce(CGFloat(0)) { $0 + $1.area }
        if available.width >= available.height {
            let width = min(available.width, area / max(available.height, 1))
            var y = available.minY
            for (index, node) in nodes.enumerated() {
                let height = index == nodes.count - 1 ? available.maxY - y : node.area / max(width, 1)
                cells.append(SpaceTreemapCell(id: node.id, item: node.item, bytes: node.bytes,
                                              frame: CGRect(x: available.minX, y: y,
                                                            width: width, height: max(0, height))))
                y += height
            }
            available.origin.x += width
            available.size.width = max(0, available.width - width)
        } else {
            let height = min(available.height, area / max(available.width, 1))
            var x = available.minX
            for (index, node) in nodes.enumerated() {
                let width = index == nodes.count - 1 ? available.maxX - x : node.area / max(height, 1)
                cells.append(SpaceTreemapCell(id: node.id, item: node.item, bytes: node.bytes,
                                              frame: CGRect(x: x, y: available.minY,
                                                            width: max(0, width), height: height)))
                x += width
            }
            available.origin.y += height
            available.size.height = max(0, available.height - height)
        }
    }
}
