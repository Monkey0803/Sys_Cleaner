import AppKit
import Foundation

@MainActor
final class CleanerStore: ObservableObject {
    enum ProjectHistoryStatus {
        case notScanned, incomplete, storageError, comparison(XcodeProjectComparison)
    }

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
    struct OverviewScanState {
        let category: ScanCategory
        let completed: Int
        let total: Int
        let progress: ScanProgress?
    }
    struct VolumeAccountingSummary {
        let rootPath: String
        let scannedAt: Date?
        let volumeName: String?
        let systemReclaimableEstimate: Int64?
        let result: SpaceAccounting
    }
    private static let historyURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Sys Cleaner/cleanup-history.json")
    private static let projectHistoryURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Sys Cleaner/xcode-project-history.json")
    private static let spaceHistoryURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Sys Cleaner/space-scan-history.json")
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
    @Published private(set) var spaceTree: SpaceTree? {
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
    @Published private(set) var cloudCurrentCount = 0
    @Published private(set) var cloudRemoteCount = 0
    @Published private(set) var volumes: [VolumeSummary] = CleanerStore.readVolumeSummaries()
    @Published var warnings: [String] = []
    @Published var selectedIDs: Set<UUID> = []
    @Published var isScanning = false
    @Published private(set) var scanProgress: ScanProgress?
    @Published private(set) var projectHistoryStatus: ProjectHistoryStatus = .notScanned
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
    @Published var cloudFolder: URL = ICloudDrive.root {
        didSet {
            selectedIDs = []
            refreshVisibleEntries()
        }
    }
    @Published private(set) var reviewedApplicationName: String?
    @Published private(set) var lastReviewedApplicationName: String?
    @Published private(set) var cleanupOverview = CleanupOverviewSnapshot.make(sources: [])
    @Published private(set) var scanDiagnostics: [ScanCategory: [ScanDiagnostic]] = [:]
    @Published private(set) var spaceGrowthComparison: SpaceGrowthComparison =
        (try? SpaceScanHistory.load(from: CleanerStore.spaceHistoryURL).latestComparison) ?? .noPrevious
    @Published private(set) var latestSpaceSnapshot: SpaceScanSnapshot? =
        try? SpaceScanHistory.load(from: CleanerStore.spaceHistoryURL).snapshots.last
    @Published private(set) var lastSpaceScanRootPath: String?
    @Published private(set) var lastSpaceScanIncomplete = false
    @Published private(set) var spaceHistoryError: String?
    @Published private(set) var overviewScanState: OverviewScanState?
    @Published private(set) var overviewScanCompletedCount: Int?
    @Published private(set) var overviewScanWasCancelled = false

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
    private var lastReviewedApplicationEntries: [ScanEntry]?
    private var xcodeSupplemental: [CleanupOverviewItem] = []
    private var xcodeSupplementalScanned = false
    private var xcodeSupplementalIncomplete = false
    private var xcodeExtraDiagnostics: [ScanDiagnostic] = []
    private var requestedXcodeOperation: CleanupOverviewOperation?
    private var latestSpaceScanID: UUID?
    private var overviewScanID: UUID?
    private var overviewScanControl: ScanControl?
    private var overviewScanTask: Task<Void, Never>?

    private struct CategoryResult {
        let entries: [ScanEntry]
        let spaceItems: [SpaceItem]
        let spaceTree: SpaceTree?
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
                entries: remaining, spaceItems: spaceItems, spaceTree: spaceTree,
                summaryCount: remaining.count,
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
            CategoryResult(entries: entries, spaceItems: spaceItems, spaceTree: spaceTree,
                           summaryCount: summaryCount,
                           summaryBytes: summaryBytes, scanMetrics: scanMetrics,
                           warnings: warnings, selectedIDs: selectedIDs,
                           hasScanned: hasScanned, isScanning: isScanning, scanProgress: progress,
                           spaceFolder: spaceFolder, resultQuery: resultQuery, resultFilter: resultFilter)
        }

        func updatingApplicationSize(at url: URL, bytes: Int64, allocatedBytes: Int64?) -> CategoryResult {
            let updated = entries.map { entry in
                entry.url == url ? entry.withEstimatedBytes(bytes, allocatedBytes: allocatedBytes) : entry
            }
            return CategoryResult(entries: updated, spaceItems: spaceItems, spaceTree: spaceTree,
                                  summaryCount: summaryCount,
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
    var hasPartialResults: Bool {
        if category == .space, spaceTree != nil {
            return !ScanReport.spaceTotalsAreComplete(warnings: warnings,
                                                     omittedCount: scanMetrics.omittedCount)
        }
        return scanMetrics.omittedCount > 0 || !warnings.isEmpty
    }
    var hasSpaceResults: Bool { spaceTree?.hasDisplayItems ?? !spaceItems.isEmpty }
    var xcodeInventoryWasScanned: Bool { xcodeSupplementalScanned }
    var canStartOverviewScan: Bool {
        category == .overview && overviewScanState == nil && runningScans.isEmpty && !isDeleting
    }
    var volumeAccountingSummary: VolumeAccountingSummary? {
        guard let rootPath = lastSpaceScanRootPath ?? latestSpaceSnapshot?.rootPath else { return nil }
        let volume = volumes.first { $0.id == rootPath }
        let result = SpaceAccounting.assess(
            scanRootPath: rootPath, volumeRootPath: volume?.id,
            volumeUsedBytes: volume?.usedBytes,
            scannedAllocatedBytes: latestSpaceSnapshot?.rootPath == rootPath
                ? latestSpaceSnapshot?.rootAllocatedBytes : nil,
            complete: !lastSpaceScanIncomplete && latestSpaceSnapshot?.rootPath == rootPath)
        return VolumeAccountingSummary(rootPath: rootPath,
            scannedAt: latestSpaceSnapshot?.rootPath == rootPath ? latestSpaceSnapshot?.date : nil,
            volumeName: volume?.name,
            systemReclaimableEstimate: volume?.systemReclaimableEstimate,
            result: result)
    }

    func refreshVolumes() { volumes = Self.readVolumeSummaries() }

    func updateXcodeOverview(caches: [ScanEntry], simulators: [XcodeSimulator], incomplete: Bool,
                             warnings: [String] = []) {
        xcodeSupplemental = caches.map {
            CleanupOverviewItem(path: $0.url.path, category: .developerCache,
                                estimatedBytes: $0.allocatedBytes ?? $0.estimatedBytes,
                                isDirectory: $0.isDirectory, operation: .trash)
        } + simulators.compactMap { simulator in
            guard simulator.canDelete, let path = simulator.dataPath, let bytes = simulator.dataBytes else {
                return nil
            }
            return CleanupOverviewItem(path: path.path, category: .developerCache,
                                       estimatedBytes: bytes, isDirectory: true, operation: .simulator,
                                       displayName: "\(simulator.name) · \(simulator.runtimeName)")
        }
        xcodeSupplementalScanned = true
        xcodeSupplementalIncomplete = incomplete
        xcodeExtraDiagnostics = ScanDiagnostic.make(warnings: warnings, omittedCount: 0)
        rebuildCleanupOverview()
    }

    func clearXcodeOverview() {
        xcodeSupplemental = []
        xcodeSupplementalScanned = false
        xcodeSupplementalIncomplete = false
        xcodeExtraDiagnostics = []
        rebuildCleanupOverview()
    }

    func diagnostics(for category: ScanCategory) -> [ScanDiagnostic] {
        (scanDiagnostics[category] ?? []) + (category == .developerCache ? xcodeExtraDiagnostics : [])
    }

    private func rebuildCleanupOverview() {
        var results = categoryResults
        if category != .overview && hasScanned { results[category] = currentResult() }
        let sources = results.compactMap { key, result -> CleanupOverviewSource? in
            guard result.hasScanned else { return nil }
            let candidates = key == .uninstall ? (lastReviewedApplicationEntries ?? result.entries) : result.entries
            let incomplete = key == .space && result.spaceTree != nil
                ? !ScanReport.spaceTotalsAreComplete(warnings: result.warnings,
                                                    omittedCount: result.scanMetrics.omittedCount)
                : result.scanMetrics.omittedCount > 0 || !result.warnings.isEmpty
            return CleanupOverviewSource(category: key, entries: candidates,
                                         incomplete: incomplete,
                                         omittedCount: result.scanMetrics.omittedCount)
        }
        cleanupOverview = CleanupOverviewSnapshot.make(
            sources: sources, supplemental: xcodeSupplemental,
            supplementalScanned: xcodeSupplementalScanned ? [.developerCache] : [],
            supplementalIncomplete: (xcodeSupplementalIncomplete ||
                (results[.developerCache]?.hasScanned == true && !xcodeSupplementalScanned))
                ? [.developerCache] : [])
    }

    func scanScopePaths(for category: ScanCategory) -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch category {
        case .overview: return []
        case .space, .large, .duplicates: return [root.path]
        case .downloads: return [home.appendingPathComponent("Downloads").path]
        case .icloud: return [ICloudDrive.root.path]
        case .systemCache: return FileScanner.systemCacheLocations().map(\.path)
        case .developerCache:
            return ([XcodeStorage.defaultDerivedDataRoot, XcodeStorage.defaultArchivesRoot,
                     XcodeStorage.defaultDeviceSupportRoot] +
                    XcodeStorage.additionalReviewLocations() + AppPreferences.shared.derivedDataRoots +
                    AppPreferences.shared.archivesRoots).map(\.path) + [L("overviewRuntimeScope")]
        case .uninstall: return ["/Applications", home.appendingPathComponent("Applications").path]
        case .orphans: return FileScanner.orphanCandidateLocations().map(\.path)
        }
    }

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
    func ignoreOrphanGroup(_ group: OrphanReviewGroup) {
        guard category == .orphans, !isDeleting, !isScanning else { return }
        AppPreferences.shared.ignoreOrphanIdentifier(group.id)
        let paths = Set(group.entries.map(\.url))
        entries.removeAll { paths.contains($0.url) }
        summaryCount = entries.count
        summaryBytes = entries.reduce(0) { $0 + $1.estimatedBytes }
        scanMetrics.allocatedBytes = entries.allSatisfy { $0.allocatedBytes != nil } ?
            entries.reduce(0) { $0 + ($1.allocatedBytes ?? 0) } : nil
    }
    func restoreIgnoredOrphanIdentifier(_ identifier: String) {
        guard category == .orphans, !isDeleting, !isScanning else { return }
        AppPreferences.shared.restoreOrphanIdentifier(identifier)
        scan()
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
        let browsing = category == .icloud && resultQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? filtered.filter { $0.url.deletingLastPathComponent().standardizedFileURL == cloudFolder.standardizedFileURL }
            : filtered
        let sorted = ScanSorting.entries(browsing, category: category, selection: sortSelection)
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
            spaceTree?.children(of: base) ?? spaceItems.filter { $0.parent.path == base.path },
            selection: sortSelection, otherName: L("otherFiles"))
    }

    func chooseFolder(startingAt volume: URL? = nil) {
        guard [.space, .large, .duplicates].contains(category) else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = L("choose")
        panel.directoryURL = volume
        if panel.runModal() == .OK, let url = panel.url {
            setScanRoot(url)
        }
    }

    func scanEntireVolume(_ volume: VolumeSummary) {
        guard category == .space, !isDeleting, !isScanning else { return }
        setScanRoot(URL(fileURLWithPath: volume.id))
        scan()
    }

    private func setScanRoot(_ url: URL) {
        let chosenRoot = url.resolvingSymlinksInPath().standardizedFileURL
        guard chosenRoot != root else { return }
        for category in [ScanCategory.space, .large, .duplicates] {
            runningScans.removeValue(forKey: category)?.control.cancel()
            categoryResults.removeValue(forKey: category)
            scanDiagnostics[category] = nil
        }
        latestSpaceScanID = nil
        root = chosenRoot
        entries = []
        spaceItems = []
        spaceTree = nil
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

    func changeCategory(_ newValue: ScanCategory) {
        guard category != newValue, !isDeleting else { return }
        if category == .overview { cancelOverviewScan() }
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
            spaceTree = nil
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
        if newValue == .overview { rebuildCleanupOverview() }
    }

    func reviewOverviewCandidate(_ item: CleanupOverviewItem) {
        requestedXcodeOperation = item.category == .developerCache ? item.operation : nil
        changeCategory(item.category)
        switch item.category {
        case .downloads, .large, .systemCache, .icloud:
            resultQuery = item.path
        default:
            break
        }
    }

    func takeXcodeReviewOperation() -> CleanupOverviewOperation? {
        defer { requestedXcodeOperation = nil }
        return requestedXcodeOperation
    }

    func invalidateScan() {
        cancel()
        cancelApplicationSizeMeasurement()
        categoryResults.removeValue(forKey: category)
        scanDiagnostics[category] = nil
        applicationOverview = nil
        reviewedApplicationName = nil
        if category == .uninstall {
            lastReviewedApplicationName = nil
            lastReviewedApplicationEntries = nil
        }
        entries = []
        spaceItems = []
        spaceTree = nil
        summaryCount = 0
        summaryBytes = 0
        scanMetrics = ScanMetrics()
        warnings = []
        selectedIDs = []
        hasScanned = false
        scanProgress = nil
        if category == .developerCache { projectHistoryStatus = .notScanned }
    }

    func scan() {
        guard category != .overview else { return }
        cancel()
        cancelApplicationSizeMeasurement()
        categoryResults.removeValue(forKey: category)
        scanDiagnostics[category] = nil
        applicationOverview = nil
        reviewedApplicationName = nil
        if category == .uninstall {
            lastReviewedApplicationName = nil
            lastReviewedApplicationEntries = nil
        }
        entries = []
        spaceItems = []
        spaceTree = nil
        summaryCount = 0
        summaryBytes = 0
        scanMetrics = ScanMetrics()
        warnings = []
        selectedIDs = []
        hasScanned = false
        scanProgress = nil
        if category == .developerCache { projectHistoryStatus = .notScanned }
        spaceFolder = root
        isScanning = true
        let scannedCategory = category
        let scanID = UUID()
        if category == .space { latestSpaceScanID = scanID }
        let newControl = ScanControl { [weak self] progress in
            Task { @MainActor [weak self] in
                self?.receiveProgress(progress, category: scannedCategory, scanID: scanID)
            }
        }
        runningScans[scannedCategory] = RunningScan(id: scanID, control: newControl,
                                                    isApplicationPreparation: false)
        let scanRoot = category == .downloads ? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads") : root
        let request = ScanRequest(category: category, root: scanRoot,
                                  minimumBytes: Int64(minimumMB) * 1_024 * 1_024,
                                  olderThanDays: olderThanDays,
                                  excludedPaths: AppPreferences.shared.excludedPaths,
                                  ignoredDuplicateHashes: AppPreferences.shared.ignoredDuplicateHashes,
                                  ignoredOrphanIdentifiers: AppPreferences.shared.ignoredOrphanIdentifiers,
                                  derivedDataRoots: AppPreferences.shared.derivedDataRoots)
        Task.detached(priority: .userInitiated) { [weak self] in
            let report = FileScanner.scan(request, control: newControl)
            let spaceSnapshot: SpaceScanSnapshot?
            if scannedCategory == .space, report.hasCompleteSpaceTotals, let tree = report.spaceTree {
                spaceSnapshot = SpaceScanSnapshot.capture(tree: tree, excludedPaths: request.excludedPaths)
            } else {
                spaceSnapshot = nil
            }
            await self?.finishScan(report, category: scannedCategory, scanID: scanID,
                                   request: request, spaceSnapshot: spaceSnapshot)
        }
    }

    func startOverviewScan(categories: Set<ScanCategory>) {
        guard canStartOverviewScan else { return }
        let ordered = ScanCategory.allCases.filter { $0 != .overview && categories.contains($0) }
        guard !ordered.isEmpty else { return }
        let batchID = UUID()
        overviewScanID = batchID
        overviewScanCompletedCount = nil
        overviewScanWasCancelled = false
        overviewScanState = OverviewScanState(category: ordered[0], completed: 0,
                                              total: ordered.count, progress: nil)
        let excludedPaths = AppPreferences.shared.excludedPaths
        let ignoredHashes = AppPreferences.shared.ignoredDuplicateHashes
        let ignoredOrphans = AppPreferences.shared.ignoredOrphanIdentifiers
        let derivedDataRoots = AppPreferences.shared.derivedDataRoots
        let scanRoot = root
        let minimumBytes = Int64(minimumMB) * 1_024 * 1_024
        let oldestDays = olderThanDays
        overviewScanTask = Task { [weak self] in
            guard let self else { return }
            var completed = 0
            for selectedCategory in ordered {
                guard self.overviewScanID == batchID, !Task.isCancelled else { break }
                if selectedCategory == .developerCache { self.clearXcodeOverview() }
                self.overviewScanState = OverviewScanState(category: selectedCategory,
                    completed: completed, total: ordered.count, progress: nil)
                let scanID = UUID()
                let completedBeforeStep = completed
                let control = ScanControl { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard let self, self.overviewScanID == batchID,
                              self.overviewScanState?.category == selectedCategory else { return }
                        self.overviewScanState = OverviewScanState(category: selectedCategory,
                            completed: completedBeforeStep, total: ordered.count, progress: progress)
                    }
                }
                self.overviewScanControl = control
                self.runningScans[selectedCategory] = RunningScan(id: scanID, control: control,
                                                                  isApplicationPreparation: false)
                if selectedCategory == .space { self.latestSpaceScanID = scanID }
                let request = ScanRequest(category: selectedCategory,
                    root: selectedCategory == .downloads
                        ? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
                        : scanRoot,
                    minimumBytes: minimumBytes, olderThanDays: oldestDays,
                    excludedPaths: excludedPaths, ignoredDuplicateHashes: ignoredHashes,
                    ignoredOrphanIdentifiers: ignoredOrphans,
                    derivedDataRoots: derivedDataRoots)
                let (report, snapshot) = await Task.detached(priority: .userInitiated) {
                    let report = FileScanner.scan(request, control: control)
                    let snapshot = selectedCategory == .space && report.hasCompleteSpaceTotals
                        ? report.spaceTree.map { SpaceScanSnapshot.capture(tree: $0,
                            excludedPaths: request.excludedPaths) } : nil
                    return (report, snapshot)
                }.value
                guard self.overviewScanID == batchID, !Task.isCancelled, !report.cancelled else {
                    self.runningScans.removeValue(forKey: selectedCategory)
                    break
                }
                self.finishScan(report, category: selectedCategory, scanID: scanID,
                                request: request, spaceSnapshot: snapshot)
                completed += 1
            }
            guard self.overviewScanID == batchID else { return }
            self.overviewScanID = nil
            self.overviewScanControl = nil
            self.overviewScanTask = nil
            self.overviewScanState = nil
            self.overviewScanCompletedCount = completed
            self.rebuildCleanupOverview()
        }
    }

    func cancelOverviewScan() {
        guard let state = overviewScanState else { return }
        overviewScanID = nil
        overviewScanControl?.cancel()
        overviewScanControl = nil
        overviewScanTask?.cancel()
        overviewScanTask = nil
        runningScans.removeValue(forKey: state.category)
        overviewScanCompletedCount = state.completed
        overviewScanWasCancelled = true
        overviewScanState = nil
        rebuildCleanupOverview()
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
            let capacityURL = DeletionCapacityScope.commonScope(for: chosen)
            let before = capacityURL.flatMap(observedAvailableCapacity)
            let outcomes = FileDeletion.execute(chosen, mode: mode)
            let after = capacityURL.flatMap(observedAvailableCapacity)
            let delta = before.flatMap { initial in after.map { $0 - initial } }
            await self?.finishDelete(outcomes, selected: chosen, category: deletedCategory,
                                     mode: mode, availableSpaceDelta: delta)
        }
    }

    func evictCloud() {
        let chosen = selectedEntries
        guard category == .icloud, !chosen.isEmpty, !hasHiddenSelection,
              !isDeleting, !isScanning else { return }
        isDeleting = true
        Task.detached(priority: .userInitiated) { [weak self] in
            let before = observedAvailableCapacity(ICloudDrive.root)
            let outcomes = chosen.map { ICloudDrive.evict($0) }
            let after = observedAvailableCapacity(ICloudDrive.root)
            let delta = before.flatMap { initial in after.map { $0 - initial } }
            await self?.finishCloudEviction(outcomes, availableSpaceDelta: delta)
        }
    }

    private func finishCloudEviction(_ outcomes: [DeleteResult], availableSpaceDelta: Int64?) {
        results = outcomes
        lastAvailableSpaceDelta = availableSpaceDelta
        selectedIDs = []
        isDeleting = false
        showResults = true
        scan()
    }

    func deleteXcodeCaches(_ chosen: [ScanEntry]) async {
        guard category == .developerCache, !chosen.isEmpty, !isDeleting,
              chosen.allSatisfy({ $0.note == "verifiedSharedCache" && $0.category == .developerCache }) else { return }
        isDeleting = true
        let outcome = await Task.detached(priority: .userInitiated) {
            let capacityURL = DeletionCapacityScope.commonScope(for: chosen)
            let before = capacityURL.flatMap(observedAvailableCapacity)
            let results = FileDeletion.execute(chosen, mode: .trash)
            let after = capacityURL.flatMap(observedAvailableCapacity)
            return (results, before.flatMap { initial in after.map { $0 - initial } })
        }.value
        finishDelete(outcome.0, selected: chosen, category: .developerCache,
                     mode: .trash, availableSpaceDelta: outcome.1)
    }

    private func finishScan(_ report: ScanReport, category scannedCategory: ScanCategory,
                            scanID: UUID, request: ScanRequest, spaceSnapshot: SpaceScanSnapshot?) {
        guard runningScans[scannedCategory]?.id == scanID else { return }
        runningScans.removeValue(forKey: scannedCategory)
        if !report.cancelled {
            scanDiagnostics[scannedCategory] = ScanDiagnostic.make(
                warnings: report.warnings, omittedCount: report.omittedCount)
        }
        if let spaceSnapshot { recordSpaceSnapshot(spaceSnapshot, scanID: scanID) }
        if scannedCategory == .developerCache {
            if let snapshot = XcodeProjectSnapshot.capture(report: report, scanID: scanID,
                    capturedAt: Date(), roots: [XcodeStorage.defaultDerivedDataRoot] + request.derivedDataRoots,
                    excludedPaths: request.excludedPaths) {
                do {
                    var history = try XcodeProjectHistory.load(from: Self.projectHistoryURL)
                    let comparison = history.record(snapshot)
                    try history.save(to: Self.projectHistoryURL)
                    projectHistoryStatus = .comparison(comparison)
                } catch {
                    projectHistoryStatus = .storageError
                }
            } else {
                projectHistoryStatus = .incomplete
            }
        }
        if category == scannedCategory {
            entries = report.entries
            if scannedCategory == .icloud {
                cloudCurrentCount = report.entries.filter { $0.note == "icloudCurrent" }.count
                cloudRemoteCount = report.entries.filter { $0.note == "icloudRemote" }.count
                if cloudFolder != ICloudDrive.root &&
                    !report.entries.contains(where: { $0.url == cloudFolder && $0.isDirectory }) {
                    cloudFolder = ICloudDrive.root
                }
            }
            spaceTree = report.spaceTree
            spaceItems = report.spaceTree == nil ? report.spaceItems : []
            summaryCount = report.scannedFileCount
            summaryBytes = report.scannedBytes
            scanMetrics = ScanMetrics(allocatedBytes: report.scannedAllocatedBytes,
                                      omittedCount: report.omittedCount)
            warnings = report.warnings
            isScanning = false
            scanProgress = nil
            hasScanned = !report.cancelled
        } else {
            let previous = categoryResults[scannedCategory]
            categoryResults[scannedCategory] = CategoryResult(
                entries: report.entries,
                spaceItems: report.spaceTree == nil ? report.spaceItems : [],
                spaceTree: report.spaceTree,
                summaryCount: report.scannedFileCount, summaryBytes: report.scannedBytes,
                scanMetrics: ScanMetrics(allocatedBytes: report.scannedAllocatedBytes,
                                         omittedCount: report.omittedCount),
                warnings: report.warnings, selectedIDs: [], hasScanned: !report.cancelled,
                isScanning: false, scanProgress: nil,
                spaceFolder: previous?.spaceFolder, resultQuery: previous?.resultQuery ?? "",
                resultFilter: previous?.resultFilter ?? .all
            )
        }
        if scannedCategory == .uninstall && category == .uninstall && !report.cancelled {
            beginApplicationSizeMeasurement(report.entries.filter { !$0.sizeIsKnown })
        }
        if scannedCategory == .space { refreshVolumes() }
        if scannedCategory == .space && !report.cancelled {
            lastSpaceScanRootPath = request.root.standardizedFileURL.path
            lastSpaceScanIncomplete = !report.hasCompleteSpaceTotals
            if !report.hasCompleteSpaceTotals { latestSpaceSnapshot = nil }
        }
        if category == .overview { rebuildCleanupOverview() }
    }

    private func recordSpaceSnapshot(_ snapshot: SpaceScanSnapshot, scanID: UUID) {
        guard latestSpaceScanID == scanID else { return }
        latestSpaceSnapshot = snapshot
        do {
            var history = try SpaceScanHistory.load(from: Self.spaceHistoryURL)
            let comparison = history.record(snapshot)
            try history.save(to: Self.spaceHistoryURL)
            spaceGrowthComparison = comparison
            spaceHistoryError = nil
        } catch {
            spaceHistoryError = error.localizedDescription
        }
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
            lastReviewedApplicationName = reviewedApplicationName
            lastReviewedApplicationEntries = report.entries
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
        let directories = Set(selected.filter(\.isDirectory).map(\.url))
        let items = outcomes.map { result in
            CleanupHistoryItem(path: result.url.path, estimatedBytes: sizes[result.url] ?? 0,
                               success: result.success, message: result.message,
                               trashPath: result.trashURL?.path, scopePath: scopes[result.url],
                               trashStamp: directories.contains(result.url) && result.trashSignature == nil
                                   ? nil : result.trashURL.flatMap { FileSafety.stamp(at: $0) },
                               trashSignature: result.trashSignature)
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
            xcodeSupplemental = []
            xcodeSupplementalScanned = false
            xcodeSupplementalIncomplete = false
        }
        let removed = Set(outcomes.filter(\.success).map(\.url))
        if !removed.isEmpty {
            lastReviewedApplicationEntries?.removeAll { removed.contains($0.url) }
        }
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
        rebuildCleanupOverview()
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
            entries: entries, spaceItems: spaceItems, spaceTree: spaceTree,
            summaryCount: summaryCount,
            summaryBytes: summaryBytes, scanMetrics: scanMetrics,
            warnings: warnings, selectedIDs: selectedIDs,
            hasScanned: hasScanned, isScanning: isScanning, scanProgress: scanProgress,
            spaceFolder: spaceFolder, resultQuery: resultQuery, resultFilter: resultFilter
        )
    }

    private func restore(_ result: CategoryResult) {
        entries = result.entries
        if category == .icloud {
            cloudCurrentCount = result.entries.filter { $0.note == "icloudCurrent" }.count
            cloudRemoteCount = result.entries.filter { $0.note == "icloudRemote" }.count
        }
        spaceItems = result.spaceItems
        spaceTree = result.spaceTree
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
        case .overview: "square.grid.2x2"
        case .space: "chart.pie"
        case .large: "externaldrive"
        case .duplicates: "doc.on.doc"
        case .downloads: "arrow.down.circle"
        case .systemCache: "folder.badge.gearshape"
        case .developerCache: "hammer"
        case .uninstall: "app.badge"
        case .orphans: "questionmark.folder"
        case .icloud: "icloud"
        }
    }
}
