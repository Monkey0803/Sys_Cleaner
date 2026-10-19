import AppKit
import Foundation

@MainActor
final class CleanerStore: ObservableObject {
    struct VolumeSummary: Identifiable {
        let id: String
        let name: String
        let totalBytes: Int64
        let freeBytes: Int64
        let systemReclaimableEstimate: Int64

        var usedBytes: Int64 { max(0, totalBytes - freeBytes) }
    }
    struct ScanMetrics {
        var allocatedBytes: Int64?
        var omittedCount = 0
    }
    private static let historyURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Sys Cleaner/cleanup-history.json")
    @Published var category: ScanCategory = .space {
        didSet { refreshVisibleEntries(); refreshSpaceChildren() }
    }
    @Published var root = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().standardizedFileURL {
        didSet { refreshSpaceChildren() }
    }
    @Published var entries: [ScanEntry] = [] {
        didSet { refreshVisibleEntries() }
    }
    @Published var spaceItems: [SpaceItem] = [] {
        didSet { refreshSpaceChildren() }
    }
    @Published private(set) var visibleEntries: [ScanEntry] = []
    @Published private(set) var visibleDuplicateGroups: [[ScanEntry]] = []
    private var visibleEntryIDs: Set<UUID> = []
    @Published private(set) var visibleSpaceChildren: [SpaceItem] = []
    @Published private(set) var sortSelection = AppPreferences.shared.sortSelection(for: .space) {
        didSet {
            AppPreferences.shared.setSortSelection(sortSelection, for: category)
            refreshVisibleEntries()
            refreshSpaceChildren()
        }
    }
    @Published var summaryCount = 0
    @Published var summaryBytes: Int64 = 0
    @Published private(set) var scanMetrics = ScanMetrics()
    @Published private(set) var volumes: [VolumeSummary] = CleanerStore.readVolumeSummaries()
    @Published var warnings: [String] = []
    @Published var selectedIDs: Set<UUID> = []
    @Published var isScanning = false
    @Published private(set) var scanProgress: ScanProgress?
    @Published var isDeleting = false
    @Published var hasScanned = false
    @Published var results: [DeleteResult] = []
    @Published private(set) var lastAvailableSpaceDelta: Int64?
    @Published var showResults = false
    @Published var showHistory = false
    @Published private(set) var cleanupHistory = (try? CleanupHistoryStorage.load(from: CleanerStore.historyURL)) ?? []
    @Published private(set) var historyError: String?
    @Published private(set) var restoreError: String?
    @Published var minimumMB = 100
    @Published var olderThanDays = 0
    @Published var resultQuery = "" {
        didSet { refreshVisibleEntries() }
    }
    @Published var resultFilter: ScanEntryFilter = .all {
        didSet { refreshVisibleEntries() }
    }
    @Published var spaceFolder: URL? {
        didSet { refreshSpaceChildren() }
    }
    @Published private(set) var reviewedApplicationName: String?

    private struct RunningScan {
        let id: UUID
        let control: ScanControl
        let isApplicationPreparation: Bool
    }

    private var runningScans: [ScanCategory: RunningScan] = [:]
    private var applicationSizeControl: ScanControl?
    private var applicationSizeGeneration = UUID()
    private var categoryResults: [ScanCategory: CategoryResult] = [:]
    private var applicationOverview: CategoryResult?

    private struct CategoryResult {
        let entries: [ScanEntry]
        let spaceItems: [SpaceItem]
        let summaryCount: Int
        let summaryBytes: Int64
        let scanMetrics: ScanMetrics
        let warnings: [String]
        let selectedIDs: Set<UUID>
        let hasScanned: Bool
        let isScanning: Bool
        let scanProgress: ScanProgress?
        let spaceFolder: URL?
        let resultQuery: String
        let resultFilter: ScanEntryFilter

        func removing(_ urls: Set<URL>) -> CategoryResult {
            let remaining = entries.filter { !urls.contains($0.url) }
            return CategoryResult(
                entries: remaining, spaceItems: spaceItems, summaryCount: remaining.count,
                summaryBytes: remaining.reduce(0) { $0 + $1.estimatedBytes },
                scanMetrics: ScanMetrics(
                    allocatedBytes: remaining.allSatisfy { $0.allocatedBytes != nil } ?
                        remaining.reduce(0) { $0 + ($1.allocatedBytes ?? 0) } : nil,
                    omittedCount: scanMetrics.omittedCount),
                warnings: warnings, selectedIDs: selectedIDs.subtracting(
                    entries.filter { urls.contains($0.url) }.map(\.id)),
                hasScanned: hasScanned, isScanning: isScanning, scanProgress: scanProgress,
                spaceFolder: spaceFolder, resultQuery: resultQuery, resultFilter: resultFilter
            )
        }

        func updatingProgress(_ progress: ScanProgress) -> CategoryResult {
            CategoryResult(entries: entries, spaceItems: spaceItems, summaryCount: summaryCount,
                           summaryBytes: summaryBytes, scanMetrics: scanMetrics,
                           warnings: warnings, selectedIDs: selectedIDs,
                           hasScanned: hasScanned, isScanning: isScanning, scanProgress: progress,
                           spaceFolder: spaceFolder, resultQuery: resultQuery, resultFilter: resultFilter)
        }

        func updatingApplicationSize(at url: URL, bytes: Int64, allocatedBytes: Int64?) -> CategoryResult {
            let updated = entries.map { entry in
                entry.url == url ? entry.withEstimatedBytes(bytes, allocatedBytes: allocatedBytes) : entry
            }
            return CategoryResult(entries: updated, spaceItems: spaceItems, summaryCount: summaryCount,
                                  summaryBytes: updated.reduce(0) { $0 + $1.estimatedBytes },
                                  scanMetrics: ScanMetrics(
                                    allocatedBytes: updated.allSatisfy { $0.allocatedBytes != nil } ?
                                        updated.reduce(0) { $0 + ($1.allocatedBytes ?? 0) } : nil,
                                    omittedCount: scanMetrics.omittedCount),
                                  warnings: warnings, selectedIDs: selectedIDs,
                                  hasScanned: hasScanned, isScanning: isScanning, scanProgress: scanProgress,
                                  spaceFolder: spaceFolder, resultQuery: resultQuery, resultFilter: resultFilter)
        }
    }

    var selectedEntries: [ScanEntry] { entries.filter { selectedIDs.contains($0.id) && $0.canDelete } }
    var hasHiddenSelection: Bool { !selectedIDs.isSubset(of: visibleEntryIDs) }
    var estimatedSelectedBytes: Int64 { selectedEntries.reduce(0) { $0 + $1.estimatedBytes } }
    var selectedAllocatedBytes: Int64? {
        let selected = selectedEntries
        return selected.allSatisfy { $0.allocatedBytes != nil } ?
            selected.reduce(0) { $0 + ($1.allocatedBytes ?? 0) } : nil
    }
    var hasPartialResults: Bool { scanMetrics.omittedCount > 0 || !warnings.isEmpty }

    func refreshVolumes() { volumes = Self.readVolumeSummaries() }

    private static func readVolumeSummaries() -> [VolumeSummary] {
        let keys: Set<URLResourceKey> = [.volumeNameKey, .volumeTotalCapacityKey,
                                         .volumeAvailableCapacityKey,
                                         .volumeAvailableCapacityForImportantUsageKey,
                                         .volumeIsLocalKey]
        let roots = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: Array(keys),
                                                           options: [.skipHiddenVolumes]) ?? []
        return roots.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.volumeIsLocal != false,
                  let total = values.volumeTotalCapacity, total > 0,
                  let free = values.volumeAvailableCapacity else { return nil }
            let availableForImportant = values.volumeAvailableCapacityForImportantUsage ?? Int64(free)
            return VolumeSummary(id: url.standardizedFileURL.path,
                                 name: values.volumeName ?? url.lastPathComponent,
                                 totalBytes: Int64(total), freeBytes: Int64(free),
                                 systemReclaimableEstimate: max(0, availableForImportant - Int64(free)))
        }
        .sorted { lhs, rhs in
            if lhs.id == "/" { return rhs.id != "/" }
            if rhs.id == "/" { return false }
            return lhs.name < rhs.name
        }
    }
    func selectDuplicateGroup(_ group: [ScanEntry]) {
        guard category == .duplicates, !isDeleting else { return }
        selectedIDs.formUnion(ScanResultGrouping.selectableIDs(in: group))
    }

    func clearDuplicateGroup(_ group: [ScanEntry]) {
        guard category == .duplicates, !isDeleting else { return }
        selectedIDs.subtract(group.map(\.id))
    }
    func ignoreDuplicateGroup(_ group: [ScanEntry]) {
        guard category == .duplicates, !isDeleting, let hash = group.first?.duplicateGroup else { return }
        AppPreferences.shared.ignoreDuplicateGroup(hash)
        selectedIDs.subtract(group.map(\.id))
        entries.removeAll { $0.duplicateGroup == hash }
        summaryCount = entries.count
        summaryBytes = entries.reduce(0) { $0 + $1.estimatedBytes }
        scanMetrics.allocatedBytes = entries.allSatisfy { $0.allocatedBytes != nil } ?
            entries.reduce(0) { $0 + ($1.allocatedBytes ?? 0) } : nil
    }
    func setSortField(_ field: ScanSortField) {
        guard category != .space || field != .modified else { return }
        sortSelection.field = field
    }

    func setSortDirection(_ direction: ScanSortDirection) {
        sortSelection.direction = direction
    }

    func refreshSorting() {
        refreshVisibleEntries()
        refreshSpaceChildren()
    }

    private func refreshVisibleEntries() {
        let filtered = ScanResultFiltering.entries(entries, category: category,
                                                   query: resultQuery, filter: resultFilter)
        let sorted = ScanSorting.entries(filtered, category: category, selection: sortSelection)
        visibleEntryIDs = Set(sorted.map(\.id))
        visibleDuplicateGroups = category == .duplicates ? ScanResultGrouping.duplicateGroups(sorted) : []
        visibleEntries = sorted
    }

    private func refreshSpaceChildren() {
        guard category == .space else {
            visibleSpaceChildren = []
            return
        }
        let base = (spaceFolder ?? root).standardizedFileURL
        visibleSpaceChildren = ScanSorting.spaceItems(
            spaceItems.filter { $0.parent.path == base.path },
            selection: sortSelection, otherName: L("otherFiles"))
    }

    func chooseFolder(startingAt volume: URL? = nil) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = L("choose")
        panel.directoryURL = volume
        if panel.runModal() == .OK, let url = panel.url {
            cancelAllScans()
            categoryResults.removeAll()
            applicationOverview = nil
            reviewedApplicationName = nil
            root = url.resolvingSymlinksInPath().standardizedFileURL
            entries = []
            spaceItems = []
            summaryCount = 0
            summaryBytes = 0
            scanMetrics = ScanMetrics()
            warnings = []
            selectedIDs = []
            hasScanned = false
            isScanning = false
            scanProgress = nil
            spaceFolder = root
        }
    }

    func changeCategory(_ newValue: ScanCategory) {
        guard category != newValue, !isDeleting else { return }
        if category == .uninstall { cancelApplicationSizeMeasurement() }
        if runningScans[category]?.isApplicationPreparation == true { cancel() }
        if category == .uninstall { backFromApplication() }
        if hasScanned || isScanning || !warnings.isEmpty {
            categoryResults[category] = currentResult()
        } else {
            categoryResults.removeValue(forKey: category)
        }
        category = newValue
        sortSelection = AppPreferences.shared.sortSelection(for: newValue)
        if let saved = categoryResults.removeValue(forKey: newValue) {
            restore(saved)
            if newValue == .uninstall && hasScanned && reviewedApplicationName == nil {
                beginApplicationSizeMeasurement(entries.filter { !$0.sizeIsKnown })
            }
        } else {
            resultQuery = ""
            resultFilter = .all
            entries = []
            spaceItems = []
            summaryCount = 0
            summaryBytes = 0
            scanMetrics = ScanMetrics()
            warnings = []
            selectedIDs = []
            hasScanned = false
            isScanning = false
            scanProgress = nil
            spaceFolder = root
        }
    }

    func invalidateScan() {
        cancel()
        cancelApplicationSizeMeasurement()
        categoryResults.removeValue(forKey: category)
        applicationOverview = nil
        reviewedApplicationName = nil
        entries = []
        spaceItems = []
        summaryCount = 0
        summaryBytes = 0
        scanMetrics = ScanMetrics()
        warnings = []
        selectedIDs = []
        hasScanned = false
        scanProgress = nil
    }

    func scan() {
        cancel()
        cancelApplicationSizeMeasurement()
        categoryResults.removeValue(forKey: category)
        applicationOverview = nil
        reviewedApplicationName = nil
        entries = []
        spaceItems = []
        summaryCount = 0
        summaryBytes = 0
        scanMetrics = ScanMetrics()
        warnings = []
        selectedIDs = []
        hasScanned = false
        scanProgress = nil
        spaceFolder = root
        isScanning = true
        let scannedCategory = category
        let scanID = UUID()
        let newControl = ScanControl { [weak self] progress in
            Task { @MainActor [weak self] in
                self?.receiveProgress(progress, category: scannedCategory, scanID: scanID)
            }
        }
        runningScans[scannedCategory] = RunningScan(id: scanID, control: newControl,
                                                    isApplicationPreparation: false)
        let request = ScanRequest(category: category, root: root, minimumBytes: Int64(minimumMB) * 1_024 * 1_024,
                                  olderThanDays: olderThanDays,
                                  excludedPaths: AppPreferences.shared.excludedPaths,
                                  ignoredDuplicateHashes: AppPreferences.shared.ignoredDuplicateHashes,
                                  derivedDataRoots: AppPreferences.shared.derivedDataRoots)
        Task.detached(priority: .userInitiated) { [weak self] in
            let report = FileScanner.scan(request, control: newControl)
            await self?.finishScan(report, category: scannedCategory, scanID: scanID)
        }
    }

    func prepareApplication(_ app: ScanEntry) {
        guard category == .uninstall, app.isDirectory, app.directorySignature == nil,
              app.risk != .protected, !isScanning, !isDeleting else { return }
        isScanning = true
        scanProgress = nil
        let scanID = UUID()
        let newControl = ScanControl { [weak self] progress in
            Task { @MainActor [weak self] in
                self?.receiveProgress(progress, category: .uninstall, scanID: scanID)
            }
        }
        runningScans[.uninstall] = RunningScan(id: scanID, control: newControl,
                                               isApplicationPreparation: true)
        let excludedPaths = AppPreferences.shared.excludedPaths
        Task.detached(priority: .userInitiated) { [weak self] in
            let report = FileScanner.prepareApplication(app, control: newControl,
                                                        excludedPaths: excludedPaths)
            await self?.finishApplicationPreparation(report, app: app, scanID: scanID)
        }
    }

    func chooseApplication() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = L("chooseAppHint")
        if panel.runModal() == .OK, let url = panel.url { openApplication(url) }
    }

    func openApplication(_ url: URL) {
        guard category == .uninstall, !isScanning, !isDeleting else { return }
        let app = url.standardizedFileURL
        let scope = app.deletingLastPathComponent()
        guard app.pathExtension.lowercased() == "app",
              let identifier = Bundle(url: app)?.bundleIdentifier,
              let stamp = FileSafety.stamp(at: app), FileSafety.isDirectory(app),
              FileSafety.isSafeLocation(app, scope: scope, category: .uninstall) else {
            warnings = ["invalidApp"]
            return
        }
        guard !FileSafety.isApplicationRunning(app, identifier: identifier) else {
            warnings = ["appRunning"]
            return
        }
        prepareApplication(ScanEntry(url: app, scope: scope, category: .uninstall,
                                     stamp: stamp, estimatedBytes: 0, sizeIsKnown: false,
                                     note: identifier, isDirectory: true, canDelete: false))
    }

    func backFromApplication() {
        guard category == .uninstall, !isDeleting, let overview = applicationOverview else { return }
        restore(overview)
        applicationOverview = nil
        reviewedApplicationName = nil
    }

    func cancel() {
        runningScans.removeValue(forKey: category)?.control.cancel()
        if isScanning {
            isScanning = false
            scanProgress = nil
            warnings = ["scanCancelled"]
        }
    }

    private func cancelAllScans() {
        for scan in runningScans.values { scan.control.cancel() }
        runningScans.removeAll()
        cancelApplicationSizeMeasurement()
    }

    private func cancelApplicationSizeMeasurement() {
        applicationSizeControl?.cancel()
        applicationSizeControl = nil
        applicationSizeGeneration = UUID()
    }

    private func beginApplicationSizeMeasurement(_ apps: [ScanEntry]) {
        cancelApplicationSizeMeasurement()
        let generation = applicationSizeGeneration
        let control = ScanControl()
        applicationSizeControl = control
        Task.detached(priority: .utility) { [weak self] in
            for app in apps where !control.isCancelled {
                guard app.isDirectory, FileSafety.stamp(at: app.url) == app.stamp,
                      let metrics = FileScanner.applicationBundleMetrics(app.url, control: control),
                      FileSafety.stamp(at: app.url) == app.stamp else { continue }
                await self?.receiveApplicationSize(app.url, logicalBytes: metrics.logicalBytes,
                                                   allocatedBytes: metrics.allocatedBytes,
                                                   generation: generation)
            }
        }
    }

    private func receiveApplicationSize(_ url: URL, logicalBytes: Int64,
                                        allocatedBytes: Int64, generation: UUID) {
        guard generation == applicationSizeGeneration else { return }
        if category == .uninstall && reviewedApplicationName == nil {
            entries = entries.map {
                $0.url == url ? $0.withEstimatedBytes(logicalBytes, allocatedBytes: allocatedBytes) : $0
            }
            summaryBytes = entries.reduce(0) { $0 + $1.estimatedBytes }
            scanMetrics.allocatedBytes = entries.allSatisfy { $0.allocatedBytes != nil } ?
                entries.reduce(0) { $0 + ($1.allocatedBytes ?? 0) } : nil
        } else if let saved = categoryResults[.uninstall] {
            categoryResults[.uninstall] = saved.updatingApplicationSize(
                at: url, bytes: logicalBytes, allocatedBytes: allocatedBytes)
        }
        if let overview = applicationOverview {
            applicationOverview = overview.updatingApplicationSize(
                at: url, bytes: logicalBytes, allocatedBytes: allocatedBytes)
        }
    }

    func delete(_ mode: DeleteMode) {
        let chosen = selectedEntries
        guard !chosen.isEmpty, !hasHiddenSelection, !isDeleting else { return }
        isDeleting = true
        let deletedCategory = category
        Task.detached(priority: .userInitiated) { [weak self] in
            let capacityURL = chosen.allSatisfy { $0.stamp.device == chosen[0].stamp.device } ?
                chosen[0].scope : nil
            let before = capacityURL.flatMap(observedAvailableCapacity)
            let outcomes = FileDeletion.execute(chosen, mode: mode)
            let after = capacityURL.flatMap(observedAvailableCapacity)
            let delta = before.flatMap { initial in after.map { $0 - initial } }
            await self?.finishDelete(outcomes, selected: chosen, category: deletedCategory,
                                     mode: mode, availableSpaceDelta: delta)
        }
    }

    private func finishScan(_ report: ScanReport, category scannedCategory: ScanCategory, scanID: UUID) {
        guard runningScans[scannedCategory]?.id == scanID else { return }
        runningScans.removeValue(forKey: scannedCategory)
        if category == scannedCategory {
            entries = report.entries
            spaceItems = report.spaceItems
            summaryCount = report.scannedFileCount
            summaryBytes = report.scannedBytes
            scanMetrics = ScanMetrics(allocatedBytes: report.scannedAllocatedBytes,
                                      omittedCount: report.omittedCount)
            warnings = report.warnings
            isScanning = false
            scanProgress = nil
            hasScanned = !report.cancelled
        } else if let previous = categoryResults[scannedCategory] {
            categoryResults[scannedCategory] = CategoryResult(
                entries: report.entries, spaceItems: report.spaceItems,
                summaryCount: report.scannedFileCount, summaryBytes: report.scannedBytes,
                scanMetrics: ScanMetrics(allocatedBytes: report.scannedAllocatedBytes,
                                         omittedCount: report.omittedCount),
                warnings: report.warnings, selectedIDs: [], hasScanned: !report.cancelled,
                isScanning: false, scanProgress: nil,
                spaceFolder: previous.spaceFolder, resultQuery: previous.resultQuery,
                resultFilter: previous.resultFilter
            )
        }
        if scannedCategory == .uninstall && category == .uninstall && !report.cancelled {
            beginApplicationSizeMeasurement(report.entries.filter { !$0.sizeIsKnown })
        }
        if scannedCategory == .space { refreshVolumes() }
    }

    private func finishApplicationPreparation(_ report: ScanReport, app: ScanEntry, scanID: UUID) {
        guard runningScans[.uninstall]?.id == scanID else { return }
        runningScans.removeValue(forKey: .uninstall)
        isScanning = false
        scanProgress = nil
        if !report.cancelled && !report.entries.isEmpty {
            let overview = currentResult()
            if let measuredApp = report.entries.first(where: { $0.url == app.url && $0.isDirectory }) {
                applicationOverview = overview.updatingApplicationSize(at: app.url,
                                                                       bytes: measuredApp.estimatedBytes,
                                                                       allocatedBytes: measuredApp.allocatedBytes)
            } else {
                applicationOverview = overview
            }
            reviewedApplicationName = app.url.lastPathComponent
            entries = report.entries
            summaryCount = report.entries.count
            summaryBytes = report.entries.reduce(0) { $0 + $1.estimatedBytes }
            scanMetrics = ScanMetrics(allocatedBytes: report.scannedAllocatedBytes,
                                      omittedCount: report.omittedCount)
            selectedIDs = []
            resultQuery = ""
            resultFilter = .all
            warnings = report.warnings
        } else {
            warnings.append(contentsOf: report.warnings)
        }
    }

    private func receiveProgress(_ progress: ScanProgress, category scannedCategory: ScanCategory, scanID: UUID) {
        guard runningScans[scannedCategory]?.id == scanID else { return }
        if category == scannedCategory {
            scanProgress = progress
        } else if let previous = categoryResults[scannedCategory] {
            categoryResults[scannedCategory] = previous.updatingProgress(progress)
        }
    }

    private func finishDelete(_ outcomes: [DeleteResult], selected: [ScanEntry],
                              category deletedCategory: ScanCategory, mode: DeleteMode,
                              availableSpaceDelta: Int64?) {
        results = outcomes
        lastAvailableSpaceDelta = availableSpaceDelta
        showResults = true
        let sizes = selected.reduce(into: [URL: Int64]()) { sizes, entry in
            sizes[entry.url] = entry.estimatedBytes
        }
        let scopes = selected.reduce(into: [URL: String]()) { scopes, entry in
            scopes[entry.url] = entry.scope.path
        }
        let items = outcomes.map { result in
            CleanupHistoryItem(path: result.url.path, estimatedBytes: sizes[result.url] ?? 0,
                               success: result.success, message: result.message,
                               trashPath: result.trashURL?.path, scopePath: scopes[result.url],
                               trashStamp: result.trashURL.flatMap { FileSafety.stamp(at: $0) })
        }
        cleanupHistory.insert(CleanupHistoryRecord(category: deletedCategory.rawValue,
                                                   mode: mode == .trash ? "trash" : "permanent",
                                                   items: items), at: 0)
        if cleanupHistory.count > 50 { cleanupHistory.removeLast(cleanupHistory.count - 50) }
        do {
            try CleanupHistoryStorage.save(cleanupHistory, to: Self.historyURL)
            historyError = nil
        } catch {
            historyError = error.localizedDescription
        }
        if outcomes.contains(where: \.success) {
            cancelAllScans()
            categoryResults.removeAll()
        }
        let removed = Set(outcomes.filter(\.success).map(\.url))
        if !removed.isEmpty, let overview = applicationOverview {
            applicationOverview = overview.removing(removed)
        }
        entries.removeAll { removed.contains($0.url) }
        summaryCount = entries.count
        summaryBytes = entries.reduce(0) { $0 + $1.estimatedBytes }
        scanMetrics.allocatedBytes = entries.allSatisfy { $0.allocatedBytes != nil } ?
            entries.reduce(0) { $0 + ($1.allocatedBytes ?? 0) } : nil
        selectedIDs.subtract(selected.map(\.id))
        isDeleting = false
    }

    func restoreHistoryItem(recordID: UUID, itemID: UUID) {
        guard let recordIndex = cleanupHistory.firstIndex(where: { $0.id == recordID }),
              let itemIndex = cleanupHistory[recordIndex].items.firstIndex(where: { $0.id == itemID }),
              let category = ScanCategory(rawValue: cleanupHistory[recordIndex].category) else { return }
        let item = cleanupHistory[recordIndex].items[itemIndex]
        if let failure = FileRestoration.restore(item, category: category) {
            restoreError = L(failure)
            return
        }
        var updated = cleanupHistory
        updated[recordIndex].items[itemIndex].restoredAt = Date()
        cleanupHistory = updated
        restoreError = nil
        do {
            try CleanupHistoryStorage.save(cleanupHistory, to: Self.historyURL)
            historyError = nil
        } catch {
            historyError = error.localizedDescription
        }
        cancelAllScans()
        categoryResults.removeAll()
        invalidateScan()
    }

    private func currentResult() -> CategoryResult {
        CategoryResult(
            entries: entries, spaceItems: spaceItems, summaryCount: summaryCount,
            summaryBytes: summaryBytes, scanMetrics: scanMetrics,
            warnings: warnings, selectedIDs: selectedIDs,
            hasScanned: hasScanned, isScanning: isScanning, scanProgress: scanProgress,
            spaceFolder: spaceFolder, resultQuery: resultQuery, resultFilter: resultFilter
        )
    }

    private func restore(_ result: CategoryResult) {
        entries = result.entries
        spaceItems = result.spaceItems
        summaryCount = result.summaryCount
        summaryBytes = result.summaryBytes
        scanMetrics = result.scanMetrics
        warnings = result.warnings
        selectedIDs = result.selectedIDs
        hasScanned = result.hasScanned
        isScanning = result.isScanning
        scanProgress = result.scanProgress
        spaceFolder = result.spaceFolder
        resultQuery = result.resultQuery
        resultFilter = result.resultFilter
    }

    func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }

    func openFullDiskAccess() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}

private func observedAvailableCapacity(_ url: URL) -> Int64? {
    try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        .volumeAvailableCapacityForImportantUsage
}

func L(_ key: String) -> String {
    let selected = AppLanguage(rawValue: UserDefaults.standard.string(forKey: "AppLanguage") ?? "") ?? .system
    return selected.bundle.localizedString(forKey: key, value: key, table: nil)
}

extension ScanCategory {
    var title: String { L(rawValue) }
    var symbol: String {
        switch self {
        case .space: "chart.pie"
        case .large: "externaldrive"
        case .duplicates: "doc.on.doc"
        case .systemCache: "folder.badge.gearshape"
        case .developerCache: "hammer"
        case .uninstall: "app.badge"
        case .orphans: "questionmark.folder"
        }
    }
}
