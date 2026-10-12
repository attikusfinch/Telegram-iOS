import Foundation

private struct Cell: Hashable {
    let column: Int
    let row: Int
}

@main
private enum GiftSizeLayoutTests {
    private static var assertions = 0
    private static let sizes = [
        GiftTileSize(width: 1, height: 1),
        GiftTileSize(width: 1, height: 2),
        GiftTileSize(width: 2, height: 1),
        GiftTileSize(width: 2, height: 2),
        GiftTileSize(width: 3, height: 1)
    ]

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String) {
        assertions += 1
        if !condition() {
            FileHandle.standardError.write(Data("FAIL: \(message())\n".utf8))
            exit(1)
        }
    }

    private static func cells(_ placement: GiftTilePlacement) -> Set<Cell> {
        var result = Set<Cell>()
        for row in placement.row ..< placement.row + placement.size.height {
            for column in placement.column ..< placement.column + placement.size.width {
                result.insert(Cell(column: column, row: row))
            }
        }
        return result
    }

    /// A deliberately simple spatial oracle, independent of the production row bitmasks.
    private static func referenceArrangement(_ sizes: [GiftTileSize], columns requestedColumns: Int, anchor: (index: Int, column: Int, row: Int)? = nil) -> [GiftTilePlacement] {
        let columns = min(32, max(1, requestedColumns))
        var occupied = Set<Cell>()
        var placements = [Int: GiftTilePlacement]()
        if let anchor, sizes.indices.contains(anchor.index) {
            let size = GiftTileSize(width: min(columns, sizes[anchor.index].width), height: sizes[anchor.index].height)
            let placement = GiftTilePlacement(column: max(0, min(columns - size.width, anchor.column)), row: max(0, anchor.row), size: size)
            placements[anchor.index] = placement
            occupied.formUnion(cells(placement))
        }
        for (index, requestedSize) in sizes.enumerated() where placements[index] == nil {
            let size = GiftTileSize(width: min(columns, requestedSize.width), height: requestedSize.height)
            var row = 0
            search: while true {
                for column in 0 ... columns - size.width {
                    let candidate = GiftTilePlacement(column: column, row: row, size: size)
                    let candidateCells = cells(candidate)
                    if occupied.isDisjoint(with: candidateCells) {
                        placements[index] = candidate
                        occupied.formUnion(candidateCells)
                        break search
                    }
                }
                row += 1
            }
        }
        return sizes.indices.map { placements[$0]! }
    }

    private static func checkArrangement(_ sizes: [GiftTileSize], columns requestedColumns: Int, anchor: (index: Int, column: Int, row: Int)? = nil) {
        let columns = min(32, max(1, requestedColumns))
        let placements = GiftSizeLayout.arrange(sizes: sizes, columns: requestedColumns, anchor: anchor)
        expect(placements.count == sizes.count, "Every gift must have one placement")
        expect(placements == GiftSizeLayout.arrange(sizes: sizes, columns: requestedColumns, anchor: anchor), "Packing must be deterministic")
        expect(placements == referenceArrangement(sizes, columns: requestedColumns, anchor: anchor), "Packing must choose the first available cell in row order; sizes=\(sizes), columns=\(requestedColumns), anchor=\(String(describing: anchor))")

        var occupied = Set<Cell>()
        for (index, placement) in placements.enumerated() {
            expect(placement.column >= 0 && placement.row >= 0, "Placement origins cannot be negative")
            expect(placement.column + placement.size.width <= columns, "Tiles must stay inside the grid")
            expect(placement.size == GiftTileSize(width: min(columns, sizes[index].width), height: sizes[index].height), "A tile must retain its requested size, except width on a narrower grid")
            let tileCells = cells(placement)
            expect(occupied.isDisjoint(with: tileCells), "Gift tiles cannot overlap")
            occupied.formUnion(tileCells)
        }
        if let anchor, sizes.indices.contains(anchor.index) {
            let anchored = placements[anchor.index]
            expect(anchored.column == max(0, min(columns - anchored.size.width, anchor.column)), "Active gift must preserve its clamped column")
            expect(anchored.row == max(0, anchor.row), "Active gift must preserve its clamped row")
        }
    }

    private static func forEachSequence(maxLength: Int, body: ([GiftTileSize]) -> Void) {
        func visit(_ sequence: [GiftTileSize]) {
            body(sequence)
            if sequence.count < maxLength {
                for size in sizes {
                    visit(sequence + [size])
                }
            }
        }
        visit([])
    }

    private static func testPacking() {
        expect(GiftTileSize.supportedSizes == sizes, "The editor must offer exactly the original four sizes and the full-width, one-row size")
        expect(sizes.allSatisfy { $0.isSupported }, "All five user sizes must be eligible for persistence")
        let compact = [sizes[3], sizes[1], sizes[2], sizes[0]]
        expect(GiftSizeLayout.arrange(sizes: compact, columns: 3) == [
            GiftTilePlacement(column: 0, row: 0, size: sizes[3]),
            GiftTilePlacement(column: 2, row: 0, size: sizes[1]),
            GiftTilePlacement(column: 0, row: 2, size: sizes[2]),
            GiftTilePlacement(column: 2, row: 2, size: sizes[0])
        ], "Mixed spans should fill a compact 3×3 grid")

        expect(GiftSizeLayout.arrange(sizes: [sizes[1], sizes[2], sizes[0], sizes[0]], columns: 3) == [
            GiftTilePlacement(column: 0, row: 0, size: sizes[1]),
            GiftTilePlacement(column: 1, row: 0, size: sizes[2]),
            GiftTilePlacement(column: 1, row: 1, size: sizes[0]),
            GiftTilePlacement(column: 2, row: 1, size: sizes[0])
        ], "Small gifts must fill holes beside a tall gift")

        expect(GiftSizeLayout.arrange(sizes: [sizes[0], sizes[4], sizes[2], sizes[0]], columns: 3) == [
            GiftTilePlacement(column: 0, row: 0, size: sizes[0]),
            GiftTilePlacement(column: 0, row: 1, size: sizes[4]),
            GiftTilePlacement(column: 1, row: 0, size: sizes[2]),
            GiftTilePlacement(column: 0, row: 2, size: sizes[0])
        ], "A full-width gift must occupy one row while later gifts fill earlier holes")
        expect(cells(GiftTilePlacement(column: 0, row: 0, size: sizes[4])).count == 3, "A full-width gift must occupy three cells in one row")

        let transient = GiftTileSize(width: 3, height: 2)
        expect(!transient.isSupported, "The full-width, two-row live footprint must not become a user size")
        let preview = GiftSizeLayout.arrange(sizes: [sizes[0], transient, sizes[2], sizes[1]], columns: 3, anchor: (1, 2, 0))
        expect(preview[1] == GiftTilePlacement(column: 0, row: 0, size: transient), "A transient full-width, two-row drag must reserve its complete footprint")
        expect(cells(preview[1]).count == 6, "A transient full-width, two-row drag must occupy six cells")
        checkArrangement([sizes[0], transient, sizes[2], sizes[1]], columns: 3, anchor: (1, 2, 0))
        checkArrangement([transient, sizes[4], sizes[3], sizes[1], sizes[0]], columns: 4)

        for columns in [1, 3, 4, 5] {
            forEachSequence(maxLength: 5) { sequence in
                checkArrangement(sequence, columns: columns)
            }
        }
        for columns in [-12, 0, 2, 31, 32, 33, 100] {
            checkArrangement(Array(repeating: sizes, count: 10).flatMap { $0 }, columns: columns)
        }
        expect(GiftTileSize(width: -10, height: 0) == .standard, "Constructed sizes must clamp to at least one cell")
        expect(GiftTileSize(width: 100, height: 100) == transient, "Constructed sizes must clamp to three columns and two rows for live packing")
    }

    private static func testAnchors() {
        for columns in [1, 3, 4, 5] {
            forEachSequence(maxLength: 4) { sequence in
                for index in sequence.indices {
                    for column in [-1, 0, columns - 1, columns + 1] {
                        for row in [-1, 0, 2] {
                            checkArrangement(sequence, columns: columns, anchor: (index, column, row))
                        }
                    }
                }
                for invalidIndex in [-1, sequence.count] {
                    expect(GiftSizeLayout.arrange(sizes: sequence, columns: columns, anchor: (invalidIndex, 3, 2)) == GiftSizeLayout.arrange(sizes: sequence, columns: columns), "An invalid active index must be ignored")
                }
            }
        }
        for size in sizes {
            checkArrangement([sizes[0], sizes[1], size, sizes[2]], columns: 3, anchor: (2, 2, 1))
        }
    }

    private static func testSnapping() {
        for (cellWidth, cellHeight, spacing) in [(100.0, 100.0, 10.0), (118.0, 118.0, 10.0), (180.0, 104.0, 10.0), (70.5, 90.25, 0.0)] {
            for expected in sizes {
                let width = cellWidth * Double(expected.width) + spacing * Double(expected.width - 1)
                let height = cellHeight * Double(expected.height) + spacing * Double(expected.height - 1)
                expect(GiftSizeLayout.snappedSize(width: width, height: height, cellWidth: cellWidth, cellHeight: cellHeight, spacing: spacing) == expected, "Each supported span must snap to itself, including rectangular base cells")
            }
            let midpointWidth = cellWidth + (cellWidth + spacing) * 0.5
            let midpointHeight = cellHeight + (cellHeight + spacing) * 0.5
            for widthOffset in [-0.001, 0.0, 0.001] {
                for heightOffset in [-0.001, 0.0, 0.001] {
                    let expected = GiftTileSize(width: widthOffset >= 0 ? 2 : 1, height: heightOffset >= 0 ? 2 : 1)
                    expect(GiftSizeLayout.snappedSize(width: midpointWidth + widthOffset, height: midpointHeight + heightOffset, cellWidth: cellWidth, cellHeight: cellHeight, spacing: spacing) == expected, "Width and height must independently snap at their exact midpoint")
                }
            }
            let wideMidpoint = cellWidth * 2.0 + spacing + (cellWidth + spacing) * 0.5
            for widthOffset in [-0.001, 0.0, 0.001] {
                let expected = widthOffset >= 0.0 ? sizes[4] : sizes[2]
                expect(GiftSizeLayout.snappedSize(width: wideMidpoint + widthOffset, height: cellHeight, cellWidth: cellWidth, cellHeight: cellHeight, spacing: spacing) == expected, "One-row gifts must snap to three columns at the 2.5-column midpoint")
                for heightOffset in [-0.001, 0.0, 0.001] {
                    let expected = heightOffset < 0.0 ? (widthOffset >= 0.0 ? sizes[4] : sizes[2]) : sizes[3]
                    expect(GiftSizeLayout.snappedSize(width: wideMidpoint + widthOffset, height: midpointHeight + heightOffset, cellWidth: cellWidth, cellHeight: cellHeight, spacing: spacing) == expected, "A three-column drag must snap back to two columns when its height reaches two rows")
                }
            }
            expect(GiftSizeLayout.snappedSize(width: -100, height: -100, cellWidth: cellWidth, cellHeight: cellHeight, spacing: spacing) == .standard, "Undersized drag dimensions must clamp to one cell")
            expect(GiftSizeLayout.snappedSize(width: 1_000_000, height: cellHeight, cellWidth: cellWidth, cellHeight: cellHeight, spacing: spacing) == sizes[4], "An oversized one-row drag must clamp to three columns")
            expect(GiftSizeLayout.snappedSize(width: 1_000_000, height: 1_000_000, cellWidth: cellWidth, cellHeight: cellHeight, spacing: spacing) == sizes[3], "An oversized two-row drag must clamp to two columns")
        }

        let invalid: [(Double, Double, Double, Double, Double)] = [
            (.nan, 210, 100, 100, 10),
            (210, .infinity, 100, 100, 10),
            (-.infinity, 210, 100, 100, 10),
            (210, 210, 0, 100, 10),
            (210, 210, 100, -1, 10),
            (210, 210, .nan, 100, 10),
            (210, 210, .infinity, 100, 10),
            (210, 210, 100, .infinity, 10),
            (210, 210, 100, 100, -1),
            (210, 210, 100, 100, .nan),
            (210, 210, 100, 100, .infinity)
        ]
        for (width, height, cellWidth, cellHeight, spacing) in invalid {
            expect(GiftSizeLayout.snappedSize(width: width, height: height, cellWidth: cellWidth, cellHeight: cellHeight, spacing: spacing) == .standard, "Nonfinite or invalid grid metrics must safely fall back to standard")
            expect(GiftSizeLayout.reservedSize(width: width, height: height, cellWidth: cellWidth, cellHeight: cellHeight, spacing: spacing) == .standard, "Nonfinite or invalid live packing metrics must safely fall back to standard")
        }
    }

    private static func testLivePackingFootprints() {
        for (cellWidth, cellHeight, spacing) in [(100.0, 100.0, 10.0), (180.0, 104.0, 10.0), (70.5, 90.25, 0.0)] {
            for expected in sizes + [GiftTileSize(width: 3, height: 2)] {
                let width = cellWidth * Double(expected.width) + spacing * Double(expected.width - 1)
                let height = cellHeight * Double(expected.height) + spacing * Double(expected.height - 1)
                expect(GiftSizeLayout.reservedSize(width: width, height: height, cellWidth: cellWidth, cellHeight: cellHeight, spacing: spacing) == expected, "Each snapped rectangle must reserve its complete live footprint")
            }
            for widthOffset in [-0.001, 0.0, 0.001] {
                for heightOffset in [-0.001, 0.0, 0.001] {
                    let width = cellWidth * 2.0 + spacing + 1.0 + widthOffset
                    let height = cellHeight + 1.0 + heightOffset
                    let expected = GiftTileSize(width: widthOffset > 0.0 ? 3 : 2, height: heightOffset > 0.0 ? 2 : 1)
                    let reserved = GiftSizeLayout.reservedSize(width: width, height: height, cellWidth: cellWidth, cellHeight: cellHeight, spacing: spacing)
                    expect(reserved == expected, "Live packing must reserve a third column and second row immediately beyond the one-point tolerance")
                    checkArrangement([sizes[0], reserved, sizes[1], sizes[3]], columns: 3, anchor: (1, 2, 0))
                }
            }
            expect(GiftSizeLayout.reservedSize(width: cellWidth + 1.0, height: cellHeight, cellWidth: cellWidth, cellHeight: cellHeight, spacing: spacing) == sizes[0], "The one-point tolerance must keep a standard gift in one column")
            expect(GiftSizeLayout.reservedSize(width: cellWidth + 1.001, height: cellHeight, cellWidth: cellWidth, cellHeight: cellHeight, spacing: spacing) == sizes[2], "A growing standard gift must immediately reserve its neighboring column")
            expect(GiftSizeLayout.reservedSize(width: -100.0, height: -100.0, cellWidth: cellWidth, cellHeight: cellHeight, spacing: spacing) == .standard, "An undersized live footprint must clamp to one cell")
            expect(GiftSizeLayout.reservedSize(width: 1_000_000.0, height: 1_000_000.0, cellWidth: cellWidth, cellHeight: cellHeight, spacing: spacing) == GiftTileSize(width: 3, height: 2), "An oversized live footprint must reserve three columns and two rows before snapping")
        }
    }

    private static func testPersistence() {
        let suite = "Telegram.GiftSizeLayoutTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let key = "Telegram.ProfileGiftSizes.v1.100.200"
        let store = GiftSizeStore(accountId: 100, peerId: 200, defaults: defaults)
        expect(store.load().isEmpty, "A fresh profile has default sizes")
        let saved = ["visible": sizes[2], "unseen-paginated-gift": sizes[1], "default": sizes[0]]
        store.save(saved)
        let expected = ["visible": sizes[2], "unseen-paginated-gift": sizes[1]]
        expect(store.load() == expected, "Only custom spans should be persisted")
        let recreated = GiftSizeStore(accountId: 100, peerId: 200, defaults: UserDefaults(suiteName: suite)!)
        expect(recreated.load() == expected, "Sizes must survive store and defaults recreation")
        expect(GiftSizeStore(accountId: 101, peerId: 200, defaults: defaults).load().isEmpty, "Accounts must have separate local sizes")
        expect(GiftSizeStore(accountId: 100, peerId: 201, defaults: defaults).load().isEmpty, "Profiles must have separate local sizes")

        var working = store.load()
        working["visible"] = sizes[3]
        expect(store.load() == expected, "Editing a draft must not persist before Save")
        working = store.load()
        expect(working == expected, "Cancel can recover the saved state without side effects")
        working["visible"] = sizes[0]
        store.save(working)
        expect(store.load() == ["unseen-paginated-gift": sizes[1]], "Save must keep entries from unseen pages and remove restored default sizes")

        GiftSizeStore(accountId: 101, peerId: 200, defaults: defaults).save(["other": sizes[3]])
        store.save(["unseen-paginated-gift": sizes[0]])
        expect(store.load().isEmpty && defaults.object(forKey: key) == nil, "No custom sizes must remove the profile's defaults key")
        expect(GiftSizeStore(accountId: 101, peerId: 200, defaults: defaults).load() == ["other": sizes[3]], "Removing one profile must preserve another account")

        let originalSizes = ["square": sizes[0], "tall": sizes[1], "wide": sizes[2], "large": sizes[3]]
        defaults.set(try! JSONEncoder().encode(originalSizes), forKey: key)
        expect(store.load() == originalSizes, "All four original sizes must remain readable from legacy JSON")
        defaults.set(Data("{\"full-width\":{\"width\":3,\"height\":1}}".utf8), forKey: key)
        expect(store.load() == ["full-width": sizes[4]], "A three-column, one-row gift must decode from legacy size JSON")
        store.save(["full-width": sizes[4]])
        expect(recreated.load() == ["full-width": sizes[4]], "A full-width gift must survive Save and store recreation")
        store.save(["full-width": sizes[4], "transient": GiftTileSize(width: 3, height: 2)])
        expect(recreated.load() == ["full-width": sizes[4]], "The transient three-column, two-row footprint must never be persisted")
        store.save(["transient": GiftTileSize(width: 3, height: 2)])
        expect(defaults.object(forKey: key) == nil, "Saving only unsupported transient footprints must remove the snapshot")

        let invalidPayloads = [
            "not json",
            "[]",
            "null",
            "{\"gift\":{\"width\":0,\"height\":1}}",
            "{\"gift\":{\"width\":4,\"height\":1}}",
            "{\"gift\":{\"width\":3,\"height\":2}}",
            "{\"gift\":{\"width\":1,\"height\":-1}}",
            "{\"gift\":{\"width\":1,\"height\":3}}",
            "{\"gift\":{\"width\":\"2\",\"height\":1}}",
            "{\"gift\":{\"width\":1}}",
            "{\"gift\":{\"width\":1,\"height\":null}}"
        ]
        for payload in invalidPayloads {
            defaults.set(Data(payload.utf8), forKey: key)
            expect(store.load().isEmpty, "Malformed or unsupported persisted sizes must safely fall back to defaults: \(payload)")
        }
        defaults.set("unexpected defaults value", forKey: key)
        expect(store.load().isEmpty, "Non-data defaults values must safely fall back")
        store.save(["recovered": sizes[3]])
        expect(recreated.load() == ["recovered": sizes[3]], "A subsequent Save must recover from corrupt data")
    }

    private static func testAnchorPersistence() {
        let suite = "Telegram.GiftSizeAnchorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "Telegram.ProfileGiftSizes.v1.42.84"
        let store = GiftSizeStore(accountId: 42, peerId: 84, defaults: defaults)
        let scope = "0:0:date:3"
        let anchor = GiftTileAnchor(key: "third", scope: scope, column: 1, row: 0)
        let customSizes = ["third": sizes[2]]

        expect(store.loadAnchor() == nil, "A fresh profile must have no anchor")
        store.save(customSizes, anchor: anchor)
        expect(store.load() == customSizes && store.loadAnchor() == anchor, "Sizes and the active tile origin must save together")
        let recreated = GiftSizeStore(accountId: 42, peerId: 84, defaults: UserDefaults(suiteName: suite)!)
        expect(recreated.load() == customSizes && recreated.loadAnchor() == anchor, "The anchor must survive recreation alongside custom sizes")
        expect(GiftSizeStore(accountId: 43, peerId: 84, defaults: defaults).loadAnchor() == nil, "An anchor cannot leak into another account")
        expect(GiftSizeStore(accountId: 42, peerId: 85, defaults: defaults).loadAnchor() == nil, "An anchor cannot leak into another profile")

        let giftKeys = ["first", "second", "third"]
        let completedResize = giftKeys.map { customSizes[$0] ?? .standard }
        let releasePlacement = GiftSizeLayout.arrange(sizes: completedResize, columns: 3, anchor: (2, 1, 0))
        expect(releasePlacement[2] == GiftTilePlacement(column: 1, row: 0, size: sizes[2]), "The rightmost card expanded inward must remain in the first row after release")
        let loadedSizes = recreated.load()
        let loadedAnchor = recreated.loadAnchor()!
        let recreatedPlacement = GiftSizeLayout.arrange(sizes: giftKeys.map { loadedSizes[$0] ?? .standard }, columns: 3, anchor: (giftKeys.firstIndex(of: loadedAnchor.key)!, loadedAnchor.column, loadedAnchor.row))
        expect(recreatedPlacement == releasePlacement, "Save and recreation must preserve the completed resize layout")
        expect(GiftSizeLayout.arrange(sizes: completedResize, columns: 3)[2].row == 1, "The regression scenario must distinguish anchored continuity from the old release jump")
        checkArrangement(completedResize, columns: 3, anchor: (2, loadedAnchor.column, loadedAnchor.row))

        var draftSizes = store.load()
        var draftAnchor = store.loadAnchor()
        draftSizes["third"] = sizes[3]
        draftAnchor = GiftTileAnchor(key: "second", scope: scope, column: 0, row: 2)
        expect(draftSizes != store.load() && draftAnchor != store.loadAnchor(), "A draft must not change either part of the saved snapshot")
        draftSizes = store.load()
        draftAnchor = store.loadAnchor()
        expect(draftSizes == customSizes && draftAnchor == anchor, "Cancel must recover the original sizes and original anchor")

        store.save([:], anchor: anchor)
        expect(store.load().isEmpty && store.loadAnchor() == anchor && defaults.data(forKey: key) != nil, "An all-default layout may still retain an anchor for continuity")
        store.save([:])
        expect(defaults.object(forKey: key) == nil && store.loadAnchor() == nil, "No sizes and no anchor must remove the snapshot")

        defaults.set(try! JSONEncoder().encode(customSizes), forKey: key)
        expect(store.load() == customSizes && store.loadAnchor() == nil, "Legacy size dictionaries must decode without fabricating an anchor")
        store.save(store.load(), anchor: anchor)
        expect(recreated.load() == customSizes && recreated.loadAnchor() == anchor, "Saving a legacy dictionary must migrate it to the current snapshot")

        for missingAnchor in ["", ",\"anchor\":null"] {
            defaults.set(Data("{\"sizes\":{\"third\":{\"width\":2,\"height\":1}}\(missingAnchor)}".utf8), forKey: key)
            expect(store.load() == customSizes && store.loadAnchor() == nil, "Absent or null optional anchors must preserve valid saved sizes")
        }
        let invalidAnchors = [
            GiftTileAnchor(key: "", scope: scope, column: 1, row: 0),
            GiftTileAnchor(key: "third", scope: scope, column: -1, row: 0),
            GiftTileAnchor(key: "third", scope: scope, column: 32, row: 0),
            GiftTileAnchor(key: "third", scope: scope, column: Int.max, row: 0),
            GiftTileAnchor(key: "third", scope: scope, column: 1, row: -1),
            GiftTileAnchor(key: "third", scope: scope, column: 1, row: 100_000),
            GiftTileAnchor(key: "third", scope: scope, column: 1, row: Int.max)
        ]
        for invalidAnchor in invalidAnchors {
            store.save(customSizes, anchor: invalidAnchor)
            expect(store.load() == customSizes && store.loadAnchor() == nil, "Invalid anchor coordinates or empty keys must be ignored without discarding custom sizes")
        }
        let malformedAnchors = [
            "42",
            "[]",
            "{\"key\":\"third\",\"scope\":\"scope\",\"column\":1}",
            "{\"key\":\"third\",\"scope\":\"scope\",\"column\":1,\"row\":\"wrong\"}"
        ]
        for malformedAnchor in malformedAnchors {
            defaults.set(Data("{\"sizes\":{\"third\":{\"width\":2,\"height\":1}},\"anchor\":\(malformedAnchor)}".utf8), forKey: key)
            expect(store.load() == customSizes && store.loadAnchor() == nil, "Malformed optional anchor metadata must not lose valid custom sizes")
        }
    }

    private static func testFullWidthAnchorPersistence() {
        let suite = "Telegram.FullWidthGiftAnchorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = GiftSizeStore(accountId: 42, peerId: 84, defaults: defaults)
        let giftKeys = ["left", "middle", "right"]

        for index in [1, 2] {
            let anchor = GiftTileAnchor(key: giftKeys[index], scope: "0:0:date:3", column: index, row: 0)
            let customSizes = [giftKeys[index]: sizes[4]]
            let completedResize = giftKeys.map { customSizes[$0] ?? .standard }
            let placements = GiftSizeLayout.arrange(sizes: completedResize, columns: 3, anchor: (index, anchor.column, anchor.row))
            expect(placements[index] == GiftTilePlacement(column: 0, row: 0, size: sizes[4]), "A middle or right gift expanded to full width must shift inward and preserve its row")
            expect(placements.enumerated().filter { $0.offset != index }.allSatisfy { $0.element.row == 1 }, "The neighboring gifts must move below a full-width anchored gift")
            checkArrangement(completedResize, columns: 3, anchor: (index, anchor.column, anchor.row))

            store.save(customSizes, anchor: anchor)
            let recreated = GiftSizeStore(accountId: 42, peerId: 84, defaults: UserDefaults(suiteName: suite)!)
            expect(recreated.load() == customSizes && recreated.loadAnchor() == anchor, "The full-width span and existing middle or right anchor must survive recreation")
            let loadedAnchor = recreated.loadAnchor()!
            let loadedSizes = recreated.load()
            let restored = GiftSizeLayout.arrange(sizes: giftKeys.map { loadedSizes[$0] ?? .standard }, columns: 3, anchor: (giftKeys.firstIndex(of: loadedAnchor.key)!, loadedAnchor.column, loadedAnchor.row))
            expect(restored == placements, "Loading a saved middle or right anchor must retain the full-width gift layout")
            expect(GiftSizeLayout.arrange(sizes: completedResize, columns: 3)[index].row == 1, "The full-width regression scenario must expose a missing anchor")
        }
    }

    private static func testInwardResizeAnchors() {
        let suite = "Telegram.InwardGiftResizeAnchorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = GiftSizeStore(accountId: 42, peerId: 84, defaults: defaults)
        let growthCases = [
            (columns: 3, initialColumn: 1, expectedColumns: [1, 0, 0]),
            (columns: 3, initialColumn: 2, expectedColumns: [2, 1, 0]),
            (columns: 4, initialColumn: 1, expectedColumns: [1, 0, 0]),
            (columns: 4, initialColumn: 2, expectedColumns: [2, 1, 0]),
            (columns: 4, initialColumn: 3, expectedColumns: [3, 2, 1]),
            (columns: 5, initialColumn: 2, expectedColumns: [2, 1, 0]),
            (columns: 5, initialColumn: 4, expectedColumns: [4, 3, 2])
        ]
        for scenario in growthCases {
            let index = scenario.initialColumn
            let giftKeys = (0 ..< scenario.columns + 6).map { "gift-\($0)" }
            for width in 1 ... 3 {
                let expectedColumn = scenario.expectedColumns[width - 1]
                let column = GiftSizeLayout.resizeAnchorColumn(initialColumn: scenario.initialColumn, initialWidth: 1, width: width, columns: scenario.columns, growsInward: true)
                expect(column == expectedColumn, "An inward \(width)-column resize from column \(scenario.initialColumn) on a \(scenario.columns)-column grid must reserve the actual dragged origin")
                let size = GiftTileSize(width: width, height: 1)
                var resized = Array(repeating: GiftTileSize.standard, count: giftKeys.count)
                resized[index] = size
                let placements = GiftSizeLayout.arrange(sizes: resized, columns: scenario.columns, anchor: (index, column, 0))
                let actualFootprint = GiftTilePlacement(column: expectedColumn, row: 0, size: size)
                expect(placements[index] == actualFootprint, "Live packing must use the resized visual footprint instead of the gift's original column")
                for (neighborIndex, neighbor) in placements.enumerated() where neighborIndex != index {
                    expect(cells(neighbor).isDisjoint(with: cells(actualFootprint)), "A neighbor must never occupy the inward drag footprint while growing from one to three columns")
                }
                checkArrangement(resized, columns: scenario.columns, anchor: (index, column, 0))

                let anchor = GiftTileAnchor(key: giftKeys[index], scope: "0:0:date:\(scenario.columns)", column: column, row: 0)
                store.save([giftKeys[index]: size], anchor: anchor)
                let recreated = GiftSizeStore(accountId: 42, peerId: 84, defaults: UserDefaults(suiteName: suite)!)
                let loadedAnchor = recreated.loadAnchor()!
                expect(loadedAnchor == anchor, "Save must retain the inward resize origin on narrow and wide grids")
                let loadedSizes = recreated.load()
                let restored = GiftSizeLayout.arrange(sizes: giftKeys.map { loadedSizes[$0] ?? .standard }, columns: scenario.columns, anchor: (index, loadedAnchor.column, loadedAnchor.row))
                expect(restored == placements, "Save and recreation must preserve the completed inward resize layout")
            }
        }

        let shrinkCases = [
            (columns: 3, initialColumn: 0, initialWidth: 2, expectedColumn: 1),
            (columns: 4, initialColumn: 1, initialWidth: 2, expectedColumn: 2),
            (columns: 5, initialColumn: 2, initialWidth: 3, expectedColumn: 4)
        ]
        for scenario in shrinkCases {
            let column = GiftSizeLayout.resizeAnchorColumn(initialColumn: scenario.initialColumn, initialWidth: scenario.initialWidth, width: 1, columns: scenario.columns, growsInward: true)
            expect(column == scenario.expectedColumn, "An inward shrink must preserve the gift's original right edge")
            checkArrangement([sizes[0], sizes[0], sizes[1], sizes[3]], columns: scenario.columns, anchor: (0, column, 0))
        }

        let outwardCases = [
            (columns: 3, initialColumn: 0, width: 2, expectedColumn: 0),
            (columns: 3, initialColumn: 1, width: 2, expectedColumn: 1),
            (columns: 3, initialColumn: 2, width: 2, expectedColumn: 1),
            (columns: 4, initialColumn: 3, width: 3, expectedColumn: 1),
            (columns: 5, initialColumn: 2, width: 3, expectedColumn: 2),
            (columns: 5, initialColumn: 4, width: 3, expectedColumn: 2)
        ]
        for scenario in outwardCases {
            let column = GiftSizeLayout.resizeAnchorColumn(initialColumn: scenario.initialColumn, initialWidth: 1, width: scenario.width, columns: scenario.columns, growsInward: false)
            expect(column == scenario.expectedColumn, "An outward resize must retain its left edge and clamp only at the grid boundary")
            checkArrangement([GiftTileSize(width: scenario.width, height: 1), sizes[0], sizes[1], sizes[3]], columns: scenario.columns, anchor: (0, column, 0))
        }
    }

    static func main() {
        testPacking()
        testAnchors()
        testSnapping()
        testLivePackingFootprints()
        testPersistence()
        testAnchorPersistence()
        testFullWidthAnchorPersistence()
        testInwardResizeAnchors()
        print("GiftSizeLayoutTests passed (\(assertions) assertions)")
    }
}
