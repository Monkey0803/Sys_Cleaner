import AppKit
import Foundation

@MainActor
final class CleanerStore: ObservableObject {
    @Published var category: ScanCategory = .space
    @Published var root = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().standardizedFileURL
    @Published var entries: [ScanEntry] = []
    @Published var spaceItems: [SpaceItem] = []
    @Published var summaryCount = 0
    @Published var summaryBytes: Int64 = 0
    @Published var warnings: [String] = []
    @Published var selectedIDs: Set<UUID> = []
    @Published var isScanning = false
    @Published var isDeleting = false
    @Published var hasScanned = false
    @Published var results: [DeleteResult] = []
    @Published var showResults = false
    @Published var minimumMB = 100
    @Published var olderThanDays = 0
    @Published var appQuery = ""
    @Published var spaceFolder: URL?
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
        let spaceFolder: URL?
        let appQuery: String

        func removing(_ urls: Set<URL>) -> CategoryResult {
            let remaining = entries.filter { !urls.contains($0.url) }
            return CategoryResult(
                entries: remaining, spaceItems: spaceItems, summaryCount: remaining.count,
                summaryBytes: remaining.reduce(0) { $0 + $1.estimatedBytes },
                warnings: warnings, selectedIDs: selectedIDs.subtracting(
                    entries.filter { urls.contains($0.url) }.map(\.id)),
                hasScanned: hasScanned, isScanning: isScanning,
                spaceFolder: spaceFolder, appQuery: appQuery
            )
        }
    }

    var selectedEntries: [ScanEntry] { entries.filter { selectedIDs.contains($0.id) && $0.canDelete } }
    var estimatedSelectedBytes: Int64 { selectedEntries.reduce(0) { $0 + $1.estimatedBytes } }
    var visibleEntries: [ScanEntry] {
        guard category == .uninstall, !appQuery.isEmpty else { return entries }
        let matchingIdentifiers = Set(entries.compactMap { entry -> String? in
            guard entry.isDirectory,
                  entry.url.pathExtension.lowercased() == "app",
                  entry.url.lastPathComponent.localizedCaseInsensitiveContains(appQuery),
                  entry.note != "appRunning" else { return nil }
            return entry.note
        })
        return entries.filter {
            $0.url.lastPathComponent.localizedCaseInsensitiveContains(appQuery) ||
            $0.note.localizedCaseInsensitiveContains(appQuery) ||
            matchingIdentifiers.contains($0.note)
        }
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
        spaceFolder = root
        isScanning = true
        let scannedCategory = category
        let scanID = UUID()
        let newControl = ScanControl()
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
        let scanID = UUID()
        let newControl = ScanControl()
        runningScans[.uninstall] = RunningScan(id: scanID, control: newControl,
                                               isApplicationPreparation: true)
        Task.detached(priority: .userInitiated) { [weak self] in
            let report = FileScanner.prepareApplication(app, control: newControl)
            await self?.finishApplicationPreparation(report, app: app, scanID: scanID)
        }
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
        Task.detached(priority: .userInitiated) { [weak self] in
            let outcomes = FileDeletion.execute(chosen, mode: mode)
            await self?.finishDelete(outcomes, selected: chosen)
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
            hasScanned = !report.cancelled
        } else if let previous = categoryResults[scannedCategory] {
            categoryResults[scannedCategory] = CategoryResult(
                entries: report.entries, spaceItems: report.spaceItems,
                summaryCount: report.scannedFileCount, summaryBytes: report.scannedBytes,
                warnings: report.warnings, selectedIDs: [], hasScanned: !report.cancelled,
                isScanning: false, spaceFolder: previous.spaceFolder, appQuery: previous.appQuery
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
    }

    private func finishDelete(_ outcomes: [DeleteResult], selected: [ScanEntry]) {
        results = outcomes
        showResults = true
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

    private func currentResult() -> CategoryResult {
        CategoryResult(
            entries: entries, spaceItems: spaceItems, summaryCount: summaryCount,
            summaryBytes: summaryBytes, warnings: warnings, selectedIDs: selectedIDs,
            hasScanned: hasScanned, isScanning: isScanning,
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
        }
    }
}
