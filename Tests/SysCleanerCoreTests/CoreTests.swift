import Foundation
import XCTest
@testable import SysCleanerCore

final class CoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".SysCleanerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func file(_ name: String, _ contents: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try contents.data(using: .utf8)!.write(to: url)
        return url
    }

    private func sortableEntry(_ name: String, size: Int64, modified: Int64,
                               category: ScanCategory = .large, group: String? = nil,
                               note: String = "", isDirectory: Bool = false,
                               signature: String? = nil) -> ScanEntry {
        let url = root.appendingPathComponent(name)
        let stamp = FileStamp(device: 1, inode: 1, size: size, modifiedSeconds: modified,
                              modifiedNanoseconds: 0, linkCount: 1)
        return ScanEntry(url: url, scope: root, category: category, stamp: stamp,
                         estimatedBytes: size, note: note, duplicateGroup: group,
                         isDirectory: isDirectory, directorySignature: signature)
    }

    func testSortEntriesBySizeNameAndModificationInBothDirections() {
        let a = sortableEntry("alpha", size: 8, modified: 20)
        let b = sortableEntry("Beta", size: 2, modified: 10)
        let c = sortableEntry("beta", size: 8, modified: 30)
        let items = [c, b, a]

        func names(_ field: ScanSortField, _ direction: ScanSortDirection) -> [String] {
            ScanSorting.entries(items, category: .large,
                                selection: ScanSortSelection(field: field, direction: direction))
                .map { $0.url.lastPathComponent }
        }

        XCTAssertEqual(names(.size, .ascending), ["Beta", "alpha", "beta"])
        XCTAssertEqual(names(.size, .descending), ["alpha", "beta", "Beta"])
        XCTAssertEqual(names(.name, .ascending), ["alpha", "Beta", "beta"])
        XCTAssertEqual(names(.name, .descending), ["Beta", "beta", "alpha"])
        XCTAssertEqual(names(.modified, .ascending), ["Beta", "alpha", "beta"])
        XCTAssertEqual(names(.modified, .descending), ["beta", "alpha", "Beta"])
    }

    func testDuplicateSortingKeepsGroupsAndRetainedCopyFirst() {
        let aRetained = sortableEntry("a-original", size: 5, modified: 20,
                                      category: .duplicates, group: "a", note: "keepOriginal")
        let aCopy = sortableEntry("z-copy", size: 5, modified: 10,
                                  category: .duplicates, group: "a", note: "duplicateCopy")
        let bRetained = sortableEntry("b-original", size: 9, modified: 30,
                                      category: .duplicates, group: "b", note: "keepOriginal")
        let bCopy = sortableEntry("c-copy", size: 9, modified: 40,
                                  category: .duplicates, group: "b", note: "duplicateCopy")
        let items = [bCopy, aCopy, bRetained, aRetained]

        func names(_ field: ScanSortField, _ direction: ScanSortDirection) -> [String] {
            ScanSorting.entries(items, category: .duplicates,
                                selection: ScanSortSelection(field: field, direction: direction))
                .map { $0.url.lastPathComponent }
        }

        XCTAssertEqual(names(.size, .ascending), ["a-original", "z-copy", "b-original", "c-copy"])
        XCTAssertEqual(names(.size, .descending), ["b-original", "c-copy", "a-original", "z-copy"])
        XCTAssertEqual(names(.name, .ascending), ["a-original", "z-copy", "b-original", "c-copy"])
        XCTAssertEqual(names(.name, .descending), ["b-original", "c-copy", "a-original", "z-copy"])
        XCTAssertEqual(names(.modified, .ascending), ["a-original", "z-copy", "b-original", "c-copy"])
        XCTAssertEqual(names(.modified, .descending), ["b-original", "c-copy", "a-original", "z-copy"])
    }

    func testUnknownAppSizesAlwaysSortLast() {
        let unknown = sortableEntry("unknown.app", size: 0, modified: 1,
                                    category: .uninstall, isDirectory: true)
        let small = sortableEntry("small.app", size: 1, modified: 2,
                                  category: .uninstall, isDirectory: true)
        let large = sortableEntry("large.app", size: 10, modified: 3,
                                  category: .uninstall, isDirectory: true)
        let items = [unknown, large, small]
        for (direction, expected) in [(ScanSortDirection.ascending, [small, large, unknown]),
                                      (.descending, [large, small, unknown])] {
            let actual = ScanSorting.entries(items, category: .uninstall,
                                             selection: ScanSortSelection(field: .size, direction: direction))
            XCTAssertEqual(actual.map(\.id), expected.map(\.id))
        }
    }

    func testSpaceItemSortingSupportsSizeAndName() {
        let a = SpaceItem(url: root.appendingPathComponent("alpha"), parent: root,
                          bytes: 5, isFolder: true)
        let b = SpaceItem(url: root.appendingPathComponent("Beta"), parent: root,
                          bytes: 10, isFolder: true)
        let other = SpaceItem(url: root.appendingPathComponent("other"), parent: root,
                              bytes: 10, isFolder: false, isOther: true)
        let items = [other, b, a]
        XCTAssertEqual(ScanSorting.spaceItems(items, selection: ScanSortSelection(), otherName: "Other")
            .map(\.id), [b.id, other.id, a.id])
        XCTAssertEqual(ScanSorting.spaceItems(items,
                                             selection: ScanSortSelection(field: .name, direction: .ascending),
                                             otherName: "Other").map(\.id), [a.id, b.id, other.id])
    }

    func testLargeFilesAndAgeFilter() throws {
        _ = try file("small", "a")
        let large = try file("large", String(repeating: "b", count: 200))
        let report = FileScanner.scan(ScanRequest(category: .large, root: root, minimumBytes: 100))
        XCTAssertEqual(report.entries.map { $0.url.resolvingSymlinksInPath() },
                       [large.resolvingSymlinksInPath()])
        XCTAssertFalse(report.cancelled)
        XCTAssertTrue(FileScanner.scan(ScanRequest(category: .large, root: root, minimumBytes: 100,
                                                   olderThanDays: 1)).entries.isEmpty)
    }

    func testDuplicatesRequireMatchingContentAndKeepOne() throws {
        _ = try file("a", "same")
        _ = try file("b", "same")
        _ = try file("c", "else")
        let report = FileScanner.scan(ScanRequest(category: .duplicates, root: root))
        XCTAssertEqual(report.entries.count, 2)
        XCTAssertEqual(report.entries.filter(\.canDelete).count, 1)
        XCTAssertEqual(Set(report.entries.compactMap(\.duplicateGroup)).count, 1)
    }

    func testCancellation() throws {
        _ = try file("a", "content")
        let control = ScanControl()
        control.cancel()
        let report = FileScanner.scan(ScanRequest(category: .space, root: root), control: control)
        XCTAssertTrue(report.cancelled)
        XCTAssertTrue(report.entries.isEmpty)
    }

    func testChangedFileAndProtectedPathAreRefused() throws {
        let url = try file("target", "original")
        let entry = FileScanner.scan(ScanRequest(category: .large, root: root, minimumBytes: 1)).entries[0]
        try "changed contents".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(FileDeletion.refusal(for: entry), "changed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let protected = ScanEntry(url: URL(fileURLWithPath: "/System/Library/test"), scope: URL(fileURLWithPath: "/"),
                                  category: .large, stamp: entry.stamp, estimatedBytes: 1)
        XCTAssertEqual(FileDeletion.refusal(for: protected), "unsafePath")
    }

    func testTrashCanBeRestoredAndPermanentDeleteRequiresSeparateMode() throws {
        let url = try file("recoverable", "save me")
        let entry = FileScanner.scan(ScanRequest(category: .large, root: root, minimumBytes: 1)).entries[0]
        let trashResult = FileDeletion.execute([entry], mode: .trash).first!
        XCTAssertTrue(trashResult.success)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertNotNil(trashResult.trashURL)
        try FileManager.default.moveItem(at: trashResult.trashURL!, to: url)
        // Restoring the exact file may update metadata; scan again before deleting.
        let restored = FileScanner.scan(ScanRequest(category: .large, root: root, minimumBytes: 1)).entries[0]
        XCTAssertEqual(FileDeletion.execute([restored], mode: .permanent).first?.success, true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testCleanupHistoryRoundTrip() throws {
        let url = root.appendingPathComponent("history/records.json")
        let item = CleanupHistoryItem(path: "/Users/test/file", estimatedBytes: 42,
                                      success: true, message: "movedToTrash",
                                      trashPath: "/Users/test/.Trash/file")
        let record = CleanupHistoryRecord(category: "large", mode: "trash", items: [item])
        try CleanupHistoryStorage.save([record], to: url)
        let loaded = try CleanupHistoryStorage.load(from: url)
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].items[0].trashPath, item.trashPath)
        XCTAssertEqual(loaded[0].items[0].estimatedBytes, 42)
        XCTAssertFalse(loaded[0].items[0].canRestore)
    }

    func testTrashHistoryRestoresWithoutOverwriting() throws {
        let scope = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/SysCleanerRestoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scope, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scope) }
        let original = scope.appendingPathComponent("sample.txt")
        try Data("original".utf8).write(to: original)
        let entry = FileScanner.scan(ScanRequest(category: .large, root: scope, minimumBytes: 1)).entries[0]
        let outcome = try XCTUnwrap(FileDeletion.execute([entry], mode: .trash).first)
        XCTAssertTrue(outcome.success)
        let trash = try XCTUnwrap(outcome.trashURL)
        let stamp = try XCTUnwrap(FileSafety.stamp(at: trash))
        let item = CleanupHistoryItem(path: original.path, estimatedBytes: entry.estimatedBytes,
                                      success: true, message: outcome.message, trashPath: trash.path,
                                      scopePath: scope.path, trashStamp: stamp)
        XCTAssertTrue(item.canRestore)

        try Data("replacement".utf8).write(to: original)
        XCTAssertEqual(FileRestoration.restore(item, category: .large), "restoreConflict")
        XCTAssertEqual(try Data(contentsOf: original), Data("replacement".utf8))
        try FileManager.default.removeItem(at: original)
        XCTAssertNil(FileRestoration.restore(item, category: .large))
        XCTAssertEqual(try Data(contentsOf: original), Data("original".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: trash.path))
    }

    func testPartialFailureKeepsOtherFiles() throws {
        let first = try file("first", "one")
        let second = try file("second", "two")
        let entries = FileScanner.scan(ScanRequest(category: .large, root: root, minimumBytes: 1)).entries
        try "changed".write(to: first, atomically: true, encoding: .utf8)
        let results = FileDeletion.execute(entries, mode: .permanent)
        XCTAssertEqual(results.filter(\.success).count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.path))
    }

    func testSymlinksAndHardLinksAreNotOffered() throws {
        let original = try file("original", "data")
        let hardlink = root.appendingPathComponent("hardlink")
        let symlink = root.appendingPathComponent("symlink")
        try FileManager.default.linkItem(at: original, to: hardlink)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: original)
        let report = FileScanner.scan(ScanRequest(category: .large, root: root, minimumBytes: 1))
        XCTAssertTrue(report.entries.isEmpty)
    }

    func testParentSymlinkSwapIsRefused() throws {
        let folder = root.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fileURL = folder.appendingPathComponent("item")
        try "content".write(to: fileURL, atomically: true, encoding: .utf8)
        let entry = FileScanner.scan(ScanRequest(category: .large, root: root, minimumBytes: 1)).entries[0]
        let moved = root.appendingPathComponent("moved")
        try FileManager.default.moveItem(at: folder, to: moved)
        try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: moved)
        XCTAssertEqual(FileDeletion.refusal(for: entry), "unsafePath")
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved.appendingPathComponent("item").path))
    }

    func testAppContentsCannotBeSelectedFromLargeFileScan() throws {
        let appFolder = root.appendingPathComponent("Example.app")
        try FileManager.default.createDirectory(at: appFolder, withIntermediateDirectories: true)
        let fileURL = appFolder.appendingPathComponent("binary")
        try "content".write(to: fileURL, atomically: true, encoding: .utf8)
        let report = FileScanner.scan(ScanRequest(category: .large, root: appFolder, minimumBytes: 1))
        XCTAssertEqual(report.entries.count, 1)
        XCTAssertFalse(report.entries[0].canDelete)

        let archive = root.appendingPathComponent("Example.xcarchive")
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        let archivedFile = archive.appendingPathComponent("binary")
        try "content".write(to: archivedFile, atomically: true, encoding: .utf8)
        XCTAssertFalse(FileSafety.isSafeLocation(archivedFile, scope: root, category: .large))
    }

    func testUnreadableFolderReportsIncompleteScan() throws {
        let blocked = root.appendingPathComponent("blocked")
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        try "hidden".write(to: blocked.appendingPathComponent("file"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: blocked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: blocked.path) }
        let report = FileScanner.scan(ScanRequest(category: .space, root: root))
        XCTAssertTrue(report.warnings.contains { $0.contains("Cannot read") })
    }

    func testOpenFileIsRefused() throws {
        let url = try file("open", "content")
        let entry = FileScanner.scan(ScanRequest(category: .large, root: root, minimumBytes: 1)).entries[0]
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        XCTAssertEqual(FileDeletion.refusal(for: entry), "fileInUse")
    }

    func testSpaceTotalsIncludeSmallFilesAndNestedFolders() throws {
        _ = try file("small", "tiny")
        let folder = root.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "nested".write(to: folder.appendingPathComponent("small"), atomically: true, encoding: .utf8)
        let report = FileScanner.scan(ScanRequest(category: .space, root: root))
        XCTAssertEqual(report.scannedFileCount, 2)
        XCTAssertEqual(report.scannedBytes, 10)
        XCTAssertEqual(report.spaceItems.first(where: { $0.url.path == folder.path })?.bytes, 6)
        XCTAssertEqual(report.spaceItems.first(where: { $0.parent.path == root.path && $0.isOther })?.bytes, 4)
    }

    func testDeepSpaceTotalsPropagateOnceThroughEveryParent() throws {
        var directory = root!
        for depth in 0..<20 {
            directory.appendPathComponent("level\(depth)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        }
        try Data(repeating: 7, count: 17).write(to: directory.appendingPathComponent("deep"))
        _ = try file("top", "abc")
        let report = FileScanner.scan(ScanRequest(category: .space, root: root))
        XCTAssertEqual(report.scannedFileCount, 2)
        XCTAssertEqual(report.scannedBytes, 20)
        for depth in 0..<20 {
            let path = root.appendingPathComponent((0...depth).map { "level\($0)" }.joined(separator: "/"))
            XCTAssertEqual(report.spaceItems.first(where: { $0.url == path })?.bytes, 17)
        }
    }

    func testSpaceFoldersRemainNavigableThroughTmpAlias() throws {
        let alias = URL(fileURLWithPath: "/private/tmp")
        let canonical = alias.resolvingSymlinksInPath().standardizedFileURL
        guard alias.path != canonical.path else { return }
        let folder = alias.appendingPathComponent("SysCleanerAlias-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let nested = folder.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data([1]).write(to: nested.appendingPathComponent("file"))
        let report = FileScanner.scan(ScanRequest(category: .space, root: folder))
        let scannedRoot = folder.resolvingSymlinksInPath().standardizedFileURL
        XCTAssertEqual(report.spaceItems.first(where: { $0.isFolder })?.parent.path, scannedRoot.path)
        XCTAssertEqual(report.spaceItems.first(where: { $0.isFolder })?.bytes, 1)
    }

    func testDuplicatePrehashIsOnlyAFilter() throws {
        let edge = Data(repeating: 1, count: 4_096)
        let first = edge + Data(repeating: 2, count: 24_576) + edge
        let second = edge + Data(repeating: 3, count: 24_576) + edge
        try first.write(to: root.appendingPathComponent("a"))
        try second.write(to: root.appendingPathComponent("b"))
        try first.write(to: root.appendingPathComponent("c"))
        let report = FileScanner.scan(ScanRequest(category: .duplicates, root: root))
        XCTAssertEqual(Set(report.entries.map { $0.url.lastPathComponent }), ["a", "c"])
        XCTAssertEqual(report.entries.filter(\.canDelete).count, 1)
    }

    func testCacheScanKeepsLargestTwoThousand() throws {
        for index in 0..<2_010 {
            let url = root.appendingPathComponent(String(format: "%04d", index))
            try Data(repeating: 1, count: index + 1).write(to: url)
        }
        let report = FileScanner.scanCaches(category: .systemCache, locations: [root])
        XCTAssertEqual(report.entries.count, 2_000)
        XCTAssertEqual(report.entries.first?.estimatedBytes, 2_010)
        XCTAssertEqual(report.entries.last?.estimatedBytes, 11)
        XCTAssertTrue(report.warnings.contains("listLimited"))
    }

    func testCancelledCacheScanReturnsNoResults() {
        let control = ScanControl()
        control.cancel()
        let report = FileScanner.scanCaches(category: .developerCache, locations: [root], control: control)
        XCTAssertTrue(report.cancelled)
        XCTAssertTrue(report.entries.isEmpty)
    }

    func testDirectorySignatureChangesWhenContentsChange() throws {
        let folder = root.appendingPathComponent("bundle")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("content")
        try Data([1]).write(to: file)
        let before = try XCTUnwrap(FileScanner.directorySignature(folder))
        XCTAssertEqual(before.bytes, 1)
        try Data([1, 2]).write(to: file)
        let after = try XCTUnwrap(FileScanner.directorySignature(folder))
        XCTAssertEqual(after.bytes, 2)
        XCTAssertNotEqual(before.digest, after.digest)
    }

    func testApplicationBundleSizeIncludesNestedFiles() throws {
        let app = root.appendingPathComponent("Sample.app")
        let nested = app.appendingPathComponent("Contents/Helpers/Helper.app/Contents")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 5).write(to: app.appendingPathComponent("Contents/main"))
        try Data(repeating: 2, count: 7).write(to: nested.appendingPathComponent("helper"))
        XCTAssertEqual(FileScanner.applicationBundleSize(app), 12)
    }

    func testOrphanCandidatesExcludeInstalledAppsAndRemainReadOnly() throws {
        let cache = root.appendingPathComponent("Caches")
        try FileManager.default.createDirectory(at: cache.appendingPathComponent("com.example.gone"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cache.appendingPathComponent("com.example.present"),
                                                withIntermediateDirectories: true)
        try Data("log".utf8).write(to: cache.appendingPathComponent("warp.log.old.3"))
        let http = root.appendingPathComponent("HTTPStorages")
        try FileManager.default.createDirectory(at: http, withIntermediateDirectories: true)
        try Data("cookie".utf8).write(to: http.appendingPathComponent("com.example.present.binarycookies"))
        let entries = FileScanner.scanOrphanCandidates(roots: [cache],
                                                      installedIdentifiers: ["com.example.present"])
        XCTAssertEqual(entries.map { $0.url.lastPathComponent }, ["com.example.gone"])
        XCTAssertEqual(entries.first?.category, .orphans)
        XCTAssertEqual(entries.first?.canDelete, false)
        let cookies = FileScanner.scanOrphanCandidates(roots: [http],
                                                       installedIdentifiers: ["com.example.present"])
        XCTAssertTrue(cookies.isEmpty)
    }

    func testOrphanCandidatesExcludeInstalledAppHelpers() throws {
        XCTAssertTrue(FileScanner.belongsToInstalledApp("com.example.product.ShareExtension",
                                                       installedIdentifiers: ["com.example.product"]))
        XCTAssertTrue(FileScanner.belongsToInstalledApp("com.example.product",
                                                       installedIdentifiers: ["com.example.product.LoginItem"]))
        XCTAssertFalse(FileScanner.belongsToInstalledApp("com.example.other",
                                                        installedIdentifiers: ["com.example.product"]))

        let applications = root.appendingPathComponent("Applications")
        let app = applications.appendingPathComponent("Nested/Main.app")
        let helper = app.appendingPathComponent("Contents/PlugIns/Share.appex")
        try FileManager.default.createDirectory(at: helper.appendingPathComponent("Contents"),
                                                withIntermediateDirectories: true)
        let mainPlist: [String: Any] = ["CFBundleIdentifier": "com.example.product",
                                       "CFBundlePackageType": "APPL"]
        let helperPlist: [String: Any] = ["CFBundleIdentifier": "com.example.product.ShareExtension",
                                         "CFBundlePackageType": "XPC!"]
        try (mainPlist as NSDictionary).write(to: app.appendingPathComponent("Contents/Info.plist"))
        try (helperPlist as NSDictionary).write(to: helper.appendingPathComponent("Contents/Info.plist"))
        let identifiers = FileScanner.installedApplicationIdentifiers(in: [applications])
        XCTAssertTrue(identifiers.contains("com.example.product"))
        XCTAssertTrue(identifiers.contains("com.example.product.shareextension"))
    }

    func testTreemapCoversAreaWithoutOverlapAndGroupsRemainder() {
        let parent = URL(fileURLWithPath: "/tmp/treemap")
        let sizes: [Int64] = [50, 25, 15, 5, 3, 2]
        let items = sizes.enumerated().map { index, bytes in
            SpaceItem(url: parent.appendingPathComponent("item\(index)"), parent: parent,
                      bytes: bytes, isFolder: index.isMultiple(of: 2))
        }
        let cells = SpaceTreemap.layout(items, in: CGSize(width: 600, height: 300), limit: 4)
        XCTAssertEqual(cells.count, 4)
        XCTAssertEqual(cells.filter(\.isRemainder).first?.bytes, 10)
        let area = cells.reduce(CGFloat(0)) { $0 + $1.frame.width * $1.frame.height }
        XCTAssertEqual(area, 180_000, accuracy: 1)
        for left in cells.indices {
            XCTAssertTrue(CGRect(origin: .zero, size: CGSize(width: 600, height: 300))
                .contains(cells[left].frame))
            for right in cells.indices where left < right {
                let overlap = cells[left].frame.intersection(cells[right].frame)
                XCTAssertLessThan(overlap.width * overlap.height, 0.1)
            }
        }
    }

    func testParallelSpaceScanProducesStableFolderTotals() throws {
        for index in 0..<12 {
            let folder = root.appendingPathComponent("branch\(index)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for child in 0..<10 {
                try Data(repeating: 1, count: index + child + 1)
                    .write(to: folder.appendingPathComponent("file\(child)"))
            }
        }
        let snapshots = (0..<5).map { _ -> [String: Int64] in
            let report = FileScanner.scan(ScanRequest(category: .space, root: root))
            XCTAssertEqual(report.scannedFileCount, 120)
            return Dictionary(uniqueKeysWithValues: report.spaceItems.filter(\.isFolder).map { ($0.url.path, $0.bytes) })
        }
        XCTAssertEqual(snapshots.first?.count, 12)
        for snapshot in snapshots.dropFirst() { XCTAssertEqual(snapshot, snapshots[0]) }
    }
}
