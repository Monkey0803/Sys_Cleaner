import AppKit
import Foundation

@MainActor
final class CleanerStore: ObservableObject {
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
    @Published var warnings: [String] = []
    @Published var selectedIDs: Set<UUID> = []
    @Published var isScanning = false
    @Published private(set) var scanProgress: ScanProgress?
    @Published var isDeleting = false
    @Published var hasScanned = false
    @Published var results: [DeleteResult] = []
    @Published var showResults = false
    @Published var showHistory = false
    @Published private(set) var cleanupHistory = (try? CleanupHistoryStorage.load(from: CleanerStore.historyURL)) ?? []
    @Published private(set) var historyError: String?
    @Published private(set) var restoreError: String?
    @Published var minimumMB = 100
    @Published var olderThanDays = 0
    @Published var appQuery = "" {
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
    private var categoryResults: [ScanCategory: CategoryResult] = [:]
    private var applicationOverview: CategoryResult?

    private struct CategoryResult {
        let entries: [ScanEntry]
        let spaceItems: [SpaceItem]
        let summaryCount: Int
        let summaryBytes: Int64
        let warnings: [String]
        let selectedIDs: Set<UUID>
        let hasScanned: Bool
        let isScanning: Bool
        let scanProgress: ScanProgress?
        let spaceFolder: URL?
        let appQuery: String

        func removing(_ urls: Set<URL>) -> CategoryResult {
            let remaining = entries.filter { !urls.contains($0.url) }
            return CategoryResult(
                entries: remaining, spaceItems: spaceItems, summaryCount: remaining.count,
                summaryBytes: remaining.reduce(0) { $0 + $1.estimatedBytes },
                warnings: warnings, selectedIDs: selectedIDs.subtracting(
                    entries.filter { urls.contains($0.url) }.map(\.id)),
                hasScanned: hasScanned, isScanning: isScanning, scanProgress: scanProgress,
                spaceFolder: spaceFolder, appQuery: appQuery
            )
        }

        func updatingProgress(_ progress: ScanProgress) -> CategoryResult {
            CategoryResult(entries: entries, spaceItems: spaceItems, summaryCount: summaryCount,
                           summaryBytes: summaryBytes, warnings: warnings, selectedIDs: selectedIDs,
                           hasScanned: hasScanned, isScanning: isScanning, scanProgress: progress,
                           spaceFolder: spaceFolder, appQuery: appQuery)
        }
    }

    var selectedEntries: [ScanEntry] { entries.filter { selectedIDs.contains($0.id) && $0.canDelete } }
    var estimatedSelectedBytes: Int64 { selectedEntries.reduce(0) { $0 + $1.estimatedBytes } }
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
        let filtered: [ScanEntry]
        if category == .uninstall && !appQuery.isEmpty {
            let matchingIdentifiers = Set(entries.compactMap { entry -> String? in
                guard entry.isDirectory,
                      entry.url.pathExtension.lowercased() == "app",
                      entry.url.lastPathComponent.localizedCaseInsensitiveContains(appQuery),
                      entry.note != "appRunning" else { return nil }
                return entry.note
            })
            filtered = entries.filter {
                $0.url.lastPathComponent.localizedCaseInsensitiveContains(appQuery) ||
                $0.note.localizedCaseInsensitiveContains(appQuery) ||
                matchingIdentifiers.contains($0.note)
            }
        } else {
            filtered = entries
        }
        visibleEntries = ScanSorting.entries(filtered, category: category, selection: sortSelection)
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

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = L("choose")
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
        if runningScans[category]?.isApplicationPreparation == true { cancel() }
        if category == .uninstall { backFromApplication() }
        if hasScanned || isScanning {
            categoryResults[category] = currentResult()
        } else {
            categoryResults.removeValue(forKey: category)
        }
        category = newValue
        sortSelection = AppPreferences.shared.sortSelection(for: newValue)
        if let saved = categoryResults.removeValue(forKey: newValue) {
            restore(saved)
        } else {
            appQuery = ""
            entries = []
            spaceItems = []
            summaryCount = 0
            summaryBytes = 0
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
        categoryResults.removeValue(forKey: category)
        applicationOverview = nil
        reviewedApplicationName = nil
        entries = []
        spaceItems = []
        summaryCount = 0
        summaryBytes = 0
        warnings = []
        selectedIDs = []
        hasScanned = false
        scanProgress = nil
    }

    func scan() {
        cancel()
        categoryResults.removeValue(forKey: category)
        applicationOverview = nil
        reviewedApplicationName = nil
        entries = []
        spaceItems = []
        summaryCount = 0
        summaryBytes = 0
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
                                  olderThanDays: olderThanDays)
        Task.detached(priority: .userInitiated) { [weak self] in
            let report = FileScanner.scan(request, control: newControl)
            await self?.finishScan(report, category: scannedCategory, scanID: scanID)
        }
    }

    func prepareApplication(_ app: ScanEntry) {
        guard category == .uninstall, app.isDirectory, app.directorySignature == nil,
              app.risk != .protected, !isScanning else { return }
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
        Task.detached(priority: .userInitiated) { [weak self] in
            let report = FileScanner.prepareApplication(app, control: newControl)
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
        guard !NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == identifier }) else {
            warnings = ["appRunning"]
            return
        }
        prepareApplication(ScanEntry(url: app, scope: scope, category: .uninstall,
                                     stamp: stamp, estimatedBytes: 0, note: identifier,
                                     isDirectory: true, canDelete: false))
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
    }

    func delete(_ mode: DeleteMode) {
        let chosen = selectedEntries
        guard !chosen.isEmpty, !isDeleting else { return }
        isDeleting = true
        let deletedCategory = category
        Task.detached(priority: .userInitiated) { [weak self] in
            let outcomes = FileDeletion.execute(chosen, mode: mode)
            await self?.finishDelete(outcomes, selected: chosen, category: deletedCategory, mode: mode)
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
            warnings = report.warnings
            isScanning = false
            scanProgress = nil
            hasScanned = !report.cancelled
        } else if let previous = categoryResults[scannedCategory] {
            categoryResults[scannedCategory] = CategoryResult(
                entries: report.entries, spaceItems: report.spaceItems,
                summaryCount: report.scannedFileCount, summaryBytes: report.scannedBytes,
                warnings: report.warnings, selectedIDs: [], hasScanned: !report.cancelled,
                isScanning: false, scanProgress: nil,
                spaceFolder: previous.spaceFolder, appQuery: previous.appQuery
            )
        }
    }

    private func finishApplicationPreparation(_ report: ScanReport, app: ScanEntry, scanID: UUID) {
        guard runningScans[.uninstall]?.id == scanID else { return }
        runningScans.removeValue(forKey: .uninstall)
        if !report.cancelled && !report.entries.isEmpty {
            applicationOverview = currentResult()
            reviewedApplicationName = app.url.lastPathComponent
            entries = report.entries
            summaryCount = report.entries.count
            summaryBytes = report.entries.reduce(0) { $0 + $1.estimatedBytes }
            selectedIDs = []
            appQuery = ""
            warnings = report.warnings
        } else {
            warnings.append(contentsOf: report.warnings)
        }
        isScanning = false
        scanProgress = nil
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
                              category deletedCategory: ScanCategory, mode: DeleteMode) {
        results = outcomes
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
            summaryBytes: summaryBytes, warnings: warnings, selectedIDs: selectedIDs,
            hasScanned: hasScanned, isScanning: isScanning, scanProgress: scanProgress,
            spaceFolder: spaceFolder, appQuery: appQuery
        )
    }

    private func restore(_ result: CategoryResult) {
        entries = result.entries
        spaceItems = result.spaceItems
        summaryCount = result.summaryCount
        summaryBytes = result.summaryBytes
        warnings = result.warnings
        selectedIDs = result.selectedIDs
        hasScanned = result.hasScanned
        isScanning = result.isScanning
        scanProgress = result.scanProgress
        spaceFolder = result.spaceFolder
        appQuery = result.appQuery
    }

    func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }

    func openFullDiskAccess() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
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
