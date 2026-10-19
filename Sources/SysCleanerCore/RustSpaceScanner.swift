import Foundation

struct RustSpaceListing: Decodable {
    struct File: Decodable {
        let path: String
        let logical: Int64
        let allocated: Int64
    }

    let root: String
    let directories: [String]
    let files: [File]
    let omitted: [String]

    func path(_ value: String, rebasedTo rootURL: URL, isDirectory: Bool = false) -> URL? {
        let base = rootURL.path
        if value == root { return rootURL }
        guard value.hasPrefix(root + "/") else { return nil }
        return URL(fileURLWithPath: base + value.dropFirst(root.count), isDirectory: isDirectory)
    }
}

enum RustSpaceScanner {
    enum Outcome {
        case completed(RustSpaceListing)
        case cancelled
        case unavailable
    }

    static func read(root: URL, excludedPaths: [String], control: ScanControl,
                     helperOverride: URL? = nil) -> Outcome {
        if control.isCancelled { return .cancelled }
        guard isEligible(root: root) else { return .unavailable }
        let helper = helperOverride ?? Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/SysCleanerScanHelper")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else { return .unavailable }

        let process = Process()
        process.executableURL = helper
        process.arguments = [root.path] + excludedPaths.flatMap { ["--exclude", $0] }
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        do {
            try process.run()
        } catch {
            return .unavailable
        }
        control.setCancellationHandler {
            if process.isRunning { process.terminate() }
        }
        defer { control.setCancellationHandler(nil) }

        var bytes = Data()
        do {
            while let chunk = try output.fileHandleForReading.read(upToCount: 65_536), !chunk.isEmpty {
                guard bytes.count <= 256 * 1_024 * 1_024 - chunk.count else {
                    if process.isRunning { process.terminate() }
                    process.waitUntilExit()
                    return .unavailable
                }
                bytes.append(chunk)
            }
        } catch {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            return control.isCancelled ? .cancelled : .unavailable
        }
        process.waitUntilExit()
        if control.isCancelled { return .cancelled }
        guard process.terminationStatus == 0,
              let listing = try? JSONDecoder().decode(RustSpaceListing.self, from: bytes),
              listing.root == root.path,
              listing.directories.contains(listing.root),
              listing.directories.allSatisfy({ listing.path($0, rebasedTo: root, isDirectory: true) != nil }),
              listing.files.allSatisfy({ listing.path($0.path, rebasedTo: root) != nil }),
              listing.omitted.allSatisfy({ listing.path($0, rebasedTo: root) != nil }) else {
            return .unavailable
        }
        return .completed(listing)
    }

    static func isEligible(root: URL) -> Bool {
        if FileSafety.isCloudPlaceholder(root) { return false }
        let path = root.standardizedFileURL.path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for cloud in [home + "/Library/Mobile Documents", home + "/Library/CloudStorage"] {
            guard FileManager.default.fileExists(atPath: cloud) else { continue }
            if path == cloud || path.hasPrefix(cloud + "/") || cloud.hasPrefix(path + "/") {
                return false
            }
        }
        let keys: Set<URLResourceKey> = [.volumeIsLocalKey]
        if let values = try? root.resourceValues(forKeys: keys), values.volumeIsLocal == false {
            return false
        }
        return true
    }
}
