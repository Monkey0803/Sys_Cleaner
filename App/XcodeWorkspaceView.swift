import AppKit
import SwiftUI

struct XcodeWorkspaceView: View {
    @EnvironmentObject private var store: CleanerStore
    @EnvironmentObject private var preferences: AppPreferences
    @State private var section: Section = .overview
    @State private var archives: [XcodeArchive] = []
    @State private var simulators: [XcodeSimulator] = []
    @State private var runtimes: [XcodeSimulatorRuntime] = []
    @State private var deviceSupport: [XcodeDeviceSupport] = []
    @State private var sharedCaches: [XcodeReadOnlyItem] = []
    @State private var additionalData: [XcodeReadOnlyItem] = []
    @State private var archiveWarnings: [String] = []
    @State private var deviceSupportWarnings: [String] = []
    @State private var sharedCacheWarnings: [String] = []
    @State private var additionalDataWarnings: [String] = []
    @State private var runtimeError: String?
    @State private var simulatorInventoryError: String?
    @State private var archiveScan: InventoryScan = .notScanned
    @State private var simulatorScan: InventoryScan = .notScanned
    @State private var runtimeScan: InventoryScan = .notScanned
    @State private var deviceSupportScan: InventoryScan = .notScanned
    @State private var sharedCacheScan: InventoryScan = .notScanned
    @State private var additionalDataScan: InventoryScan = .notScanned
    @State private var sharedCacheProgress: ScanProgress?
    @State private var additionalDataProgress: ScanProgress?
    @State private var sharedCacheControl: ScanControl?
    @State private var additionalDataControl: ScanControl?
    @State private var extraRefreshID = UUID()
    @State private var selectedSimulatorIDs = Set<String>()
    @State private var selectedCachePaths = Set<String>()
    @State private var showingTrashConfirmation = false
    @State private var showingSimulatorConfirmation = false
    @State private var showingCacheTrashConfirmation = false
    @State private var operationError: String?
    @State private var comparisonBefore: XcodeReviewSnapshot?
    @State private var comparisonAfter: XcodeReviewSnapshot?
    @State private var comparisonRefreshPending = false
    @State private var comparisonExtrasDone = false
    @State private var projectQuery = ""
    @State private var projectFilter: ProjectFilter = .all
    @State private var projectSort: ProjectSort = .size

    private enum Section: String, CaseIterable, Identifiable {
        case overview, review, projects, archives, simulators
        var id: Self { self }
    }

    private enum InventoryScan {
        case notScanned, scanning
        case complete(TimeInterval), partial(TimeInterval), unavailable(TimeInterval), cancelled(TimeInterval)

        var isScanning: Bool {
            if case .scanning = self { return true }
            return false
        }
    }

    private enum ExtraInventoryResult: Sendable {
        case archives(XcodeStorageInventory<XcodeArchive>, TimeInterval)
        case simulators([XcodeSimulator], String?, TimeInterval)
        case runtimes([XcodeSimulatorRuntime], String?, TimeInterval)
        case deviceSupport(XcodeStorageInventory<XcodeDeviceSupport>, TimeInterval)
        case sharedCaches(XcodeReadOnlyReport, TimeInterval)
        case additionalData(XcodeReadOnlyReport, TimeInterval)
    }

    private enum ProjectFilter: String {
        case all, identified, unknown
    }

    private enum ProjectSort: String {
        case size, recent, name
    }

    private var visibleProjects: [XcodeProjectGroup] {
        let query = projectQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = XcodeStorage.projectGroups(store.entries).filter { group in
            let matchesFilter: Bool
            switch projectFilter {
            case .all: matchesFilter = true
            case .identified: matchesFilter = group.projectPath != nil
            case .unknown: matchesFilter = group.projectPath == nil
            }
            return matchesFilter && (query.isEmpty
                || projectName(group).localizedStandardContains(query)
                || (group.projectPath?.localizedStandardContains(query) ?? false)
                || group.entries.contains { $0.url.path.localizedStandardContains(query) })
        }
        switch projectSort {
        case .recent:
            return filtered.sorted { $0.lastActivity == $1.lastActivity
                ? $0.id < $1.id : $0.lastActivity > $1.lastActivity }
        case .size:
            return filtered.sorted { left, right in
                if left.logicalBytes != right.logicalBytes {
                    return left.logicalBytes > right.logicalBytes
                }
                return left.id < right.id
            }
        case .name:
            return filtered.sorted { left, right in
                let leftName = projectName(left)
                let rightName = projectName(right)
                let comparison = leftName.localizedStandardCompare(rightName)
                if comparison != .orderedSame { return comparison == .orderedAscending }
                return left.id < right.id
            }
        }
    }

    private func projectName(_ group: XcodeProjectGroup) -> String {
        group.projectPath.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }
            ?? L("xcodeUnknownProject")
    }

    private func projectName(_ entry: ScanEntry) -> String {
        entry.note.isEmpty ? L("xcodeUnknownProject")
            : URL(fileURLWithPath: entry.note).deletingPathExtension().lastPathComponent
    }

    private func pruneHiddenProjectSelection() {
        store.selectedIDs.formIntersection(Set(visibleProjects.flatMap(\.entries).map(\.id)))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("xcodeTitle").font(.largeTitle.bold())
                    Text("xcodeDescription").foregroundStyle(.secondary)
                }
                Spacer()
                Button("scanAgain") { refresh() }
                    .hoverHighlight()
                    .disabled(store.isDeleting)
            }
            .padding(20)
            Picker("xcodeSection", selection: $section) {
                Text("xcodeOverview").tag(Section.overview)
                Text("xcodeReview").tag(Section.review)
                Text("xcodeProjects").tag(Section.projects)
                Text("xcodeArchives").tag(Section.archives)
                Text("xcodeSimulators").tag(Section.simulators)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
            Divider()
            switch section {
            case .overview: overviewView
            case .review: reviewView
            case .projects: projectsView
            case .archives: archivesView
            case .simulators: simulatorsView
            }
            if let operationError {
                Text(operationError).foregroundStyle(.orange)
                    .font(.caption).padding(12)
            }
        }
        .task {
            if !store.hasScanned && !store.isScanning && !store.warnings.contains("scanCancelled") {
                store.scan()
            }
            await refreshExtras()
        }
        .onDisappear {
            sharedCacheControl?.cancel()
            additionalDataControl?.cancel()
            clearComparison()
        }
        .onChange(of: store.showResults) { _, showing in
            guard showing, comparisonBefore != nil, !comparisonRefreshPending else { return }
            comparisonRefreshPending = true
            comparisonExtrasDone = false
            store.scan()
            Task {
                await refreshExtras()
                comparisonExtrasDone = true
                finishComparisonIfReady()
            }
        }
        .onChange(of: store.isScanning) { _, _ in finishComparisonIfReady() }
        .alert("xcodeTrashConfirm", isPresented: $showingTrashConfirmation) {
            Button("moveToTrash", role: .destructive) {
                beginComparison()
                store.delete(.trash)
            }
            Button("cancel", role: .cancel) {}
        } message: {
            Text(String(format: L("confirmCount"), store.selectedEntries.count,
                        ByteCountFormatter.string(fromByteCount: store.estimatedSelectedBytes, countStyle: .file)))
        }
        .alert("xcodeSimulatorConfirm", isPresented: $showingSimulatorConfirmation) {
            Button("xcodeDeleteDevices", role: .destructive) { deleteSelectedSimulators() }
            Button("cancel", role: .cancel) {}
        } message: {
            let names = simulators.filter { selectedSimulatorIDs.contains($0.id) }.map(\.name).joined(separator: "、")
            Text(String(format: L("xcodeSimulatorIrreversible"), selectedSimulatorIDs.count, names))
        }
        .alert("xcodeCacheTrashConfirm", isPresented: $showingCacheTrashConfirmation) {
            Button("moveToTrash", role: .destructive) { deleteSelectedCaches() }
            Button("cancel", role: .cancel) {}
        } message: {
            let names = sharedCaches.filter { selectedCachePaths.contains($0.url.path) }.map(\.name).joined(separator: "、")
            Text(String(format: L("xcodeCacheTrashMessage"), selectedCachePaths.count, names))
        }
    }

    private var overviewView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("xcodeOverviewExplain")
                    .font(.caption).foregroundStyle(.secondary)
                if store.isScanning { ProgressView("scanning") }
                overviewRow("xcodeProjects", count: store.entries.count,
                            bytes: store.entries.reduce(0) { $0 + $1.estimatedBytes },
                            status: projectScanStatus, isScanning: store.isScanning,
                            sources: [String(format: L("xcodeStandardPath"),
                                             XcodeStorage.defaultDerivedDataRoot.resolvingSymlinksInPath().path)]
                                + preferences.derivedDataRoots.map { String(format: L("xcodeAddedPath"), $0.path) })
                overviewRow("xcodeArchives", count: archives.count,
                            bytes: archives.reduce(0) { $0 + $1.logicalBytes },
                            status: scanStatus(archiveScan), isScanning: archiveScan.isScanning,
                            sources: [String(format: L("xcodeStandardPath"),
                                             XcodeStorage.defaultArchivesRoot.resolvingSymlinksInPath().path)])
                overviewRow("xcodeSimulators", count: simulators.count,
                            bytes: simulators.allSatisfy { $0.dataBytes != nil }
                                ? simulators.reduce(0) { $0 + ($1.dataBytes ?? 0) } : nil,
                            status: scanStatus(simulatorScan), isScanning: simulatorScan.isScanning,
                            sources: [L("xcodeSimulatorSource")])
                overviewRow("xcodeRuntimes", count: runtimes.count,
                            bytes: runtimes.allSatisfy { $0.logicalBytes != nil }
                                ? runtimes.reduce(0) { $0 + ($1.logicalBytes ?? 0) } : nil,
                            status: scanStatus(runtimeScan), isScanning: runtimeScan.isScanning,
                            sources: [L("xcodeRuntimeSource")])
                overviewRow("xcodeDeviceSupport", count: deviceSupport.count,
                            bytes: deviceSupport.reduce(0) { $0 + $1.logicalBytes },
                            status: scanStatus(deviceSupportScan), isScanning: deviceSupportScan.isScanning,
                            sources: [String(format: L("xcodeStandardPath"),
                                             XcodeStorage.defaultDeviceSupportRoot.resolvingSymlinksInPath().path)])
                overviewRow("xcodeSharedCaches", count: sharedCaches.count,
                            bytes: sharedCaches.reduce(0) { $0 + $1.logicalBytes },
                            status: scanStatus(sharedCacheScan), isScanning: sharedCacheScan.isScanning,
                            sources: [L("xcodeSharedCachesSource")])
                overviewRow("xcodeAdditionalData", count: additionalData.count,
                            bytes: additionalData.reduce(0) { $0 + $1.logicalBytes },
                            status: scanStatus(additionalDataScan), isScanning: additionalDataScan.isScanning,
                            sources: [L("xcodeAdditionalDataSource")])
                Button("cancel") { cancelReadOnlyScans() }
                    .hoverHighlight()
                    .disabled(!sharedCacheScan.isScanning && !additionalDataScan.isScanning)
                if sharedCacheScan.isScanning || additionalDataScan.isScanning {
                    readOnlyProgress(sharedCacheProgress, title: L("xcodeSharedCaches"))
                    readOnlyProgress(additionalDataProgress, title: L("xcodeAdditionalData"))
                }
                ForEach(sharedCacheWarnings + additionalDataWarnings, id: \.self) { warning in
                    Text(localizedWarning(warning)).font(.caption).foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
                if !sharedCaches.isEmpty || !additionalData.isEmpty {
                    DisclosureGroup("xcodeReadOnlyCandidates") {
                        ForEach(sharedCaches + additionalData) { item in readOnlyCandidateRow(item) }
                    }
                }
                Text("xcodeCoverageScope").font(.caption).foregroundStyle(.secondary)

                if !runtimes.isEmpty {
                    Text("xcodeRuntimes").font(.headline)
                    Text("xcodeRuntimesReadOnly").font(.caption).foregroundStyle(.secondary)
                    Button("xcodeOpenXcode") { openXcode() }
                        .hoverHighlight()
                    ForEach(runtimes) { runtime in
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("\(runtime.name) \(runtime.version) (\(runtime.build))")
                                Text(runtime.state).font(.caption).foregroundStyle(.secondary)
                                if let lastUsed = runtime.lastUsed {
                                    Text(String(format: L("xcodeLastUsed"), lastUsed.formatted()))
                                        .font(.caption2).foregroundStyle(.secondary)
                                } else {
                                    Text("xcodeLastUsedUnknown")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                                runtimeRelationship(runtime)
                                if let path = runtimePath(runtime) {
                                    Text(path.path).font(.caption2).foregroundStyle(.tertiary)
                                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                                }
                            }
                            Spacer()
                            Text(runtime.logicalBytes.map { bytes in
                                String(format: L("xcodeEstimatedSize"),
                                       ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                            } ?? L("notMeasured"))
                                .font(.caption).foregroundStyle(.secondary)
                            finderButton(runtimePath(runtime))
                        }
                        .padding(10)
                        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                if !deviceSupport.isEmpty {
                    Text("xcodeDeviceSupport").font(.headline)
                    Text("xcodeDeviceSupportReadOnly").font(.caption).foregroundStyle(.secondary)
                    ForEach(deviceSupport) { item in
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.name)
                                Text(item.url.path).font(.caption).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                            }
                            Spacer()
                            Text(ByteCountFormatter.string(fromByteCount: item.logicalBytes, countStyle: .file))
                            Button { store.reveal(item.url) } label: { Image(systemName: "folder") }
                                .help(L("showInFinder"))
                                .hoverHighlight()
                        }
                        .padding(10)
                        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                ForEach(archiveWarnings + deviceSupportWarnings, id: \.self) { warning in
                    Text(localizedWarning(warning)).font(.caption).foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
                if let runtimeError {
                    Text(runtimeError).font(.caption).foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
                if let simulatorInventoryError {
                    Text(simulatorInventoryError).font(.caption).foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
    }

    private var reviewProjectEntries: [ScanEntry] {
        store.entries.filter(\.canDelete)
    }

    private var reviewProjects: [XcodeProjectGroup] {
        XcodeStorage.projectGroups(reviewProjectEntries).sorted {
            $0.logicalBytes == $1.logicalBytes
                ? $0.id < $1.id : $0.logicalBytes > $1.logicalBytes
        }
    }

    private var reviewShutdownDevices: [XcodeSimulator] {
        simulators.filter(\.canDelete)
    }

    private var reviewView: some View {
        VStack(spacing: 0) {
            Text("xcodeReviewExplain")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20).padding(.vertical, 12)
            if let before = comparisonBefore, let after = comparisonAfter {
                VStack(alignment: .leading, spacing: 4) {
                    Text("xcodeReviewComparisonTitle").font(.headline)
                    ForEach(XcodeReviewCategory.allCases, id: \.self) { category in
                        if let pair = before.comparison(to: after, category: category) {
                            Text(String(format: L("xcodeReviewComparisonRow"),
                                        L(comparisonCategoryKey(category)),
                                        pair.before.count, pair.after.count,
                                        comparisonSize(pair.before.estimatedBytes),
                                        comparisonSize(pair.after.estimatedBytes)))
                                .font(.caption).monospacedDigit()
                        } else {
                            Text(String(format: L("xcodeReviewComparisonIncomplete"),
                                        L(comparisonCategoryKey(category))))
                                .font(.caption).foregroundStyle(.orange)
                        }
                    }
                    Text("xcodeReviewComparisonHelp")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
            }
            if !sharedCaches.isEmpty {
                HStack {
                    Spacer()
                    Button("xcodeCacheTrashAction") { showingCacheTrashConfirmation = true }
                        .hoverHighlight()
                        .disabled(selectedCachePaths.isEmpty || sharedCacheScan.isScanning || store.isDeleting)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
            }
            List {
                if !sharedCaches.isEmpty {
                    SwiftUI.Section {
                        ForEach(sharedCaches) { item in readOnlyCandidateRow(item, selectable: true) }
                        Text("xcodeCacheTrashHelp").font(.caption).foregroundStyle(.secondary)
                    } header: {
                        Text("xcodeSharedCaches")
                    }
                }

                SwiftUI.Section {
                    if store.isScanning { ProgressView("scanning") }
                    if store.hasPartialResults {
                        Text("xcodeReviewPartialProjects")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    if !store.hasScanned && !store.isScanning && !store.hasPartialResults {
                        Text("xcodeNotScanned").foregroundStyle(.secondary)
                    } else if reviewProjectEntries.isEmpty && !store.isScanning {
                        Text("xcodeNoProjects").foregroundStyle(.secondary)
                    }
                    ForEach(reviewProjects) { group in
                        DisclosureGroup {
                            ForEach(group.entries) { entry in projectRow(entry) }
                        } label: {
                            projectGroupRow(group, showRebuildHelp: true)
                        }
                    }
                    Text(String(format: L("selectedSummary"), store.selectedEntries.count,
                                ByteCountFormatter.string(fromByteCount: store.estimatedSelectedBytes,
                                                          countStyle: .file)))
                        .font(.caption).foregroundStyle(.secondary)
                    Button("moveToTrash") { showingTrashConfirmation = true }
                        .hoverHighlight()
                        .disabled(store.selectedEntries.isEmpty || store.isScanning || store.isDeleting)
                } header: {
                    Text("xcodeReviewTrash")
                    Text(String(format: L("xcodeReviewTrashSummary"), reviewProjects.count,
                                reviewProjectEntries.count,
                                ByteCountFormatter.string(
                                    fromByteCount: reviewProjectEntries.reduce(0) { $0 + $1.estimatedBytes },
                                    countStyle: .file)))
                } footer: {
                    Text("xcodeReviewTrashHelp")
                }

                SwiftUI.Section {
                    if simulatorScan.isScanning { ProgressView("scanning") }
                    if simulatorInventoryError != nil {
                        Text("xcodeReviewUnavailableDevices")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    if simulators.isEmpty && !simulatorScan.isScanning && simulatorInventoryError == nil {
                        Text("xcodeNoSimulators").foregroundStyle(.secondary)
                    }
                    ForEach(simulators) { device in simulatorRow(device) }
                    Button("xcodeDeleteDevices", role: .destructive) {
                        showingSimulatorConfirmation = true
                    }
                    .hoverHighlight()
                    .disabled(selectedSimulatorIDs.isEmpty || simulatorScan.isScanning || store.isDeleting)
                } header: {
                    Text("xcodeReviewDevices")
                    Text(String(format: L("xcodeReviewDeviceSummary"), reviewShutdownDevices.count,
                                reviewShutdownDevices.allSatisfy { $0.dataBytes != nil }
                                    ? ByteCountFormatter.string(
                                        fromByteCount: reviewShutdownDevices.reduce(0) { $0 + ($1.dataBytes ?? 0) },
                                        countStyle: .file) : L("notMeasured")))
                } footer: {
                    Text("xcodeReviewDevicesHelp")
                }

                SwiftUI.Section {
                    if archiveScan.isScanning || runtimeScan.isScanning || deviceSupportScan.isScanning ||
                        sharedCacheScan.isScanning || additionalDataScan.isScanning {
                        ProgressView("scanning")
                    }
                    ForEach(archiveWarnings + deviceSupportWarnings + sharedCacheWarnings + additionalDataWarnings,
                            id: \.self) { warning in
                        Text(localizedWarning(warning))
                            .font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                    }
                    if let runtimeError {
                        Text(runtimeError).font(.caption).foregroundStyle(.orange)
                            .textSelection(.enabled)
                    }
                    ForEach(archives.sorted { $0.logicalBytes > $1.logicalBytes }) { archive in
                        reviewReadOnlyRow(name: archive.name, path: archive.url,
                                          bytes: archive.logicalBytes, kind: L("xcodeArchives"))
                    }
                    ForEach(runtimes) { runtime in
                        reviewReadOnlyRow(name: "\(runtime.name) \(runtime.version) (\(runtime.build))",
                                          path: runtimePath(runtime), bytes: runtime.logicalBytes,
                                          kind: L("xcodeRuntimes"))
                    }
                    ForEach(deviceSupport.sorted { $0.logicalBytes > $1.logicalBytes }) { item in
                        reviewReadOnlyRow(name: item.name, path: item.url,
                                          bytes: item.logicalBytes, kind: L("xcodeDeviceSupport"))
                    }
                    ForEach(additionalData) { item in readOnlyCandidateRow(item, selectable: false) }
                    if archives.isEmpty && runtimes.isEmpty && deviceSupport.isEmpty &&
                        sharedCaches.isEmpty && additionalData.isEmpty &&
                        archiveWarnings.isEmpty && deviceSupportWarnings.isEmpty &&
                        sharedCacheWarnings.isEmpty && additionalDataWarnings.isEmpty && runtimeError == nil &&
                        !archiveScan.isScanning && !runtimeScan.isScanning && !deviceSupportScan.isScanning &&
                        !sharedCacheScan.isScanning && !additionalDataScan.isScanning {
                        Text("xcodeReviewNoReadOnly").foregroundStyle(.secondary)
                    }
                } header: {
                    Text("xcodeReviewReadOnly")
                } footer: {
                    Text("xcodeReviewReadOnlyHelp")
                }
            }
            .listStyle(.inset)
        }
    }

    private func reviewReadOnlyRow(name: String, path: URL?, bytes: Int64?, kind: String) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(name).font(.headline)
                Text(kind).font(.caption).foregroundStyle(.secondary)
                Text(path?.path ?? L("xcodeFinderPathUnavailable"))
                    .font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            }
            Spacer(minLength: 8)
            Text(bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
                 ?? L("notMeasured"))
                .font(.caption).foregroundStyle(.secondary)
            finderButton(path)
        }
        .padding(.vertical, 5)
    }

    private func readOnlyCandidateRow(_ item: XcodeReadOnlyItem, selectable: Bool = false) -> some View {
        HStack(spacing: 12) {
            if selectable, let _ = XcodeStorage.cacheDeletionEntry(for: item, derivedDataRoots:
                [XcodeStorage.defaultDerivedDataRoot] + preferences.derivedDataRoots) {
                Toggle(item.name, isOn: Binding(
                    get: { selectedCachePaths.contains(item.url.path) },
                    set: { selected in
                        if selected { selectedCachePaths.insert(item.url.path) }
                        else { selectedCachePaths.remove(item.url.path) }
                    }
                ))
                .labelsHidden()
                .disabled(sharedCacheScan.isScanning || store.isDeleting)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name).font(.headline)
                Text(readOnlyPurpose(item.name)).font(.caption).foregroundStyle(.secondary)
                Text(item.url.path).font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                Text(item.isComplete ? "completeResults" : "partialResults")
                    .font(.caption2).foregroundColor(item.isComplete ? .secondary : .orange)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                Text(String(format: L("xcodeEstimatedSize"),
                            ByteCountFormatter.string(fromByteCount: item.logicalBytes, countStyle: .file)))
                Text(String(format: L("xcodeAllocated"),
                            ByteCountFormatter.string(fromByteCount: item.allocatedBytes, countStyle: .file)))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            finderButton(item.url)
        }.padding(.vertical, 5)
    }

    private func readOnlyPurpose(_ name: String) -> String {
        switch name {
        case "DeviceLogs": L("xcodePurposeDeviceLogs")
        case "DocumentationCache": L("xcodePurposeDocumentationCache")
        case "DocumentationIndex": L("xcodePurposeDocumentationIndex")
        case "Products": L("xcodePurposeProducts")
        case "DVTDownloads": L("xcodePurposeDVTDownloads")
        case "XCTestDevices": L("xcodePurposeXCTestDevices")
        default: L("xcodePurposeSharedCache")
        }
    }

    @ViewBuilder
    private func readOnlyProgress(_ progress: ScanProgress?, title: String) -> some View {
        if let progress {
            VStack(alignment: .leading, spacing: 3) {
                Text(title + " · " + String(format: L("scanProgressCounts"),
                    progress.processedFiles, progress.processedDirectories,
                    ByteCountFormatter.string(fromByteCount: progress.processedBytes, countStyle: .file)))
                Text(progress.currentPath).lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
            }.font(.caption).foregroundStyle(.secondary)
        }
    }

    private func runtimePath(_ runtime: XcodeSimulatorRuntime) -> URL? {
        guard let path = runtime.path, path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path)
    }

    private func finderButton(_ url: URL?) -> some View {
        Button {
            guard let url, FileManager.default.fileExists(atPath: url.path) else {
                operationError = L("xcodeFinderPathUnavailable")
                return
            }
            store.reveal(url)
        } label: {
            Image(systemName: "folder")
        }
        .hoverHighlight()
        .disabled(url == nil)
        .help(L(url == nil ? "xcodeFinderPathUnavailable" : "showInFinder"))
    }

    @ViewBuilder
    private func runtimeRelationship(_ runtime: XcodeSimulatorRuntime) -> some View {
        switch simulatorScan {
        case .complete:
            if let association = XcodeStorage.runtimeAssociation(
                for: runtime, among: runtimes, devices: simulators) {
                Text(String(format: L("xcodeRuntimeDevices"),
                            association.deviceCount, association.bootedDeviceCount))
                    .font(.caption).foregroundStyle(.secondary)
                if association.matchingImageCount > 1 {
                    Text(String(format: L("xcodeRuntimeSharedIdentifier"), association.matchingImageCount))
                        .font(.caption).foregroundStyle(.orange)
                }
            } else {
                Text("xcodeRuntimeUnknownIdentifier")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .scanning:
            Text("xcodeRuntimeCheckingDevices").font(.caption).foregroundStyle(.secondary)
        case .notScanned, .partial, .unavailable, .cancelled:
            Text("xcodeRuntimeDevicesUnavailable").font(.caption).foregroundStyle(.orange)
        }
    }

    private func openXcode() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.dt.Xcode"),
              NSWorkspace.shared.open(url) else {
            operationError = L("xcodeOpenXcodeFailed")
            return
        }
        operationError = nil
    }

    private func scanStatus(_ scan: InventoryScan) -> String {
        switch scan {
        case .notScanned: L("xcodeNotScanned")
        case .scanning: L("scanning")
        case .complete(let seconds): String(format: L("xcodeScanDuration"), L("completeResults"), seconds)
        case .partial(let seconds): String(format: L("xcodeScanDuration"), L("partialResults"), seconds)
        case .unavailable(let seconds): String(format: L("xcodeScanDuration"), L("xcodeUnavailable"), seconds)
        case .cancelled(let seconds): String(format: L("xcodeScanDuration"), L("scanCancelled"), seconds)
        }
    }

    private func readOnlyStatus(_ report: XcodeReadOnlyReport, seconds: TimeInterval) -> InventoryScan {
        if report.cancelled { return .cancelled(seconds) }
        if report.isComplete { return .complete(seconds) }
        return report.readableSourceCount == 0 ? .unavailable(seconds) : .partial(seconds)
    }

    private func cancelReadOnlyScans() {
        sharedCacheControl?.cancel()
        additionalDataControl?.cancel()
    }

    private var projectScanStatus: String {
        if store.isScanning { return L("scanning") }
        guard store.hasScanned || store.hasPartialResults else { return L("xcodeNotScanned") }
        guard store.hasPartialResults else { return L("completeResults") }
        let roots = [XcodeStorage.defaultDerivedDataRoot] + preferences.derivedDataRoots
        let hasReadableSource = roots.contains { root in
            !store.warnings.contains {
                $0 == "Cannot read \(root.path)" || $0 == "Invalid root \(root.path)" ||
                $0 == "Overlapping root \(root.path)"
            }
        }
        return L(hasReadableSource ? "partialResults" : "xcodeUnavailable")
    }

    private func overviewRow(_ title: LocalizedStringKey, count: Int?, bytes: Int64?,
                             status: String, isScanning: Bool, sources: [String]) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout.weight(.semibold))
                if let count {
                    Text(String(format: L("xcodeOverviewCount"), count))
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(sources, id: \.self) { source in
                    Text(source).font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                HStack(spacing: 5) {
                    if isScanning { ProgressView().controlSize(.mini) }
                    Text(status)
                }.font(.caption)
                Text(bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
                     ?? L("notMeasured"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    private var projectsView: some View {
        VStack(spacing: 0) {
            HStack {
                Text("xcodeDerivedDataHelp").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("xcodeAddRoot") { chooseRoot() }
                    .hoverHighlight()
            }
            .padding(.horizontal, 20).padding(.vertical, 10)
            HStack {
                ClearableSearchField(placeholder: L("xcodeSearchProjects"), text: $projectQuery)
                    .onChange(of: projectQuery) { _, _ in pruneHiddenProjectSelection() }
                Picker("xcodeProjectFilter", selection: $projectFilter) {
                    Text("xcodeFilterAll").tag(ProjectFilter.all)
                    Text("xcodeFilterIdentified").tag(ProjectFilter.identified)
                    Text("xcodeFilterUnknown").tag(ProjectFilter.unknown)
                }
                .onChange(of: projectFilter) { _, _ in pruneHiddenProjectSelection() }
                Picker("xcodeProjectSort", selection: $projectSort) {
                    Text("xcodeSortSize").tag(ProjectSort.size)
                    Text("xcodeSortRecent").tag(ProjectSort.recent)
                    Text("xcodeSortName").tag(ProjectSort.name)
                }
            }
            .padding(.horizontal, 20).padding(.bottom, 10)
            if !preferences.derivedDataRoots.isEmpty {
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(preferences.derivedDataRoots, id: \.path) { root in
                            HStack {
                                Text(root.path).font(.caption).lineLimit(1)
                                Button {
                                    preferences.removeDerivedDataRoot(root)
                                    refreshAfterRootChange()
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                }
                                .buttonStyle(.plain)
                                .help(L("xcodeRemoveRoot"))
                                .hoverHighlight()
                            }
                            .padding(6).background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }.padding(.horizontal, 20)
            }
            if store.hasScanned && !store.isScanning {
                ScanCompletionSummaryView()
            }
            if store.isScanning {
                VStack(spacing: 10) {
                    ProgressView("scanning")
                    if let progress = store.scanProgress {
                        Text(L("scanStage_\(progress.stage.rawValue)"))
                        Text(String(format: L("scanProgressCounts"), progress.processedFiles,
                                    progress.processedDirectories,
                                    ByteCountFormatter.string(fromByteCount: progress.processedBytes,
                                                              countStyle: .file)))
                        Text(progress.currentPath)
                            .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                    }
                    Button("cancel") { store.cancel() }
                        .hoverHighlight()
                }
                .font(.caption).foregroundStyle(.secondary)
                .padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if visibleProjects.isEmpty {
                ContentUnavailableView(store.hasPartialResults && store.entries.isEmpty
                                       ? "xcodePartialNoProjects"
                                       : store.entries.isEmpty ? "xcodeNoProjects" : "xcodeNoMatchingProjects",
                                       systemImage: "hammer",
                                       description: Text(store.hasPartialResults && store.entries.isEmpty
                                           ? "xcodePartialNoProjectsDetail" : store.entries.isEmpty
                                           ? "xcodeNoProjectsDetail" : "xcodeNoMatchingProjectsDetail"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(visibleProjects) { group in
                    if group.entries.count > 1 {
                        DisclosureGroup {
                            ForEach(group.entries) { entry in projectRow(entry) }
                        } label: {
                            projectGroupRow(group)
                        }
                    } else if let entry = group.entries.first {
                        projectRow(entry)
                    }
                }
                .listStyle(.inset)
            }
            if !store.isScanning && (store.hasScanned || store.hasPartialResults) {
                HStack {
                    Text(store.hasPartialResults ? "partialResults" : "completeResults")
                    if store.scanMetrics.omittedCount > 0 {
                        Text(String(format: L("omittedItemsCount"), store.scanMetrics.omittedCount))
                    }
                    Spacer()
                }
                .font(.caption).foregroundStyle(store.hasPartialResults ? .orange : .secondary)
                .padding(.horizontal, 20).padding(.top, 8)
            }
            if !store.warnings.isEmpty {
                DisclosureGroup(String(format: L("scanWarnings"), store.warnings.count)) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(store.warnings, id: \.self) { warning in
                                Text(localizedWarning(warning)).font(.caption).textSelection(.enabled)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(height: 100)
                }
                .font(.caption).padding(10)
                .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 20)
            }
            HStack {
                Text(String(format: L("selectedSummary"), store.selectedEntries.count,
                    ByteCountFormatter.string(fromByteCount: store.estimatedSelectedBytes, countStyle: .file)))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("moveToTrash") { showingTrashConfirmation = true }
                    .hoverHighlight()
                    .disabled(store.selectedEntries.isEmpty || store.isScanning || store.isDeleting)
            }
            .padding(16)
            .background(.bar)
        }
    }

    private func projectGroupRow(_ group: XcodeProjectGroup, showRebuildHelp: Bool = false) -> some View {
        let selected = group.entries.filter { store.selectedIDs.contains($0.id) }
        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(projectName(group)).font(.headline)
                if let path = group.projectPath {
                    Text(path).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                } else if let entry = group.entries.first {
                    Text(entry.url.path).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Text(String(format: L("xcodeBuildDirectories"), group.entries.count))
                    .font(.caption).foregroundStyle(.secondary)
                Text(String(format: L("xcodeLastActivity"), group.lastActivity.formatted()))
                    .font(.caption2).foregroundStyle(.secondary)
                if showRebuildHelp {
                    if !selected.isEmpty {
                        Text(String(format: L("selectedSummary"), selected.count,
                                    ByteCountFormatter.string(
                                        fromByteCount: selected.reduce(0) { $0 + $1.estimatedBytes },
                                        countStyle: .file)))
                            .font(.caption2).foregroundStyle(.blue)
                    }
                    Text("xcodeRebuildHelp").font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                Text(ByteCountFormatter.string(fromByteCount: group.logicalBytes, countStyle: .file))
                if let allocated = group.allocatedBytes {
                    Text(String(format: L("xcodeAllocated"),
                                ByteCountFormatter.string(fromByteCount: allocated, countStyle: .file)))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }.padding(.vertical, 6)
    }

    private func localizedWarning(_ warning: String) -> String {
        if warning.hasPrefix("Invalid root ") {
            return warning.replacingOccurrences(of: "Invalid root ", with: L("xcodeInvalidRootWarning") + " ")
        }
        if warning.hasPrefix("Overlapping root ") {
            return warning.replacingOccurrences(of: "Overlapping root ", with: L("xcodeOverlappingRootWarning") + " ")
        }
        if warning.hasPrefix("Cannot read ") {
            return warning.replacingOccurrences(of: "Cannot read ", with: L("cannotRead") + " ")
        }
        if warning.hasPrefix("Cannot verify ") {
            return warning.replacingOccurrences(of: "Cannot verify ", with: L("cannotVerify") + " ")
        }
        return L(warning)
    }

    private func projectRow(_ entry: ScanEntry) -> some View {
        let path = entry.note
        let lastUsed = entry.lastUsedDate
        return HStack(alignment: .top, spacing: 12) {
            Toggle("", isOn: Binding(get: { store.selectedIDs.contains(entry.id) }, set: { selected in
                if selected { store.selectedIDs.insert(entry.id) }
                else { store.selectedIDs.remove(entry.id) }
            }))
            .labelsHidden()
            .disabled(store.isDeleting || store.isScanning)
            VStack(alignment: .leading, spacing: 4) {
                Text(projectName(entry))
                    .font(.headline)
                Text(path.isEmpty ? entry.url.path : path)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                if !path.isEmpty {
                    Text(entry.url.path).font(.caption2).foregroundStyle(.tertiary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Text("xcodeRebuildHelp").font(.caption).foregroundStyle(.secondary)
                Text(String(format: L(lastUsed == nil ? "xcodeLastModified" : "xcodeLastUsed"),
                            (lastUsed ?? Date(timeIntervalSince1970: Double(entry.stamp.modifiedSeconds))).formatted()))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                Text(ByteCountFormatter.string(fromByteCount: entry.estimatedBytes, countStyle: .file))
                if let allocated = entry.allocatedBytes {
                    Text(String(format: L("xcodeAllocated"),
                                ByteCountFormatter.string(fromByteCount: allocated, countStyle: .file)))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            Button { store.reveal(entry.url) } label: { Image(systemName: "folder") }
                .help(L("showInFinder"))
                .hoverHighlight()
        }
        .padding(.vertical, 6)
    }

    private var archivesView: some View {
        VStack(spacing: 0) {
            Text("xcodeArchivesReadOnly").font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(16)
            ForEach(archiveWarnings, id: \.self) { warning in
                Text(localizedWarning(warning)).font(.caption).foregroundStyle(.orange)
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
            }
            if archiveScan.isScanning {
                ProgressView("scanning").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if archives.isEmpty {
                ContentUnavailableView("xcodeNoArchives", systemImage: "archivebox")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(archives) { archive in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(archive.name).font(.headline)
                            Text(archive.url.path).font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                            if let date = archive.created { Text(date.formatted()).font(.caption2).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: archive.logicalBytes, countStyle: .file))
                        Button { store.reveal(archive.url) } label: { Image(systemName: "folder") }
                            .help(L("showInFinder"))
                            .hoverHighlight()
                    }.padding(.vertical, 6)
                }
            }
        }
    }

    private var simulatorsView: some View {
        VStack(spacing: 0) {
            Text("xcodeSimulatorHelp").font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(16)
            if simulatorScan.isScanning {
                ProgressView("scanning").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let simulatorInventoryError {
                ContentUnavailableView("xcodeUnavailable", systemImage: "iphone.slash",
                                       description: Text(simulatorInventoryError))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if simulators.isEmpty {
                ContentUnavailableView("xcodeNoSimulators", systemImage: "iphone")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(simulators) { device in
                    simulatorRow(device)
                }
            }
            HStack {
                Spacer()
                Button("xcodeDeleteDevices", role: .destructive) { showingSimulatorConfirmation = true }
                    .hoverHighlight()
                    .disabled(selectedSimulatorIDs.isEmpty || simulatorScan.isScanning)
            }.padding(16).background(.bar)
        }
    }

    private func simulatorRow(_ device: XcodeSimulator) -> some View {
        HStack(spacing: 12) {
            Toggle("", isOn: Binding(get: { selectedSimulatorIDs.contains(device.id) }, set: { selected in
                if selected { selectedSimulatorIDs.insert(device.id) }
                else { selectedSimulatorIDs.remove(device.id) }
            }))
            .labelsHidden().disabled(!device.canDelete || simulatorScan.isScanning || store.isDeleting)
            VStack(alignment: .leading, spacing: 3) {
                Text(device.name).font(.headline)
                Text("\(device.runtimeName) · \(device.state)")
                    .font(.caption).foregroundStyle(.secondary)
                if let date = device.lastUsed {
                    Text(date.formatted()).font(.caption2).foregroundStyle(.secondary)
                }
                Text(device.dataPath?.path ?? L("xcodeFinderPathUnavailable"))
                    .font(.caption2).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            }
            Spacer(minLength: 8)
            Text(device.dataBytes.map {
                ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)
            } ?? L("notMeasured"))
                .font(.caption).foregroundStyle(.secondary)
            finderButton(device.dataPath)
        }
        .padding(.vertical, 6)
    }

    private func chooseRoot() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = L("xcodeChooseRootHelp")
        if panel.runModal() == .OK, let url = panel.url {
            let previousCount = preferences.derivedDataRoots.count
            preferences.addDerivedDataRoot(url)
            if preferences.derivedDataRoots.count > previousCount {
                refreshAfterRootChange()
            } else {
                operationError = L("xcodeInvalidRoot")
            }
        }
    }

    private func refreshAfterRootChange() {
        clearComparison()
        store.invalidateScan()
        store.scan()
        Task { await refreshExtras() }
    }

    private func refresh() {
        clearComparison()
        store.scan()
        Task { await refreshExtras() }
    }

    private func comparisonCategoryKey(_ category: XcodeReviewCategory) -> String {
        switch category {
        case .projects: "xcodeProjects"
        case .sharedCaches: "xcodeSharedCaches"
        case .simulators: "xcodeSimulators"
        case .archives: "xcodeArchives"
        case .runtimes: "xcodeRuntimes"
        case .deviceSupport: "xcodeDeviceSupport"
        case .otherData: "xcodeAdditionalData"
        }
    }

    private func comparisonSize(_ bytes: Int64?) -> String {
        bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
            ?? L("notMeasured")
    }

    private func inventoryComplete(_ scan: InventoryScan) -> Bool {
        if case .complete = scan { return true }
        return false
    }

    private var reviewSnapshot: XcodeReviewSnapshot {
        XcodeReviewSnapshot(measures: [
            .projects: XcodeReviewMeasure(count: store.entries.count,
                estimatedBytes: store.entries.reduce(0) { $0 + $1.estimatedBytes },
                complete: store.hasScanned && !store.hasPartialResults && !store.isScanning),
            .sharedCaches: XcodeReviewMeasure(count: sharedCaches.count,
                estimatedBytes: sharedCaches.reduce(0) { $0 + $1.logicalBytes },
                complete: inventoryComplete(sharedCacheScan)),
            .simulators: XcodeReviewMeasure(count: simulators.count,
                estimatedBytes: simulators.allSatisfy { $0.dataBytes != nil }
                    ? simulators.reduce(0) { $0 + ($1.dataBytes ?? 0) } : nil,
                complete: inventoryComplete(simulatorScan)),
            .archives: XcodeReviewMeasure(count: archives.count,
                estimatedBytes: archives.reduce(0) { $0 + $1.logicalBytes },
                complete: inventoryComplete(archiveScan)),
            .runtimes: XcodeReviewMeasure(count: runtimes.count,
                estimatedBytes: runtimes.allSatisfy { $0.logicalBytes != nil }
                    ? runtimes.reduce(0) { $0 + ($1.logicalBytes ?? 0) } : nil,
                complete: inventoryComplete(runtimeScan)),
            .deviceSupport: XcodeReviewMeasure(count: deviceSupport.count,
                estimatedBytes: deviceSupport.reduce(0) { $0 + $1.logicalBytes },
                complete: inventoryComplete(deviceSupportScan)),
            .otherData: XcodeReviewMeasure(count: additionalData.count,
                estimatedBytes: additionalData.reduce(0) { $0 + $1.logicalBytes },
                complete: inventoryComplete(additionalDataScan))
        ])
    }

    private func beginComparison() {
        comparisonBefore = reviewSnapshot
        comparisonAfter = nil
        comparisonRefreshPending = false
        comparisonExtrasDone = false
    }

    private func finishComparisonIfReady() {
        guard comparisonRefreshPending, comparisonExtrasDone, !store.isScanning else { return }
        comparisonAfter = reviewSnapshot
        comparisonRefreshPending = false
    }

    private func clearComparison() {
        comparisonBefore = nil
        comparisonAfter = nil
        comparisonRefreshPending = false
        comparisonExtrasDone = false
    }

    private func refreshExtras() async {
        cancelReadOnlyScans()
        selectedCachePaths.removeAll()
        let refreshID = UUID()
        extraRefreshID = refreshID
        let sharedControl = ScanControl { progress in
            Task { @MainActor in
                if extraRefreshID == refreshID { sharedCacheProgress = progress }
            }
        }
        let additionalControl = ScanControl { progress in
            Task { @MainActor in
                if extraRefreshID == refreshID { additionalDataProgress = progress }
            }
        }
        sharedCacheControl = sharedControl
        additionalDataControl = additionalControl
        archiveScan = .scanning
        simulatorScan = .scanning
        runtimeScan = .scanning
        deviceSupportScan = .scanning
        sharedCacheScan = .scanning
        additionalDataScan = .scanning
        archives = []
        simulators = []
        runtimes = []
        deviceSupport = []
        sharedCaches = []
        additionalData = []
        archiveWarnings = []
        deviceSupportWarnings = []
        sharedCacheWarnings = []
        additionalDataWarnings = []
        sharedCacheProgress = nil
        additionalDataProgress = nil
        simulatorInventoryError = nil
        runtimeError = nil
        operationError = nil
        selectedSimulatorIDs.removeAll()

        await withTaskGroup(of: ExtraInventoryResult.self) { group in
            group.addTask(priority: .utility) {
                let start = ProcessInfo.processInfo.systemUptime
                let inventory = XcodeStorage.archiveInventory()
                return .archives(inventory, ProcessInfo.processInfo.systemUptime - start)
            }
            group.addTask(priority: .utility) {
                let start = ProcessInfo.processInfo.systemUptime
                let inventory = XcodeStorage.deviceSupportInventory()
                return .deviceSupport(inventory, ProcessInfo.processInfo.systemUptime - start)
            }
            let derivedRoots = [XcodeStorage.defaultDerivedDataRoot] + preferences.derivedDataRoots
            group.addTask(priority: .utility) {
                let start = ProcessInfo.processInfo.systemUptime
                let report = XcodeStorage.sharedCacheInventory(derivedDataRoots: derivedRoots,
                                                                control: sharedControl)
                return .sharedCaches(report, ProcessInfo.processInfo.systemUptime - start)
            }
            group.addTask(priority: .utility) {
                let start = ProcessInfo.processInfo.systemUptime
                let report = XcodeStorage.additionalDataInventory(control: additionalControl)
                return .additionalData(report, ProcessInfo.processInfo.systemUptime - start)
            }
            group.addTask(priority: .utility) {
                let start = ProcessInfo.processInfo.systemUptime
                do {
                    let items = try XcodeStorage.simulators()
                    return .simulators(items, nil, ProcessInfo.processInfo.systemUptime - start)
                } catch {
                    return .simulators([], error.localizedDescription,
                                       ProcessInfo.processInfo.systemUptime - start)
                }
            }
            group.addTask(priority: .utility) {
                let start = ProcessInfo.processInfo.systemUptime
                do {
                    let items = try XcodeStorage.runtimeImages()
                    return .runtimes(items, nil, ProcessInfo.processInfo.systemUptime - start)
                } catch {
                    return .runtimes([], error.localizedDescription,
                                     ProcessInfo.processInfo.systemUptime - start)
                }
            }
            for await result in group {
                guard extraRefreshID == refreshID, !Task.isCancelled else { continue }
                switch result {
                case .archives(let inventory, let seconds):
                    archives = inventory.items
                    archiveWarnings = inventory.warnings
                    archiveScan = inventory.warnings.contains("Cannot read \(XcodeStorage.defaultArchivesRoot.path)")
                        ? .unavailable(seconds) : inventory.isComplete ? .complete(seconds) : .partial(seconds)
                case .simulators(let items, let error, let seconds):
                    simulators = items
                    simulatorInventoryError = error
                    simulatorScan = error == nil ? .complete(seconds) : .unavailable(seconds)
                case .runtimes(let items, let error, let seconds):
                    runtimes = items
                    runtimeError = error
                    runtimeScan = error == nil ? .complete(seconds) : .unavailable(seconds)
                case .deviceSupport(let inventory, let seconds):
                    deviceSupport = inventory.items
                    deviceSupportWarnings = inventory.warnings
                    deviceSupportScan = inventory.warnings.contains("Cannot read \(XcodeStorage.defaultDeviceSupportRoot.path)")
                        ? .unavailable(seconds) : inventory.isComplete ? .complete(seconds) : .partial(seconds)
                case .sharedCaches(let report, let seconds):
                    sharedCaches = report.items
                    sharedCacheWarnings = report.warnings
                    sharedCacheScan = readOnlyStatus(report, seconds: seconds)
                    sharedCacheProgress = nil
                case .additionalData(let report, let seconds):
                    additionalData = report.items
                    additionalDataWarnings = report.warnings
                    additionalDataScan = readOnlyStatus(report, seconds: seconds)
                    additionalDataProgress = nil
                }
            }
        }
    }

    private func deleteSelectedSimulators() {
        beginComparison()
        let ids = selectedSimulatorIDs.sorted()
        selectedSimulatorIDs.removeAll()
        Task {
            let failures = await Task.detached(priority: .userInitiated) {
                ids.compactMap { id -> String? in
                    do { try XcodeStorage.deleteSimulator(id: id); return nil }
                    catch { return "\(id): \(error.localizedDescription)" }
                }
            }.value
            await refreshExtras()
            operationError = failures.isEmpty ? operationError : failures.joined(separator: "\n")
            comparisonAfter = reviewSnapshot
        }
    }

    private func deleteSelectedCaches() {
        let selected = selectedCachePaths
        let roots = [XcodeStorage.defaultDerivedDataRoot] + preferences.derivedDataRoots
        let entries = sharedCaches.filter { selected.contains($0.url.path) }
            .compactMap { XcodeStorage.cacheDeletionEntry(for: $0, derivedDataRoots: roots) }
        selectedCachePaths.removeAll()
        guard !entries.isEmpty else {
            operationError = L("xcodeCacheSelectionChanged")
            return
        }
        if entries.count != selected.count { operationError = L("xcodeCacheSelectionChanged") }
        beginComparison()
        Task {
            await store.deleteXcodeCaches(entries)
        }
    }
}
