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

    private var control: ScanControl?
    private var generation = 0

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
            cancel()
            root = url.resolvingSymlinksInPath().standardizedFileURL
            entries = []
            spaceItems = []
            summaryCount = 0
            summaryBytes = 0
            warnings = []
            selectedIDs = []
            hasScanned = false
            spaceFolder = root
        }
    }

    func changeCategory(_ newValue: ScanCategory) {
        guard category != newValue else { return }
        cancel()
        category = newValue
        appQuery = ""
        entries = []
        spaceItems = []
        summaryCount = 0
        summaryBytes = 0
        warnings = []
        selectedIDs = []
        hasScanned = false
        spaceFolder = root
    }

    func invalidateScan() {
        cancel()
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
        entries = []
        spaceItems = []
        summaryCount = 0
        summaryBytes = 0
        warnings = []
        selectedIDs = []
        hasScanned = false
        spaceFolder = root
        isScanning = true
        generation += 1
        let currentGeneration = generation
        let newControl = ScanControl()
        control = newControl
        let request = ScanRequest(category: category, root: root, minimumBytes: Int64(minimumMB) * 1_024 * 1_024,
                                  olderThanDays: olderThanDays)
        Task.detached(priority: .userInitiated) { [weak self] in
            let report = FileScanner.scan(request, control: newControl)
            await self?.finishScan(report, generation: currentGeneration)
        }
    }

    func prepareApplication(_ app: ScanEntry) {
        guard category == .uninstall, app.isDirectory, app.directorySignature == nil,
              app.risk != .protected, !isScanning else { return }
        isScanning = true
        generation += 1
        let currentGeneration = generation
        let newControl = ScanControl()
        control = newControl
        Task.detached(priority: .userInitiated) { [weak self] in
            let report = FileScanner.prepareApplication(app, control: newControl)
            await self?.finishApplicationPreparation(report, appID: app.id, generation: currentGeneration)
        }
    }

    func cancel() {
        control?.cancel()
        control = nil
        if isScanning {
            generation += 1
            isScanning = false
            warnings = ["scanCancelled"]
        }
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

    private func finishScan(_ report: ScanReport, generation currentGeneration: Int) {
        guard generation == currentGeneration else { return }
        entries = report.entries
        spaceItems = report.spaceItems
        summaryCount = report.scannedFileCount
        summaryBytes = report.scannedBytes
        warnings = report.warnings
        isScanning = false
        hasScanned = !report.cancelled
        control = nil
    }

    private func finishApplicationPreparation(_ report: ScanReport, appID: UUID, generation currentGeneration: Int) {
        guard generation == currentGeneration else { return }
        if !report.cancelled && !report.entries.isEmpty {
            entries.removeAll { $0.id == appID }
            entries.append(contentsOf: report.entries)
            entries.sort { $0.estimatedBytes > $1.estimatedBytes }
            summaryCount = entries.count
            summaryBytes = entries.reduce(0) { $0 + $1.estimatedBytes }
        }
        warnings.append(contentsOf: report.warnings)
        isScanning = false
        control = nil
    }

    private func finishDelete(_ outcomes: [DeleteResult], selected: [ScanEntry]) {
        results = outcomes
        showResults = true
        let removed = Set(outcomes.filter(\.success).map(\.url))
        entries.removeAll { removed.contains($0.url) }
        summaryCount = entries.count
        summaryBytes = entries.reduce(0) { $0 + $1.estimatedBytes }
        selectedIDs.subtract(selected.map(\.id))
        isDeleting = false
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
