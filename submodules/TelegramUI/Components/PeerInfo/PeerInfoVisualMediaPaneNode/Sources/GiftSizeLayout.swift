import Foundation

/// Grid units are deliberately independent of points so saved sizes survive rotation.
struct GiftTileSize: Codable, Equatable {
    let width: Int
    let height: Int

    static let standard = GiftTileSize(width: 1, height: 1)
    static let supportedSizes = [standard, GiftTileSize(width: 1, height: 2), GiftTileSize(width: 2, height: 1), GiftTileSize(width: 2, height: 2), GiftTileSize(width: 3, height: 1)]

    var isSupported: Bool {
        return self.width < 3 || self.height == 1
    }

    init(width: Int, height: Int) {
        // A 3×2 footprint is allowed during a drag, but only 3×1 is saved.
        self.width = min(3, max(1, width))
        self.height = min(2, max(1, height))
    }

    private enum CodingKeys: String, CodingKey {
        case width
        case height
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let width = try container.decode(Int.self, forKey: .width)
        let height = try container.decode(Int.self, forKey: .height)
        guard (1 ... 3).contains(width), (1 ... 2).contains(height), width < 3 || height == 1 else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unsupported gift tile size"))
        }
        self.init(width: width, height: height)
    }
}

struct GiftTilePlacement: Equatable {
    let column: Int
    let row: Int
    let size: GiftTileSize
}

struct GiftTileAnchor: Codable, Equatable {
    let key: String
    let scope: String
    let column: Int
    let row: Int
}

enum GiftSizeLayout {
    static func snappedSize(width: Double, height: Double, cellWidth: Double, cellHeight: Double, spacing: Double) -> GiftTileSize {
        guard width.isFinite, height.isFinite, cellWidth.isFinite, cellHeight.isFinite, spacing.isFinite, cellWidth > 0.0, cellHeight > 0.0, spacing >= 0.0 else {
            return .standard
        }
        let rows = height >= cellHeight + (cellHeight + spacing) * 0.5 ? 2 : 1
        let columns: Int
        if rows == 1 && width >= cellWidth + (cellWidth + spacing) * 1.5 {
            columns = 3
        } else {
            columns = width >= cellWidth + (cellWidth + spacing) * 0.5 ? 2 : 1
        }
        return GiftTileSize(width: columns, height: rows)
    }

    static func reservedSize(width: Double, height: Double, cellWidth: Double, cellHeight: Double, spacing: Double) -> GiftTileSize {
        guard width.isFinite, height.isFinite, cellWidth.isFinite, cellHeight.isFinite, spacing.isFinite, cellWidth > 0.0, cellHeight > 0.0, spacing >= 0.0 else {
            return .standard
        }
        let columns = width > cellWidth * 2.0 + spacing + 1.0 ? 3 : (width > cellWidth + 1.0 ? 2 : 1)
        return GiftTileSize(width: columns, height: height > cellHeight + 1.0 ? 2 : 1)
    }

    static func resizeAnchorColumn(initialColumn: Int, initialWidth: Int, width: Int, columns: Int, growsInward: Bool) -> Int {
        let column = growsInward ? initialColumn + initialWidth - width : initialColumn
        return max(0, min(columns - width, column))
    }

    /// First-fit packing fills holes left by tall tiles. The tile being resized can
    /// keep its grid origin while its neighbors move into the remaining spaces.
    static func arrange(sizes: [GiftTileSize], columns: Int, anchor: (index: Int, column: Int, row: Int)? = nil) -> [GiftTilePlacement] {
        let columns = min(32, max(1, columns))
        var rows: [UInt64] = []
        var placements: [GiftTilePlacement?] = Array(repeating: nil, count: sizes.count)

        func occupy(_ placement: GiftTilePlacement) {
            let mask = ((UInt64(1) << placement.size.width) - 1) << placement.column
            while rows.count < placement.row + placement.size.height {
                rows.append(0)
            }
            for row in placement.row ..< placement.row + placement.size.height {
                rows[row] |= mask
            }
        }

        if let anchor, sizes.indices.contains(anchor.index) {
            let size = GiftTileSize(width: min(columns, sizes[anchor.index].width), height: sizes[anchor.index].height)
            let placement = GiftTilePlacement(column: max(0, min(columns - size.width, anchor.column)), row: max(0, anchor.row), size: size)
            placements[anchor.index] = placement
            occupy(placement)
        }

        for (index, requestedSize) in sizes.enumerated() where placements[index] == nil {
            let size = GiftTileSize(width: min(columns, requestedSize.width), height: requestedSize.height)
            var row = 0
            search: while true {
                for column in 0 ... columns - size.width {
                    let mask = ((UInt64(1) << size.width) - 1) << column
                    var isFree = true
                    for occupiedRow in row ..< row + size.height {
                        if occupiedRow < rows.count && rows[occupiedRow] & mask != 0 {
                            isFree = false
                            break
                        }
                    }
                    if isFree {
                        let placement = GiftTilePlacement(column: column, row: row, size: size)
                        placements[index] = placement
                        occupy(placement)
                        break search
                    }
                }
                row += 1
            }
        }
        return placements.compactMap { $0 }
    }
}

final class GiftSizeStore {
    private let defaults: UserDefaults
    private let key: String
    private struct Snapshot: Codable {
        let sizes: [String: GiftTileSize]
        let anchor: GiftTileAnchor?

        private enum CodingKeys: String, CodingKey {
            case sizes
            case anchor
        }

        init(sizes: [String: GiftTileSize], anchor: GiftTileAnchor?) {
            self.sizes = sizes
            self.anchor = anchor
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.sizes = try container.decode([String: GiftTileSize].self, forKey: .sizes)
            // Optional placement metadata must not discard valid saved sizes.
            self.anchor = try? container.decodeIfPresent(GiftTileAnchor.self, forKey: .anchor)
        }
    }

    init(accountId: Int64, peerId: Int64, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.key = "Telegram.ProfileGiftSizes.v1.\(accountId).\(peerId)"
    }

    func load() -> [String: GiftTileSize] {
        guard let data = self.defaults.data(forKey: self.key) else {
            return [:]
        }
        if let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) {
            return snapshot.sizes
        }
        return (try? JSONDecoder().decode([String: GiftTileSize].self, from: data)) ?? [:]
    }

    func loadAnchor() -> GiftTileAnchor? {
        guard let data = self.defaults.data(forKey: self.key), let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data), let anchor = snapshot.anchor, !anchor.key.isEmpty, anchor.column >= 0, anchor.column < 32, anchor.row >= 0, anchor.row < 100_000 else {
            return nil
        }
        return anchor
    }

    func save(_ sizes: [String: GiftTileSize], anchor: GiftTileAnchor? = nil) {
        // Default tiles need no entry. Keep unseen gifts because the list is paginated.
        let customSizes = sizes.filter { $0.value.isSupported && $0.value != .standard }
        if customSizes.isEmpty && anchor == nil {
            self.defaults.removeObject(forKey: self.key)
        } else if let data = try? JSONEncoder().encode(Snapshot(sizes: customSizes, anchor: anchor)) {
            self.defaults.set(data, forKey: self.key)
        }
    }
}
