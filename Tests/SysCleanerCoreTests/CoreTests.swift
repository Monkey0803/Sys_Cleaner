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
}
