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
                               signature: String? = nil, canDelete: Bool = true,
                               sizeIsKnown: Bool = true) -> ScanEntry {
        let url = root.appendingPathComponent(name)
        let stamp = FileStamp(device: 1, inode: 1, size: size, modifiedSeconds: modified,
                              modifiedNanoseconds: 0, linkCount: 1)
        return ScanEntry(url: url, scope: root, category: category, stamp: stamp,
                         estimatedBytes: size, sizeIsKnown: sizeIsKnown, note: note,
                         duplicateGroup: group,
                         isDirectory: isDirectory, canDelete: canDelete,
                         directorySignature: signature)
    }

    func testResultSearchAndTypeFiltersKeepOriginalEntries() {
        let photo = sortableEntry("Holiday.HEIC", size: 10, modified: 1)
        let archive = sortableEntry("backup.zip", size: 20, modified: 1)
        let locked = sortableEntry("protected.pdf", size: 30, modified: 1, canDelete: false)
        let entries = [photo, archive, locked]

        XCTAssertEqual(ScanResultFiltering.entries(entries, category: .large,
                                                   query: "holiday", filter: .all).map(\.id), [photo.id])
        XCTAssertEqual(ScanResultFiltering.entries(entries, category: .large,
                                                   query: "", filter: .images).map(\.id), [photo.id])
        XCTAssertEqual(ScanResultFiltering.entries(entries, category: .large,
                                                   query: "", filter: .archives).map(\.id), [archive.id])
        XCTAssertEqual(ScanResultFiltering.entries(entries, category: .large,
                                                   query: "", filter: .locked).map(\.id), [locked.id])
        XCTAssertEqual(ScanResultFiltering.entries(entries, category: .large,
                                                   query: "", filter: .selectable).count, 2)
        XCTAssertEqual(entries.count, 3)
    }

    func testDuplicateSearchPreservesGroupAndGroupSelectionRetainsOne() {
        let retained = sortableEntry("original.png", size: 7, modified: 1,
                                     category: .duplicates, group: "same", note: "keepOriginal")
        let copy = sortableEntry("copy.png", size: 7, modified: 2,
                                 category: .duplicates, group: "same", note: "duplicateCopy")
        let other = sortableEntry("unrelated.pdf", size: 9, modified: 3,
                                  category: .duplicates, group: "other", note: "keepOriginal")
        let otherCopy = sortableEntry("another.pdf", size: 9, modified: 4,
                                      category: .duplicates, group: "other", note: "duplicateCopy")
        let all = [retained, copy, other, otherCopy]
        let filtered = ScanResultFiltering.entries(all, category: .duplicates,
                                                   query: "copy.png", filter: .all)
        XCTAssertEqual(filtered.map(\.id), [retained.id, copy.id])
        let groups = ScanResultGrouping.duplicateGroups(filtered)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(ScanResultGrouping.selectableIDs(in: groups[0]), Set([copy.id]))
        XCTAssertEqual(ScanResultFiltering.entries(all, category: .duplicates,
                                                   query: "", filter: .documents).map(\.id),
                       [other.id, otherCopy.id])
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
        let measured = unknown.withEstimatedBytes(5)
        XCTAssertEqual(measured.id, unknown.id)
        XCTAssertEqual(measured.estimatedBytes, 5)
        XCTAssertEqual(ScanSorting.entries([unknown, large, small].map {
            $0.id == unknown.id ? measured : $0
        }, category: .uninstall, selection: ScanSortSelection(field: .size, direction: .ascending))
            .map(\.id), [small.id, unknown.id, large.id])
    }

    func testUnknownOrphanFolderSizeSortsAfterMeasuredFolders() {
        let unknown = sortableEntry("unknown", size: 0, modified: 1,
                                    category: .orphans, isDirectory: true, sizeIsKnown: false)
        let empty = sortableEntry("empty", size: 0, modified: 2,
                                  category: .orphans, isDirectory: true)
        let filled = sortableEntry("filled", size: 10, modified: 3,
                                   category: .orphans, isDirectory: true)
        for (direction, expected) in [(ScanSortDirection.ascending, [empty, filled, unknown]),
                                      (.descending, [filled, empty, unknown])] {
            let actual = ScanSorting.entries([unknown, filled, empty], category: .orphans,
                                             selection: ScanSortSelection(field: .size,
                                                                          direction: direction))
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

    func testApplicationOverviewListsBundlesWithoutMeasuringContents() throws {
        let app = root.appendingPathComponent("Sample.app")
        let contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": "dev.example.SysCleanerSample",
                                   "CFBundleName": "Sample", "CFBundlePackageType": "APPL"]
        let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try plist.write(to: contents.appendingPathComponent("Info.plist"))
        try Data(repeating: 1, count: 4096).write(to: contents.appendingPathComponent("payload"))

        let entries = FileScanner.scanApplications(roots: [root])
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].url.path, app.path)
        XCTAssertEqual(entries[0].estimatedBytes, 0)
        XCTAssertFalse(entries[0].canDelete)
        XCTAssertNil(entries[0].directorySignature)
    }

    func testRunningApplicationMatchesBundlePathNotOnlyIdentifier() {
        let installed = root.appendingPathComponent("Xcode.app")
        let otherVersion = root.appendingPathComponent("Xcode Beta.app")
        XCTAssertFalse(FileSafety.matchesRunningApplication(installed, identifier: "com.apple.dt.Xcode",
                                                            runningIdentifier: "com.apple.dt.Xcode",
                                                            runningBundle: otherVersion))
        XCTAssertTrue(FileSafety.matchesRunningApplication(installed, identifier: "com.apple.dt.Xcode",
                                                           runningIdentifier: "com.apple.dt.Xcode",
                                                           runningBundle: installed))
        XCTAssertTrue(FileSafety.matchesRunningApplication(installed, identifier: "com.apple.dt.Xcode",
                                                           runningIdentifier: "com.apple.dt.Xcode",
                                                           runningBundle: installed.appendingPathComponent("Contents/Helpers/Tool.app")))
        XCTAssertFalse(FileSafety.matchesRunningApplication(installed, identifier: "com.apple.dt.Xcode",
                                                            runningIdentifier: "another.app",
                                                            runningBundle: installed))
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

    func testTrashHistoryAllowsTrashChangeTimeToDrift() throws {
        let scope = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/SysCleanerRestoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scope, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scope) }
        let original = scope.appendingPathComponent("sample")
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        try Data("original".utf8).write(to: original.appendingPathComponent("sample.txt"))
        var destination: NSURL?
        try FileManager.default.trashItem(at: original, resultingItemURL: &destination)
        let trash = try XCTUnwrap(destination as URL?)
        defer { try? FileManager.default.removeItem(at: trash) }
        let stamp = try XCTUnwrap(FileSafety.stamp(at: trash))
        let signature = try XCTUnwrap(FileScanner.directorySignature(trash)?.digest)
        let recorded = FileStamp(device: stamp.device, inode: stamp.inode, size: stamp.size,
                                 modifiedSeconds: stamp.modifiedSeconds,
                                 modifiedNanoseconds: stamp.modifiedNanoseconds,
                                 linkCount: stamp.linkCount, allocatedBytes: stamp.allocatedBytes,
                                 changedSeconds: (stamp.changedSeconds ?? 0) - 1,
                                 changedNanoseconds: stamp.changedNanoseconds)
        let item = CleanupHistoryItem(path: original.path, estimatedBytes: 8,
                                      success: true, message: "movedToTrash", trashPath: trash.path,
                                      scopePath: scope.path, trashStamp: recorded,
                                      trashSignature: signature)
        XCTAssertNil(FileRestoration.restore(item, category: .large))
        XCTAssertEqual(try Data(contentsOf: original.appendingPathComponent("sample.txt")),
                       Data("original".utf8))
    }

    func testTrashHistoryRejectsDirectoryContentChangedAfterMove() throws {
        let scope = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/SysCleanerRestoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scope, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scope) }
        let original = scope.appendingPathComponent("sample")
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        let child = original.appendingPathComponent("data.txt")
        try Data("original".utf8).write(to: child)
        var trashPath: URL?
        defer { if let trashPath { try? FileManager.default.removeItem(at: trashPath) } }
        var destination: NSURL?
        try FileManager.default.trashItem(at: original, resultingItemURL: &destination)
        let trash = try XCTUnwrap(destination as URL?)
        trashPath = trash
        let stamp = try XCTUnwrap(FileSafety.stamp(at: trash))
        let signature = try XCTUnwrap(FileScanner.directorySignature(trash)?.digest)
        let history = CleanupHistoryItem(path: original.path, estimatedBytes: 8,
                                         success: true, message: "movedToTrash", trashPath: trash.path,
                                         scopePath: scope.path, trashStamp: stamp,
                                         trashSignature: signature)
        let trashedChild = trash.appendingPathComponent("data.txt")
        let previousModification = try XCTUnwrap(FileSafety.stamp(at: trashedChild))
        try Data("modified".utf8).write(to: trashedChild)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970:
            Double(previousModification.modifiedSeconds) + Double(previousModification.modifiedNanoseconds) / 1e9)],
            ofItemAtPath: trashedChild.path)
        XCTAssertEqual(FileRestoration.restore(history, category: .large), "restoreChanged")
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
    }

    func testXcodeReviewComparisonRequiresCompleteCategoryOnBothSides() {
        let before = XcodeReviewSnapshot(measures: [
            .projects: XcodeReviewMeasure(count: 3, estimatedBytes: 900, complete: true),
            .sharedCaches: XcodeReviewMeasure(count: 2, estimatedBytes: 300, complete: false)
        ])
        let after = XcodeReviewSnapshot(measures: [
            .projects: XcodeReviewMeasure(count: 2, estimatedBytes: 500, complete: true),
            .sharedCaches: XcodeReviewMeasure(count: 1, estimatedBytes: 100, complete: true)
        ])
        let projects = before.comparison(to: after, category: .projects)
        XCTAssertEqual(projects?.before.count, 3)
        XCTAssertEqual(projects?.after.count, 2)
        XCTAssertEqual(projects?.before.estimatedBytes, 900)
        XCTAssertEqual(projects?.after.estimatedBytes, 500)
        XCTAssertNil(before.comparison(to: after, category: .sharedCaches))
        XCTAssertNil(before.comparison(to: after, category: .archives))
    }

    func testDeleteResultDistinguishesSafetySkipFromOperationFailure() {
        let path = URL(fileURLWithPath: "/tmp/example")
        XCTAssertEqual(DeleteResult(url: path, success: true, message: "movedToTrash").status, .success)
        XCTAssertEqual(DeleteResult(url: path, success: false, message: "changed").status, .skipped)
        XCTAssertEqual(DeleteResult(url: path, success: false, message: "fileInUse").status, .skipped)
        XCTAssertEqual(DeleteResult(url: path, success: false, message: "disk full").status, .failed)
    }

    func testCapacityObservationDoesNotTreatCrossVolumeBatchAsOneVolume() {
        func entry(device: UInt64, name: String) -> ScanEntry {
            ScanEntry(url: URL(fileURLWithPath: "/tmp/\(name)"),
                      scope: URL(fileURLWithPath: "/tmp"), category: .large,
                      stamp: FileStamp(device: device, inode: 1, size: 10,
                                       modifiedSeconds: 1, modifiedNanoseconds: 0, linkCount: 1),
                      estimatedBytes: 10)
        }
        XCTAssertNil(DeletionCapacityScope.commonScope(for: []))
        XCTAssertEqual(DeletionCapacityScope.commonScope(for: [entry(device: 1, name: "a"),
                                                              entry(device: 1, name: "b")])?.path, "/tmp")
        XCTAssertNil(DeletionCapacityScope.commonScope(for: [entry(device: 1, name: "a"),
                                                            entry(device: 2, name: "b")]))
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

    func testSpaceTreeMaterializesOnlyRequestedFolderChildren() throws {
        let folder = root.appendingPathComponent("资料")
        let nested = folder.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        _ = try file("small", "tiny")
        try Data(repeating: 7, count: 1_048_576).write(to: nested.appendingPathComponent("large"))
        let report = FileScanner.scan(ScanRequest(category: .space, root: root))
        let tree = try XCTUnwrap(report.spaceTree)

        XCTAssertEqual(tree.directoryCount, 3)
        let rootChildren = tree.children(of: root)
        XCTAssertEqual(rootChildren.first(where: { $0.isFolder })?.url.path, folder.path)
        XCTAssertEqual(rootChildren.first(where: { $0.isOther })?.bytes, 4)
        XCTAssertEqual(tree.children(of: folder).map(\.url.lastPathComponent), ["nested"])
        XCTAssertEqual(tree.children(of: nested).map(\.url.lastPathComponent), ["large"])
        XCTAssertTrue(tree.children(of: root.appendingPathComponent("missing")).isEmpty)

        let complete = Dictionary(uniqueKeysWithValues: report.spaceItems.map { ($0.id, $0.bytes) })
        XCTAssertEqual(complete[folder.path], 1_048_576)
        XCTAssertEqual(complete[nested.path], 1_048_576)
    }

    func testEmptySpaceTreeHasNoDisplayItems() throws {
        let report = FileScanner.scan(ScanRequest(category: .space, root: root))
        let tree = try XCTUnwrap(report.spaceTree)
        XCTAssertEqual(tree.directoryCount, 1)
        XCTAssertFalse(tree.hasDisplayItems)
        XCTAssertTrue(tree.children(of: root).isEmpty)
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
        let tree = try XCTUnwrap(report.spaceTree)
        XCTAssertEqual(tree.children(of: scannedRoot).first(where: { $0.isFolder })?.bytes, 1)
        XCTAssertEqual(tree.children(of: scannedRoot.appendingPathComponent("nested"))
            .first(where: { $0.isOther })?.bytes, 1)
    }

    func testRustSpacePrototypeMatchesSwiftAndFallsBack() throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let helper = repository.appendingPathComponent("Benchmarks/Rust/target/release/space_helper")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else {
            throw XCTSkip("Build the Rust space_helper release binary before this test")
        }
        let nested = root.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 1_048_576).write(to: nested.appendingPathComponent("large"))
        try Data().write(to: nested.appendingPathComponent("empty"))
        try Data("small".utf8).write(to: nested.appendingPathComponent("small"))
        try FileManager.default.linkItem(at: nested.appendingPathComponent("small"),
                                         to: root.appendingPathComponent("hardlink"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"),
                                                    withDestinationURL: nested)
        let trash = root.appendingPathComponent(".Trash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        try Data("ignored".utf8).write(to: trash.appendingPathComponent("ignored"))
        let excluded = root.appendingPathComponent("excluded")
        try FileManager.default.createDirectory(at: excluded, withIntermediateDirectories: true)
        try Data("excluded".utf8).write(to: excluded.appendingPathComponent("file"))

        let swift = FileScanner.scan(ScanRequest(category: .space, root: root,
                                                  excludedPaths: [excluded.path]))
        let rust = FileScanner.scan(ScanRequest(category: .space, root: root,
                                                 excludedPaths: [excluded.path],
                                                 useRustSpaceScanner: true, rustHelperURL: helper))
        let fallback = FileScanner.scan(ScanRequest(category: .space, root: root,
                                                     excludedPaths: [excluded.path],
                                                     useRustSpaceScanner: true,
                                                     rustHelperURL: root.appendingPathComponent("missing-helper")))

        func items(_ report: ScanReport) -> [String: String] {
            Dictionary(uniqueKeysWithValues: report.spaceItems.map { item in
                (item.url.path + (item.isOther ? "#other" : ""),
                 "\(item.bytes):\(item.allocatedBytes ?? -1):\(item.isFolder)")
            })
        }
        XCTAssertEqual(rust.scannedFileCount, swift.scannedFileCount)
        XCTAssertEqual(rust.scannedBytes, swift.scannedBytes)
        XCTAssertEqual(rust.scannedAllocatedBytes, swift.scannedAllocatedBytes)
        XCTAssertEqual(rust.omittedCount, swift.omittedCount)
        XCTAssertEqual(items(rust), items(swift))
        XCTAssertEqual(items(fallback), items(swift))

        let control = ScanControl()
        control.cancel()
        XCTAssertTrue(FileScanner.scan(ScanRequest(category: .space, root: root,
                                                    useRustSpaceScanner: true, rustHelperURL: helper),
                                       control: control).cancelled)
    }

    func testRustSpacePrototypeStopsRunningHelperWhenCancelled() throws {
        let helper = root.appendingPathComponent("slow-helper.sh")
        try "#!/bin/sh\nexec /bin/sleep 10\n".write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let control = ScanControl()
        let finished = expectation(description: "Rust helper stopped after cancellation")
        let started = Date()
        let scanRoot = try XCTUnwrap(root)
        DispatchQueue.global().async {
            let report = FileScanner.scan(ScanRequest(category: .space, root: scanRoot,
                                                       useRustSpaceScanner: true, rustHelperURL: helper),
                                          control: control)
            XCTAssertTrue(report.cancelled)
            finished.fulfill()
        }
        Thread.sleep(forTimeInterval: 0.1)
        control.cancel()
        wait(for: [finished], timeout: 3)
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
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

    func testConcurrentDuplicateHashingKeepsContentGroupsAndOriginals() throws {
        let edge = Data(repeating: 7, count: 4_096)
        for (name, middle) in [("a1", UInt8(1)), ("a2", 1), ("a3", 1),
                               ("b1", 2), ("b2", 2), ("unique", 3)] {
            try (edge + Data(repeating: middle, count: 24_576) + edge)
                .write(to: root.appendingPathComponent(name))
        }
        let report = FileScanner.scan(ScanRequest(category: .duplicates, root: root))
        XCTAssertEqual(Set(report.entries.map { $0.url.lastPathComponent }),
                       ["a1", "a2", "a3", "b1", "b2"])
        XCTAssertEqual(Set(report.entries.compactMap(\.duplicateGroup)).count, 2)
        XCTAssertEqual(Set(report.entries.filter { !$0.canDelete }.map { $0.url.lastPathComponent }),
                       ["a1", "b1"])
        XCTAssertEqual(report.entries.filter(\.canDelete).count, 3)
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
        XCTAssertEqual(report.omittedCount, 10)
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

    func testOrphanCandidatesMeasureFolderContentsAndEmptyFolders() throws {
        let cache = root.appendingPathComponent("Caches")
        let filled = cache.appendingPathComponent("com.example.filled")
        let nested = filled.appendingPathComponent("nested")
        let empty = cache.appendingPathComponent("com.example.empty")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 7).write(to: filled.appendingPathComponent("first"))
        try Data(repeating: 2, count: 11).write(to: nested.appendingPathComponent("second"))

        let entries = FileScanner.scanOrphanCandidates(roots: [cache], installedIdentifiers: [])
        let byName = Dictionary(uniqueKeysWithValues: entries.map { ($0.url.lastPathComponent, $0) })
        XCTAssertEqual(byName["com.example.filled"]?.estimatedBytes, 18)
        XCTAssertEqual(byName["com.example.filled"]?.sizeIsKnown, true)
        XCTAssertEqual(byName["com.example.empty"]?.estimatedBytes, 0)
        XCTAssertEqual(byName["com.example.empty"]?.sizeIsKnown, true)
        XCTAssertTrue(entries.allSatisfy { !$0.canDelete })
    }

    func testUnreadableOrphanFolderKeepsSizeUnknown() throws {
        let cache = root.appendingPathComponent("Caches")
        let candidate = cache.appendingPathComponent("com.example.blocked")
        try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 5).write(to: candidate.appendingPathComponent("file"))
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: candidate.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: candidate.path) }

        let entry = try XCTUnwrap(FileScanner.scanOrphanCandidates(
            roots: [cache], installedIdentifiers: []).first)
        XCTAssertFalse(entry.sizeIsKnown)
        XCTAssertEqual(entry.estimatedBytes, 0)
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

    func testPieGroupsOtherAndKeepsAtMostSevenPositiveSlices() {
        let parent = URL(fileURLWithPath: "/tmp/space-pie")
        let sizes: [Int64] = [50, 25, 15, 5, 3, 2, 1, 0]
        let items = sizes.enumerated().map { index, bytes in
            SpaceItem(url: parent.appendingPathComponent("item\(index)"), parent: parent,
                      bytes: bytes, isFolder: index.isMultiple(of: 2))
        }
        let existingOther = SpaceItem(url: parent.appendingPathComponent("other"), parent: parent,
                                      bytes: 4, isFolder: false, isOther: true)
        let slices = SpacePie.slices([existingOther] + items.reversed())
        XCTAssertEqual(slices.count, 7)
        XCTAssertEqual(slices.map(\.bytes), [50, 25, 15, 5, 5, 3, 2])
        XCTAssertEqual(slices.filter { !$0.isOther }.map(\.bytes), [50, 25, 15, 5, 3, 2])
        XCTAssertEqual(slices.first(where: \.isOther)?.bytes, 5)
        XCTAssertEqual(slices.reduce(Int64(0)) { $0 + $1.bytes }, 105)
        XCTAssertEqual(slices.reduce(0.0) { $0 + $1.fraction }, 1, accuracy: 0.000001)
        XCTAssertFalse(slices.contains { $0.item?.bytes == 0 })
        XCTAssertEqual(SpacePie.slice(at: 0, in: slices)?.bytes, 50)
        XCTAssertEqual(SpacePie.slice(at: 0.9999, in: slices)?.bytes, 2)
        XCTAssertNil(SpacePie.slice(at: 1, in: slices))
        XCTAssertTrue(SpacePie.slices([items.last!]).isEmpty)
    }

    func testSpaceScanKeepsZeroSizeFilesAndFoldersInListOnly() throws {
        let emptyFile = root.appendingPathComponent("empty.txt")
        let emptyFolder = root.appendingPathComponent("Empty Folder")
        try Data().write(to: emptyFile)
        try FileManager.default.createDirectory(at: emptyFolder, withIntermediateDirectories: true)

        let report = FileScanner.scan(ScanRequest(category: .space, root: root))
        let zeroItems = report.spaceItems.filter { $0.bytes == 0 && !$0.isOther }
        XCTAssertEqual(Set(zeroItems.map(\.url.lastPathComponent)), ["empty.txt", "Empty Folder"])
        XCTAssertTrue(SpacePie.slices(report.spaceItems).isEmpty)
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

    func testParallelSpaceScanAggregatesNestedBranchesRegardlessOfDiscoveryOrder() throws {
        for branch in 0..<24 {
            let parent = root.appendingPathComponent("branch\(branch)")
            let child = parent.appendingPathComponent("nested")
            try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
            try Data(repeating: 1, count: branch + 1)
                .write(to: child.appendingPathComponent("data"))
        }
        for _ in 0..<5 {
            let report = FileScanner.scan(ScanRequest(category: .space, root: root))
            let totals = Dictionary(uniqueKeysWithValues: report.spaceItems.filter(\.isFolder)
                .map { ($0.url.path, $0.bytes) })
            for branch in 0..<24 {
                let parent = root.appendingPathComponent("branch\(branch)")
                XCTAssertEqual(totals[parent.path], Int64(branch + 1))
                XCTAssertEqual(totals[parent.appendingPathComponent("nested").path], Int64(branch + 1))
            }
        }
    }

    func testScanExclusionsSkipNestedPathsWithoutRemovingOtherResults() throws {
        let excluded = root.appendingPathComponent("excluded")
        try FileManager.default.createDirectory(at: excluded, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 12).write(to: excluded.appendingPathComponent("hidden"))
        try Data(repeating: 2, count: 8).write(to: root.appendingPathComponent("visible"))
        let report = FileScanner.scan(ScanRequest(category: .space, root: root,
                                                   excludedPaths: [excluded.path]))
        XCTAssertEqual(report.scannedFileCount, 1)
        XCTAssertEqual(report.scannedBytes, 8)
        XCTAssertFalse(report.spaceItems.contains { $0.url.path.hasPrefix(excluded.path) })
    }

    func testIgnoredDuplicateHashOmitsWholeVerifiedGroup() throws {
        _ = try file("a", "same")
        _ = try file("b", "same")
        let first = FileScanner.scan(ScanRequest(category: .duplicates, root: root))
        let hash = try XCTUnwrap(first.entries.first?.duplicateGroup)
        let ignored = FileScanner.scan(ScanRequest(category: .duplicates, root: root,
                                                   ignoredDuplicateHashes: [hash]))
        XCTAssertEqual(first.entries.count, 2)
        XCTAssertTrue(ignored.entries.isEmpty)
    }

    func testPhysicalEstimateIsSeparateFromLogicalSize() throws {
        let url = try file("small", "x")
        let stamp = try XCTUnwrap(FileSafety.stamp(at: url))
        XCTAssertEqual(stamp.size, 1)
        XCTAssertGreaterThanOrEqual(stamp.allocatedBytes ?? -1, 1)
        let report = FileScanner.scan(ScanRequest(category: .space, root: root))
        XCTAssertEqual(report.scannedBytes, 1)
        XCTAssertEqual(report.scannedAllocatedBytes, stamp.allocatedBytes)
    }

    func testOldHistoryStampDecodesWithoutAllocatedSize() throws {
        let original = FileStamp(device: 1, inode: 2, size: 3, modifiedSeconds: 4,
                                 modifiedNanoseconds: 5, linkCount: 1)
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(FileStamp.self, from: encoded)
        XCTAssertEqual(decoded, original)
        XCTAssertNil(decoded.allocatedBytes)
    }

    func testXcodeDerivedDataUsesMetadataAndKeepsUnknownProjectSeparate() throws {
        let parent = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/SysCleaner-XcodeTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: parent) }
        let derived = parent.appendingPathComponent("DerivedData")
        let known = derived.appendingPathComponent("Opaque-1")
        let unknown = derived.appendingPathComponent("Opaque-abcdefghijklmnopqrstuvwxabcd")
        try FileManager.default.createDirectory(at: known, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: unknown, withIntermediateDirectories: true)
        let accessed = Date(timeIntervalSince1970: 1_000)
        let metadata: [String: Any] = ["WorkspacePath": "/Projects/Actual/Actual.xcworkspace",
                                       "LastAccessedDate": accessed]
        try PropertyListSerialization.data(fromPropertyList: metadata, format: .xml, options: 0)
            .write(to: known.appendingPathComponent("info.plist"))
        try Data(repeating: 1, count: 32).write(to: known.appendingPathComponent("build.o"))
        try Data(repeating: 2, count: 16).write(to: unknown.appendingPathComponent("build.o"))

        let report = XcodeStorage.derivedDataEntries(roots: [derived])
        XCTAssertEqual(report.entries.count, 2)
        XCTAssertEqual(report.entries.first(where: { $0.url == known })?.note,
                       "/Projects/Actual/Actual.xcworkspace")
        XCTAssertEqual(report.entries.first(where: { $0.url == known })?.lastUsedDate, accessed)
        XCTAssertEqual(report.entries.first(where: { $0.url == unknown })?.note, "")
        XCTAssertNil(report.entries.first(where: { $0.url == unknown })?.lastUsedDate)
        XCTAssertEqual(report.entries.first(where: { $0.url == unknown })?.estimatedBytes, 16)
        let globalCache = derived.appendingPathComponent("ModuleCache.noindex")
        try FileManager.default.createDirectory(at: globalCache, withIntermediateDirectories: true)
        XCTAssertFalse(XcodeStorage.isProjectDirectory(globalCache))
        let excluded = XcodeStorage.derivedDataEntries(roots: [derived], excludedPaths: [unknown.path])
        XCTAssertEqual(excluded.entries.map(\.url), [known])
    }

    func testXcodeRecentSortUsesScannedMetadataUntilRescan() throws {
        let parent = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/SysCleaner-XcodeTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: parent) }
        let derived = parent.appendingPathComponent("DerivedData")
        let older = derived.appendingPathComponent("Older-1")
        let newer = derived.appendingPathComponent("Newer-1")
        let unknown = derived.appendingPathComponent("Unknown-abcdefghijklmnopqrstuvwxabcd")
        for directory in [older, newer, unknown] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        func writeAccessDate(_ date: Date, to directory: URL) throws {
            let metadata: [String: Any] = ["WorkspacePath": "/Projects/\(directory.lastPathComponent).xcodeproj",
                                           "LastAccessedDate": date]
            try PropertyListSerialization.data(fromPropertyList: metadata, format: .xml, options: 0)
                .write(to: directory.appendingPathComponent("info.plist"))
        }
        let early = Date(timeIntervalSince1970: 1_000)
        let late = Date(timeIntervalSince1970: 2_000)
        try writeAccessDate(early, to: older)
        try writeAccessDate(late, to: newer)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_500)],
                                              ofItemAtPath: unknown.path)

        let scanned = XcodeStorage.derivedDataEntries(roots: [derived]).entries
        XCTAssertEqual(XcodeStorage.sortedByRecentUse(scanned).map(\.url), [newer, unknown, older])

        try writeAccessDate(late.addingTimeInterval(1_000), to: older)
        XCTAssertEqual(XcodeStorage.sortedByRecentUse(scanned).map(\.url), [newer, unknown, older])
        let rescanned = XcodeStorage.derivedDataEntries(roots: [derived]).entries
        XCTAssertEqual(XcodeStorage.sortedByRecentUse(rescanned).map(\.url), [older, newer, unknown])
    }

    func testXcodeProjectGroupsAggregateKnownPathsAndKeepUnknownDirectoriesSeparate() throws {
        let parent = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/SysCleaner-XcodeTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: parent) }
        let roots = [parent.appendingPathComponent("Primary/DerivedData"),
                     parent.appendingPathComponent("Custom/DerivedData")]
        let known = roots.enumerated().map { index, root in root.appendingPathComponent("Known-\(index)") }
        let unknown = roots.enumerated().map { index, root in
            root.appendingPathComponent("Unknown\(index)-abcdefghijklmnopqrstuvwxabcd")
        }
        for (index, directory) in known.enumerated() {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let metadata: [String: Any] = ["WorkspacePath": "/Projects/Shared.xcworkspace",
                                           "LastAccessedDate": Date(timeIntervalSince1970: Double(index + 1) * 1_000)]
            try PropertyListSerialization.data(fromPropertyList: metadata, format: .xml, options: 0)
                .write(to: directory.appendingPathComponent("info.plist"))
            try Data(repeating: 1, count: (index + 1) * 10).write(to: directory.appendingPathComponent("build.o"))
        }
        for directory in unknown {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(repeating: 1, count: 5).write(to: directory.appendingPathComponent("build.o"))
        }

        let report = XcodeStorage.derivedDataEntries(roots: roots)
        let groups = XcodeStorage.projectGroups(report.entries)
        XCTAssertEqual(groups.count, 3)
        let shared = try XCTUnwrap(groups.first(where: { $0.projectPath == "/Projects/Shared.xcworkspace" }))
        XCTAssertEqual(Set(shared.entries.map(\.url)), Set(known))
        XCTAssertEqual(shared.logicalBytes, shared.entries.reduce(0) { $0 + $1.estimatedBytes })
        XCTAssertEqual(shared.allocatedBytes, shared.entries.reduce(0) { $0 + ($1.allocatedBytes ?? 0) })
        XCTAssertEqual(shared.lastActivity, Date(timeIntervalSince1970: 2_000))
        XCTAssertEqual(Set(groups.filter { $0.projectPath == nil }.flatMap(\.entries).map(\.url)), Set(unknown))
        XCTAssertTrue(groups.filter { $0.projectPath == nil }.allSatisfy { $0.entries.count == 1 })
    }

    func testXcodeEmptyAndUnreadableRootsReportCompleteness() throws {
        let parent = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/SysCleaner-XcodeTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: parent) }
        let empty = parent.appendingPathComponent("Empty/DerivedData")
        let unreadable = parent.appendingPathComponent("Denied/DerivedData")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: unreadable, withIntermediateDirectories: true)
        let emptyReport = XcodeStorage.derivedDataEntries(roots: [empty])
        XCTAssertTrue(emptyReport.entries.isEmpty)
        XCTAssertTrue(emptyReport.warnings.isEmpty)
        XCTAssertEqual(emptyReport.omittedCount, 0)

        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: unreadable.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: unreadable.path) }
        guard (try? FileManager.default.contentsOfDirectory(atPath: unreadable.path)) == nil else {
            throw XCTSkip("This process can read directories without permission")
        }
        let report = XcodeStorage.derivedDataEntries(roots: [empty, unreadable])
        XCTAssertTrue(report.entries.isEmpty)
        XCTAssertEqual(report.omittedCount, 1)
        XCTAssertEqual(report.warnings, ["Cannot read \(unreadable.path)"])
    }

    func testXcodeDerivedDataRejectsOverlappingAndSymlinkRootsWithoutDoubleCounting() throws {
        let parent = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/SysCleaner-XcodeTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("DerivedData")
        let project = root.appendingPathComponent("Project-abcdefghijklmnopqrstuvwxabcd")
        let nested = project.appendingPathComponent("DerivedData")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 21).write(to: nested.appendingPathComponent("build.o"))
        let alias = parent.appendingPathComponent("Alias/DerivedData")
        try FileManager.default.createDirectory(at: alias.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)

        XCTAssertTrue(XcodeStorage.isAllowedDerivedDataRoot(root))
        XCTAssertFalse(XcodeStorage.isAllowedDerivedDataRoot(alias))
        let report = XcodeStorage.derivedDataEntries(roots: [root, root, nested, alias])
        XCTAssertEqual(report.entries.count, 1)
        XCTAssertEqual(report.entries[0].url, project)
        XCTAssertEqual(report.entries[0].estimatedBytes, 21)
        XCTAssertEqual(report.omittedCount, 2)
        XCTAssertTrue(report.warnings.contains("Overlapping root \(nested.path)"))
        XCTAssertTrue(report.warnings.contains("Invalid root \(alias.path)"))
    }

    func testXcodeDerivedDataRejectsReadOnlyCategoryOverlap() throws {
        let root = XcodeStorage.defaultArchivesRoot
            .appendingPathComponent("SysCleaner-XcodeTests-\(UUID().uuidString)/DerivedData")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        XCTAssertFalse(XcodeStorage.isAllowedDerivedDataRoot(root))
        let report = XcodeStorage.derivedDataEntries(roots: [root])
        XCTAssertTrue(report.entries.isEmpty)
        XCTAssertEqual(report.omittedCount, 1)
        XCTAssertEqual(report.warnings, ["Invalid root \(root.path)"])
        let productsRoot = XcodeStorage.defaultXcodeRoot
            .appendingPathComponent("Products/SysCleaner-XcodeTests-\(UUID().uuidString)/DerivedData")
        defer { try? FileManager.default.removeItem(at: productsRoot.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: productsRoot, withIntermediateDirectories: true)
        XCTAssertFalse(XcodeStorage.isAllowedDerivedDataRoot(productsRoot))
    }

    func testXcodeSharedCachesAreReadOnlyAndExcludeProjectDirectories() throws {
        let parent = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/SysCleaner-XcodeTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("DerivedData")
        let cache = root.appendingPathComponent("ModuleCache.noindex")
        let project = root.appendingPathComponent("Project-abcdefghijklmnopqrstuvwxabcd")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 37).write(to: cache.appendingPathComponent("module.pcm"))
        try Data().write(to: cache.appendingPathComponent("info.plist"))
        try Data(repeating: 1, count: 99).write(to: project.appendingPathComponent("build.o"))

        let report = XcodeStorage.sharedCacheInventory(derivedDataRoots: [root, root])
        XCTAssertTrue(report.isComplete)
        XCTAssertEqual(report.items.map { $0.url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) },
                       [cache.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))])
        XCTAssertEqual(report.items[0].logicalBytes, 37)
        XCTAssertGreaterThanOrEqual(report.items[0].allocatedBytes, 37)
        XCTAssertTrue(report.items[0].isComplete)
        XCTAssertEqual(XcodeStorage.derivedDataEntries(roots: [root]).entries.count, 1)
        XCTAssertFalse(XcodeStorage.isAllowedDerivedDataRoot(
            XcodeStorage.defaultDerivedDataRoot.appendingPathComponent("ModuleCache.noindex")))
    }

    func testXcodeAdditionalDataListsOnlyConfirmedDirectoriesAndSkipsSymlinks() throws {
        let parent = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/SysCleaner-XcodeTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: parent) }
        let developer = parent.appendingPathComponent("Developer")
        let xcode = developer.appendingPathComponent("Xcode")
        let logs = xcode.appendingPathComponent("DeviceLogs")
        let downloads = developer.appendingPathComponent("DVTDownloads")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 11).write(to: logs.appendingPathComponent("log.txt"))
        try Data(repeating: 1, count: 23).write(to: downloads.appendingPathComponent("payload"))
        try FileManager.default.createSymbolicLink(at: xcode.appendingPathComponent("Products"),
                                                     withDestinationURL: downloads)

        let report = XcodeStorage.additionalDataInventory(xcodeRoot: xcode, developerRoot: developer)
        XCTAssertEqual(Set(report.items.map { $0.url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }),
                       Set([logs, downloads].map { $0.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }))
        XCTAssertEqual(report.items.reduce(0) { $0 + $1.logicalBytes }, 34)
        XCTAssertEqual(report.warnings, ["Cannot verify \(xcode.appendingPathComponent("Products").path)"])
        XCTAssertFalse(report.isComplete)
    }

    func testXcodeAdditionalDataReportsUnreadableDirectory() throws {
        let parent = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/SysCleaner-XcodeTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: parent) }
        let developer = parent.appendingPathComponent("Developer")
        let xcode = developer.appendingPathComponent("Xcode")
        let logs = xcode.appendingPathComponent("DeviceLogs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: logs.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: logs.path) }
        guard (try? FileManager.default.contentsOfDirectory(atPath: logs.path)) == nil else {
            throw XCTSkip("This process can read directories without permission")
        }
        let report = XcodeStorage.additionalDataInventory(xcodeRoot: xcode, developerRoot: developer)
        XCTAssertFalse(report.isComplete)
        XCTAssertEqual(report.warnings, ["Cannot verify \(logs.path)"])
        XCTAssertEqual(report.items.count, 1)
        XCTAssertFalse(report.items[0].isComplete)
    }

    func testXcodeReadOnlyScanCanCancelWithoutCountingMoreDirectories() throws {
        let parent = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/SysCleaner-XcodeTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("DerivedData")
        let cache = root.appendingPathComponent("CompilationCache.noindex")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 5).write(to: cache.appendingPathComponent("entry"))
        let control = ScanControl()
        control.cancel()
        let report = XcodeStorage.sharedCacheInventory(derivedDataRoots: [root], control: control)
        XCTAssertTrue(report.cancelled)
        XCTAssertTrue(report.items.isEmpty)
        XCTAssertFalse(report.isComplete)
    }

    func testXcodeReadOnlyScanReportsProgressAndStopsDuringLargeDirectory() throws {
        final class CancellationBox: @unchecked Sendable {
            var control: ScanControl?
            var observedFiles = 0
        }
        let parent = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/SysCleaner-XcodeTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("DerivedData")
        let cache = root.appendingPathComponent("ModuleCache.noindex")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        for index in 0..<200 {
            try Data([UInt8(index % 255)]).write(to: cache.appendingPathComponent("entry-\(index)"))
        }
        let box = CancellationBox()
        let control = ScanControl { progress in
            if progress.processedFiles == 0 && progress.processedDirectories == 0 {
                Thread.sleep(forTimeInterval: 0.25)
            } else if progress.processedFiles > 0 {
                box.observedFiles = progress.processedFiles
                box.control?.cancel()
            }
        }
        box.control = control
        let report = XcodeStorage.sharedCacheInventory(derivedDataRoots: [root], control: control)
        XCTAssertGreaterThan(box.observedFiles, 0)
        XCTAssertLessThan(box.observedFiles, 200)
        XCTAssertTrue(report.cancelled)
        XCTAssertEqual(report.items.count, 1)
        XCTAssertFalse(report.items[0].isComplete)
    }

    func testXcodeReadOnlyScanMarksChangedDirectoryPartial() throws {
        let parent = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/SysCleaner-XcodeTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("DerivedData")
        let cache = root.appendingPathComponent("SymbolCache.noindex")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data([1]).write(to: cache.appendingPathComponent("first"))
        let second = cache.appendingPathComponent("second")
        let control = ScanControl { progress in
            if progress.processedFiles == 0 && progress.processedDirectories == 0 {
                Thread.sleep(forTimeInterval: 0.25)
            } else if progress.processedFiles > 0 {
                try? Data([2]).write(to: second)
            }
        }
        let report = XcodeStorage.sharedCacheInventory(derivedDataRoots: [root], control: control)
        XCTAssertFalse(report.isComplete)
        XCTAssertFalse(report.items[0].isComplete)
        XCTAssertEqual(report.warnings, ["Cannot verify \(cache.path)"])
    }

    func testXcodeVerifiedSharedCacheRefusesRecentAndChangedDataThenRestoresFromTrash() throws {
        let parent = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/SysCleaner-XcodeTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("DerivedData")
        let cache = root.appendingPathComponent("ModuleCache.noindex")
        let file = cache.appendingPathComponent("module.pcm")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 64).write(to: file)

        let recentItem = try XCTUnwrap(XcodeStorage.sharedCacheInventory(derivedDataRoots: [root]).items.first)
        let recentEntry = try XCTUnwrap(XcodeStorage.cacheDeletionEntry(for: recentItem,
                                                                         derivedDataRoots: [root]))
        XCTAssertNil(XcodeStorage.cacheDeletionEntry(for: recentItem, derivedDataRoots: []))
        XCTAssertEqual(FileDeletion.refusal(for: recentEntry), "recentlyUsed")
        XCTAssertFalse(try XCTUnwrap(FileDeletion.execute([recentEntry], mode: .permanent).first).success)

        let oldDate = Date().addingTimeInterval(-3600)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: file.path)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: cache.path)
        let oldItem = try XCTUnwrap(XcodeStorage.sharedCacheInventory(derivedDataRoots: [root]).items.first)
        let oldEntry = try XCTUnwrap(XcodeStorage.cacheDeletionEntry(for: oldItem,
                                                                      derivedDataRoots: [root]))
        try Data(repeating: 2, count: 64).write(to: file)
        XCTAssertEqual(FileDeletion.refusal(for: oldEntry), "recentlyUsed")

        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: file.path)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: cache.path)
        XCTAssertEqual(FileDeletion.refusal(for: oldEntry), "changed")
        let safeItem = try XCTUnwrap(XcodeStorage.sharedCacheInventory(derivedDataRoots: [root]).items.first)
        let safeEntry = try XCTUnwrap(XcodeStorage.cacheDeletionEntry(for: safeItem,
                                                                       derivedDataRoots: [root]))
        let openFile = try FileHandle(forReadingFrom: file)
        XCTAssertEqual(FileDeletion.refusal(for: safeEntry), "fileInUse")
        try openFile.close()
        if FileDeletion.refusal(for: safeEntry) == "fileInUse" {
            throw XCTSkip("Xcode or an Xcode build process is active")
        }
        let result = try XCTUnwrap(FileDeletion.execute([safeEntry], mode: .trash).first)
        XCTAssertTrue(result.success, result.message)
        XCTAssertNotNil(result.trashSignature)
        let trashed = try XCTUnwrap(result.trashURL)
        let history = CleanupHistoryItem(path: cache.path, estimatedBytes: safeEntry.estimatedBytes,
                                         success: true, message: result.message, trashPath: trashed.path,
                                         scopePath: root.path, trashStamp: FileSafety.stamp(at: trashed),
                                         trashSignature: result.trashSignature)
        XCTAssertNil(FileRestoration.restore(history, category: .developerCache))
        XCTAssertTrue(FileSafety.isDirectory(cache))
    }

    func testXcodeUnverifiedSharedCacheStaysReadOnly() throws {
        let parent = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/SysCleaner-XcodeTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("DerivedData")
        let cache = root.appendingPathComponent("SymbolCache.noindex")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data([1]).write(to: cache.appendingPathComponent("symbol"))
        let item = try XCTUnwrap(XcodeStorage.sharedCacheInventory(derivedDataRoots: [root]).items.first)
        XCTAssertNil(XcodeStorage.cacheDeletionEntry(for: item, derivedDataRoots: [root]))
    }

    func testXcodeSharedCacheSymlinkNeverBecomesDeletable() throws {
        let parent = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/SysCleaner-XcodeTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("DerivedData")
        let outside = parent.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("ModuleCache.noindex")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let report = XcodeStorage.sharedCacheInventory(derivedDataRoots: [root])
        XCTAssertTrue(report.items.isEmpty)
        XCTAssertFalse(report.isComplete)
        XCTAssertEqual(report.warnings, ["Cannot verify \(link.path)"])
    }

    func testXcodeScanReportsDirectoryChangedWhileMeasuring() throws {
        let parent = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/SysCleaner-XcodeTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: parent) }
        let derived = parent.appendingPathComponent("DerivedData")
        let project = derived.appendingPathComponent("Changing-abcdefghijklmnopqrstuvwxabcd")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 8).write(to: project.appendingPathComponent("build.o"))
        let control = ScanControl { progress in
            if progress.processedDirectories == 1 && progress.processedFiles == 0 {
                Thread.sleep(forTimeInterval: 0.25)
            }
            guard progress.processedFiles == 1 else { return }
            try? Data(repeating: 2, count: 9).write(to: URL(fileURLWithPath: progress.currentPath))
        }
        control.begin(.discovering, path: derived)
        Thread.sleep(forTimeInterval: 0.25)
        let report = XcodeStorage.derivedDataEntries(roots: [derived], control: control)
        XCTAssertTrue(report.entries.isEmpty)
        XCTAssertEqual(report.omittedCount, 1)
        XCTAssertEqual(report.warnings, ["Cannot verify \(project.path)"])
    }

    func testXcodeDerivedDataChangeIsRefusedAndTrashCanRestore() throws {
        let parent = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/SysCleaner-XcodeTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: parent) }
        let derived = parent.appendingPathComponent("DerivedData")
        let project = derived.appendingPathComponent("Fixture-abcdefghijklmnopqrstuvwxabcd")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let file = project.appendingPathComponent("build.o")
        try Data(repeating: 1, count: 8).write(to: file)
        let entry = try XCTUnwrap(XcodeStorage.derivedDataEntries(roots: [derived]).entries.first)
        try Data(repeating: 2, count: 9).write(to: file)
        XCTAssertEqual(FileDeletion.refusal(for: entry), "changedOrRunning")

        let refreshed = try XCTUnwrap(XcodeStorage.derivedDataEntries(roots: [derived]).entries.first)
        if FileDeletion.refusal(for: refreshed) == "changedOrRunning" {
            throw XCTSkip("Xcode or a build process is active")
        }
        let result = try XCTUnwrap(FileDeletion.execute([refreshed], mode: .trash).first)
        XCTAssertTrue(result.success, result.message)
        let trashed = try XCTUnwrap(result.trashURL)
        let item = CleanupHistoryItem(path: project.path, estimatedBytes: refreshed.estimatedBytes,
                                      success: true, message: result.message, trashPath: trashed.path,
                                      scopePath: derived.path, trashStamp: FileSafety.stamp(at: trashed))
        XCTAssertNil(FileRestoration.restore(item, category: .developerCache))
        XCTAssertTrue(FileSafety.isDirectory(project))
    }

    func testSimulatorJSONAllowsOnlyShutdownDevices() throws {
        let json = """
        {"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-27-0":[
          {"udid":"00000000-0000-0000-0000-000000000001","name":"iPhone A","state":"Shutdown","isAvailable":true,"dataPathSize":4096},
          {"udid":"00000000-0000-0000-0000-000000000002","name":"iPhone B","state":"Booted","isAvailable":true,"dataPathSize":8192}
        ]}}
        """
        let devices = try XcodeStorage.parseSimulators(Data(json.utf8))
        XCTAssertEqual(devices.count, 2)
        XCTAssertTrue(try XCTUnwrap(devices.first(where: { $0.name == "iPhone A" })).canDelete)
        XCTAssertFalse(try XCTUnwrap(devices.first(where: { $0.name == "iPhone B" })).canDelete)
        XCTAssertEqual(devices[0].runtimeName, "iOS 27.0")
        XCTAssertNoThrow(try XcodeStorage.validateSimulatorDeletion(
            id: "00000000-0000-0000-0000-000000000001", in: devices))
        XCTAssertThrowsError(try XcodeStorage.validateSimulatorDeletion(
            id: "00000000-0000-0000-0000-000000000002", in: devices))
        XCTAssertThrowsError(try XcodeStorage.validateSimulatorDeletion(
            id: "00000000-0000-0000-0000-000000000001", in: devices.filter { $0.name != "iPhone A" }))
    }

    func testXcodeArchivesAreMeasuredForReadOnlyInventory() throws {
        let archivesRoot = root.appendingPathComponent("Archives")
        let archive = archivesRoot.appendingPathComponent("2026-10-16/Test.xcarchive")
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        let info: [String: Any] = ["ApplicationProperties": ["ApplicationPath": "Applications/Example.app"],
                                   "CreationDate": Date(timeIntervalSince1970: 1000)]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: archive.appendingPathComponent("Info.plist"))
        try Data(repeating: 1, count: 77).write(to: archive.appendingPathComponent("binary"))
        try Data().write(to: archivesRoot.appendingPathComponent(".DS_Store"))
        let result = XcodeStorage.archives(at: archivesRoot)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].name, "Example")
        XCTAssertGreaterThanOrEqual(result[0].logicalBytes, 77)
        XCTAssertEqual(result[0].created, Date(timeIntervalSince1970: 1000))
        XCTAssertTrue(XcodeStorage.archiveInventory(at: archivesRoot).isComplete)
    }

    func testCustomArchivesRootsAreCombinedWithoutDuplicateCounting() throws {
        let standard = root.appendingPathComponent("Archives")
        let custom = root.appendingPathComponent("Custom Archives")
        let first = standard.appendingPathComponent("2026-10-16/First.xcarchive")
        let second = custom.appendingPathComponent("2026-10-17/Second.xcarchive")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 11).write(to: first.appendingPathComponent("binary"))
        try Data(repeating: 2, count: 22).write(to: second.appendingPathComponent("binary"))

        let result = XcodeStorage.archiveInventory(roots: [standard, custom, standard,
                                                            custom.appendingPathComponent("2026-10-17")])
        XCTAssertEqual(Set(result.items.map { $0.url.standardizedFileURL.path }),
                       Set([first.path, second.path]))
        XCTAssertTrue(result.items.allSatisfy { $0.logicalBytes > 0 })
        XCTAssertEqual(result.warnings, ["Overlapping root \(custom.appendingPathComponent("2026-10-17").path)"])
        XCTAssertTrue(XcodeStorage.isAllowedArchivesRoot(custom))
        XCTAssertFalse(XcodeStorage.isAllowedArchivesRoot(XcodeStorage.defaultDerivedDataRoot))
    }

    func testCustomArchivesMissingAndSymbolicLinkSourcesAreReported() throws {
        let custom = root.appendingPathComponent("Custom Archives")
        let day = custom.appendingPathComponent("2026-10-17")
        let archive = day.appendingPathComponent("Real.xcarchive")
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        let alias = root.appendingPathComponent("Alias Archives")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: custom)
        let linkedArchive = day.appendingPathComponent("Alias.xcarchive")
        try FileManager.default.createSymbolicLink(at: linkedArchive, withDestinationURL: archive)
        let missing = root.appendingPathComponent("Missing Archives")

        let result = XcodeStorage.archiveInventory(roots: [custom, alias, missing])
        XCTAssertEqual(result.items.map { $0.url.standardizedFileURL.path }, [archive.path])
        XCTAssertTrue(result.warnings.contains("Cannot verify \(linkedArchive.path)"))
        XCTAssertTrue(result.warnings.contains("Invalid archive root \(alias.path)"))
        XCTAssertTrue(result.warnings.contains("Invalid archive root \(missing.path)"))
        XCTAssertFalse(result.isComplete)
    }

    func testXcodeRuntimeImagesParseReadOnlyMetadata() throws {
        let json = """
        {"00000000-0000-0000-0000-000000000001":{
          "identifier":"00000000-0000-0000-0000-000000000001",
          "runtimeIdentifier":"com.apple.CoreSimulator.SimRuntime.iOS-27-0",
          "path":"/System/Library/AssetsV2/Example.runtime",
          "version":"27.0","build":"24A434","state":"Ready",
          "sizeBytes":8192,"lastUsedAt":"2026-10-16T06:51:28Z"}}
        """
        let runtimes = try XcodeStorage.parseRuntimeImages(Data(json.utf8))
        XCTAssertEqual(runtimes.count, 1)
        XCTAssertEqual(runtimes[0].name, "iOS")
        XCTAssertEqual(runtimes[0].version, "27.0")
        XCTAssertEqual(runtimes[0].runtimeIdentifier, "com.apple.CoreSimulator.SimRuntime.iOS-27-0")
        XCTAssertEqual(runtimes[0].path, "/System/Library/AssetsV2/Example.runtime")
        XCTAssertEqual(runtimes[0].logicalBytes, 8192)
        XCTAssertNotNil(runtimes[0].lastUsed)
    }

    func testRuntimeAssociationDoesNotAssumeWhichImageDevicesUse() throws {
        let runtimeJSON = """
        {
          "image-a":{"identifier":"image-a","runtimeIdentifier":"com.apple.CoreSimulator.SimRuntime.iOS-27-0","build":"24A434"},
          "image-b":{"identifier":"image-b","runtimeIdentifier":"com.apple.CoreSimulator.SimRuntime.iOS-27-0","build":"24A5380g"},
          "image-c":{"identifier":"image-c","runtimeIdentifier":"com.apple.CoreSimulator.SimRuntime.iOS-27-1"},
          "image-unknown":{"identifier":"image-unknown"}
        }
        """
        let deviceJSON = """
        {"devices":{
          "com.apple.CoreSimulator.SimRuntime.iOS-27-0":[
            {"udid":"00000000-0000-0000-0000-000000000001","name":"A","state":"Shutdown"},
            {"udid":"00000000-0000-0000-0000-000000000002","name":"B","state":"Booted"}
          ],
          "com.apple.CoreSimulator.SimRuntime.iOS-27-1":[
            {"udid":"00000000-0000-0000-0000-000000000003","name":"C","state":"Shutdown"}
          ]
        }}
        """
        let runtimes = try XcodeStorage.parseRuntimeImages(Data(runtimeJSON.utf8))
        let devices = try XcodeStorage.parseSimulators(Data(deviceJSON.utf8))
        let shared = try XCTUnwrap(runtimes.first { $0.id == "image-a" })
        let association = try XCTUnwrap(XcodeStorage.runtimeAssociation(
            for: shared, among: runtimes, devices: devices))
        XCTAssertEqual(association.deviceCount, 2)
        XCTAssertEqual(association.bootedDeviceCount, 1)
        XCTAssertEqual(association.matchingImageCount, 2)
        XCTAssertNil(XcodeStorage.runtimeAssociation(
            for: try XCTUnwrap(runtimes.first { $0.id == "image-unknown" }),
            among: runtimes, devices: devices))
    }

    func testDeviceSupportInventoryMeasuresFoldersAndReportsMissingRoot() throws {
        let supportRoot = root.appendingPathComponent("iOS DeviceSupport")
        let device = supportRoot.appendingPathComponent("iPhone A 27.0")
        try FileManager.default.createDirectory(at: device, withIntermediateDirectories: true)
        try Data(repeating: 7, count: 100).write(to: device.appendingPathComponent("symbols"))
        let inventory = XcodeStorage.deviceSupportInventory(at: supportRoot)
        XCTAssertTrue(inventory.isComplete)
        XCTAssertEqual(inventory.items.count, 1)
        XCTAssertEqual(inventory.items[0].name, "iPhone A 27.0")
        XCTAssertEqual(inventory.items[0].logicalBytes, 100)
        XCTAssertTrue(XcodeStorage.deviceSupportInventory(
            at: root.appendingPathComponent("missing")).items.isEmpty)
    }
}
