import AppKit
import Charts
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var store: CleanerStore
    @EnvironmentObject private var preferences: AppPreferences
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @State private var pendingMode: DeleteMode = .trash
    @State private var showingConfirmation = false
    @State private var inspectedEntry: ScanEntry?
    @State private var previewURL: URL?
    @State private var previewSelection: UUID?
    @State private var spacePieHasAppeared = false
    @State private var showingVolumeOverview = true
    @State private var hoveredVolumeID: String?
    @State private var duplicateGroupPage = 0
    @State private var cloudPage = 0
    @State private var showingCloudConfirmation = false
    @State private var overviewQuery = ""
    @State private var overviewCategory: ScanCategory?
    @State private var reviewOperationFilter: CleanupOverviewOperation?
    @State private var reviewRiskFilter: RiskLevel?
    @State private var overviewPage = 0
    @State private var overviewScanSelection: Set<ScanCategory> =
        [.downloads, .systemCache, .orphans]
    @State private var showingOverviewPlanConfirmation = false
    @State private var showingAccountingNotices = false
    @State private var showingAccountingExclusions = false
    private let overviewItemsPerPage = 50
    private let cloudItemsPerPage = 200
    private let duplicateGroupsPerPage = 200
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { store.category }, set: { store.changeCategory($0) })) {
                Section {
                    categoryRow(.overview)
                }
                Section(L("explore")) {
                    categoryRow(.space)
                    categoryRow(.large)
                    categoryRow(.duplicates)
                    categoryRow(.downloads)
                    categoryRow(.icloud)
                }
                Section(L("cleanup")) {
                    categoryRow(.systemCache)
                    categoryRow(.developerCache)
                    categoryRow(.uninstall)
                    categoryRow(.orphans)
                }
            }
            .navigationTitle("Sys Cleaner")
            .frame(minWidth: 200)
        } detail: {
            VStack(spacing: 0) {
                if store.category == .overview {
                    overviewContent
                } else if store.category == .developerCache {
                    XcodeWorkspaceView()
                } else {
                header
                if store.hasScanned && !store.isScanning {
                    ScanCompletionSummaryView()
                }
                Divider()
                if store.category == .icloud {
                    cloudContent
                } else if store.isScanning {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text(L("scanStage_\(store.scanProgress?.stage.rawValue ?? "discovering")"))
                            .font(.headline)
                        if let progress = store.scanProgress {
                            Text(String(format: L("scanProgressCounts"), progress.processedFiles,
                                        progress.processedDirectories,
                                        fileSize(progress.processedBytes)))
                                .foregroundStyle(.secondary)
                            Text(progress.currentPath)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: 440)
                        }
                        Button("cancel") { store.cancel() }
                            .hoverHighlight()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if !store.hasScanned && store.entries.isEmpty && !store.hasSpaceResults {
                    ContentUnavailableView {
                        Label(store.category.title, systemImage: store.category.symbol)
                    } description: {
                        Text("startPrompt")
                    } actions: {
                        scanButton
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if store.entries.isEmpty && !store.hasSpaceResults {
                    ContentUnavailableView {
                        Label("noResults", systemImage: "checkmark.circle")
                    } description: {
                        Text("noResultsDetail")
                    } actions: {
                        scanButton
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if store.category != .space && store.visibleEntries.isEmpty {
                    ContentUnavailableView {
                        Label("noMatchingResults", systemImage: "line.3.horizontal.decrease.circle")
                    } description: {
                        Text("adjustSearchOrFilter")
                    } actions: {
                        Button("clearSearchAndFilter") {
                            store.resultQuery = ""
                            store.resultFilter = .all
                        }
                        .hoverHighlight()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if store.category == .space {
                    spaceContent
                } else {
                    resultsContent
                }
                if !store.warnings.isEmpty { warningsView }
                if store.category != .space && store.category != .orphans && store.category != .icloud { actionBar }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .onDrop(of: [UTType.fileURL.identifier], isTargeted: nil) { providers in
                guard store.category == .uninstall, let provider = providers.first else { return false }
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    let url: URL?
                    if let data = item as? Data {
                        url = URL(dataRepresentation: data, relativeTo: nil)
                    } else {
                        url = item as? URL
                    }
                    if let url { Task { @MainActor in store.openApplication(url) } }
                }
                return true
            }
            .navigationTitle(store.reviewedApplicationName ?? store.category.title)
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button { store.showHistory = true } label: {
                        Label("cleanupHistory", systemImage: "clock.arrow.circlepath")
                    }
                    .help(L("cleanupHistory"))
                    .hoverHighlight()
                }
                ToolbarItem(placement: .automatic) {
                    Button { openSettings() } label: { Label("settings", systemImage: "gearshape") }
                        .help(L("settings"))
                        .hoverHighlight()
                }
            }
            .alert(pendingMode == .trash ? L("confirmTrash") : L("confirmPermanent"),
                   isPresented: $showingConfirmation) {
                Button(pendingMode == .trash ? L("moveToTrash") : L("deletePermanently"), role: .destructive) {
                    store.delete(pendingMode)
                }
                Button(L("cancel"), role: .cancel) {}
            } message: {
                Text(String(format: L("confirmCount"), store.selectedEntries.count,
                            fileSize(store.estimatedSelectedBytes)))
            }
            .alert(L("icloudConfirmTitle"), isPresented: $showingCloudConfirmation) {
                Button(L("icloudEvict"), role: .destructive) { store.evictCloud() }
                Button(L("cancel"), role: .cancel) {}
            } message: {
                Text(String(format: L("icloudConfirmDetail"), store.selectedEntries.count,
                            fileSize(store.selectedAllocatedBytes ?? 0)))
            }
            .alert(L("overviewPlanConfirmTitle"), isPresented: $showingOverviewPlanConfirmation) {
                Button("overviewExecutePlan", role: .destructive) { store.executeOverviewPlan() }
                Button(L("cancel"), role: .cancel) {}
            } message: {
                Text(overviewPlanConfirmationText)
            }
            .sheet(isPresented: $store.showResults) { resultsSheet }
            .sheet(isPresented: $store.showHistory) { historySheet }
            .alert(item: $inspectedEntry) { entry in
                Alert(title: Text(entry.url.lastPathComponent),
                      message: Text(inspectorMessage(for: entry)),
                      dismissButton: .default(Text("done")))
            }
            .quickLookPreview($previewURL)
        }
        .onChange(of: store.minimumMB) { _, _ in store.invalidateScan() }
        .onChange(of: store.olderThanDays) { _, _ in store.invalidateScan() }
        .onChange(of: preferences.language) { _, _ in store.refreshSorting() }
        .onChange(of: store.category) { _, _ in duplicateGroupPage = 0 }
        .onChange(of: store.cloudFolder) { _, _ in cloudPage = 0 }
        .onChange(of: store.visibleEntries.count) { _, _ in cloudPage = 0 }
        .onChange(of: store.resultQuery) { _, _ in duplicateGroupPage = 0 }
        .onChange(of: store.resultFilter) { _, _ in duplicateGroupPage = 0 }
        .onChange(of: store.sortSelection) { _, _ in duplicateGroupPage = 0 }
        .onChange(of: store.visibleDuplicateGroups.count) { _, count in
            duplicateGroupPage = min(duplicateGroupPage,
                                     max(0, (count - 1) / duplicateGroupsPerPage))
        }
        .onChange(of: overviewQuery) { _, _ in overviewPage = 0 }
        .onChange(of: overviewCategory) { _, _ in overviewPage = 0 }
        .onChange(of: reviewOperationFilter) { _, _ in overviewPage = 0 }
        .onChange(of: reviewRiskFilter) { _, _ in overviewPage = 0 }
        .onChange(of: store.hasScanned) { _, scanned in
            if store.category == .space && scanned { showingVolumeOverview = false }
            if !scanned { duplicateGroupPage = 0 }
        }
        .onAppear {
            FinderReviewBridge.shared.connect(store: store, openMainWindow: { openWindow(id: "main") })
        }
    }

    private func categoryRow(_ category: ScanCategory) -> some View {
        Label(category.title, systemImage: category.symbol).tag(category)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    if store.category == .uninstall, store.reviewedApplicationName != nil {
                        Button { store.backFromApplication() } label: {
                            Label("back", systemImage: "chevron.left")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                        .hoverHighlight()
                        .disabled(store.isDeleting)
                        .padding(.bottom, 4)
                    }
                    Text(store.reviewedApplicationName ?? store.category.title).font(.largeTitle.bold())
                    Text(descriptionKey).foregroundStyle(.secondary)
                    if let token = store.reviewedHomebrewCaskToken {
                        Text(String(format: L("appHomebrewNotice"), token))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if store.hasScanned && !store.isScanning &&
                    (store.category == .space ? store.hasSpaceResults : !store.entries.isEmpty) {
                    sortMenu
                }
                if store.reviewedApplicationName == nil && store.hasScanned && !store.isScanning &&
                    (store.category == .space ? store.hasSpaceResults : !store.visibleEntries.isEmpty) {
                    scanButton
                }
            }
            if [.space, .large, .duplicates].contains(store.category) {
                HStack {
                    Image(systemName: "folder")
                    Text(store.root.path).lineLimit(1).truncationMode(.middle)
                        .font(.callout.monospaced())
                    Spacer()
                    Button("chooseFolder") { store.chooseFolder() }
                        .focusEffectDisabled()
                        .hoverHighlight()
                }
                .padding(10)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            }
            if store.category == .space && !store.volumes.isEmpty {
                HStack {
                    Text("volumeOverview").font(.callout.weight(.semibold))
                    Text(String(format: L("volumeCount"), store.volumes.count))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(showingVolumeOverview ? "hideVolumes" : "showVolumes") {
                        showingVolumeOverview.toggle()
                    }
                        .buttonStyle(.borderless)
                        .hoverHighlight()
                }
                if showingVolumeOverview {
                    ScrollView(.vertical) {
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible())],
                                  spacing: 8) {
                            ForEach(store.volumes) { volume in
                                volumeCard(volume)
                            }
                        }
                    }
                    .frame(height: store.volumes.count > 2 ? 232 : 112)
                    .scrollIndicators(.visible)
                    HStack {
                        Text("volumeReclaimableHelp")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if store.volumes.count > 4 {
                            Text("volumeScrollHint")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Menu("scanEntireVolume") {
                            ForEach(store.volumes) { volume in
                                Button(volume.name) { store.scanEntireVolume(volume) }
                            }
                        }
                        .hoverHighlight()
                        .disabled(store.isScanning || store.isDeleting)
                        .help(L("scanEntireVolumeHelp"))
                        Button("refreshVolumes") { store.refreshVolumes() }
                            .buttonStyle(.borderless)
                            .hoverHighlight()
                    }
                }
            }
            if store.category == .large {
                HStack(spacing: 32) {
                    HStack(spacing: 8) {
                        Text("minimumSize")
                        Picker("minimumSize", selection: $store.minimumMB) {
                            Text("minimum100MB").tag(100)
                            Text("minimum500MB").tag(500)
                            Text("minimum1GB").tag(1024)
                        }
                        .labelsHidden()
                        .frame(width: 96)
                    }
                    HStack(spacing: 8) {
                        Text("olderThan")
                        Picker("olderThan", selection: $store.olderThanDays) {
                            Text("anyTime").tag(0)
                            Text("olderThan30Days").tag(30)
                            Text("olderThan180Days").tag(180)
                        }
                        .labelsHidden()
                        .frame(width: 100)
                    }
                    Spacer()
                }
            }
            if store.category == .orphans {
                HStack {
                    Text("orphanReviewEvidence").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if !preferences.ignoredOrphanIdentifiers.isEmpty {
                        Menu(String(format: L("orphanIgnoredCount"),
                                    preferences.ignoredOrphanIdentifiers.count)) {
                            ForEach(preferences.ignoredOrphanIdentifiers.sorted(), id: \.self) { identifier in
                                Button(identifier) { store.restoreIgnoredOrphanIdentifier(identifier) }
                            }
                        }
                        .hoverHighlight()
                        .disabled(store.isScanning)
                    }
                }
            }
            if store.category != .space {
                HStack {
                    ClearableSearchField(
                        placeholder: L(store.category == .uninstall && store.reviewedApplicationName == nil ?
                                       "searchApps" : "searchResults"),
                        text: $store.resultQuery)
                        .frame(maxWidth: 360)
                    Menu {
                        Picker("filterResults", selection: $store.resultFilter) {
                            Text("filter_all").tag(ScanEntryFilter.all)
                            if store.category != .duplicates {
                                Text("filter_selectable").tag(ScanEntryFilter.selectable)
                                Text("filter_locked").tag(ScanEntryFilter.locked)
                            }
                            Text("filter_images").tag(ScanEntryFilter.images)
                            Text("filter_videos").tag(ScanEntryFilter.videos)
                            Text("filter_documents").tag(ScanEntryFilter.documents)
                            Text("filter_archives").tag(ScanEntryFilter.archives)
                            Text("filter_folders").tag(ScanEntryFilter.folders)
                            Text("filter_other").tag(ScanEntryFilter.other)
                        }
                    } label: {
                        Label(L("filter_\(store.resultFilter.rawValue)"), systemImage: "line.3.horizontal.decrease")
                    }
                    .hoverHighlight()
                    .disabled(store.isScanning)
                    if store.hasScanned && (!store.resultQuery.isEmpty || store.resultFilter != .all) {
                        Text(String(format: L("visibleResultCount"), store.visibleEntries.count,
                                    store.entries.count))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if store.category == .uninstall && store.reviewedApplicationName == nil {
                        Button("chooseApp") { store.chooseApplication() }
                            .hoverHighlight()
                            .disabled(store.isScanning || store.isDeleting)
                        Text("dropAppHint").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            HStack(spacing: 12) {
                Label(String(format: L("itemsCount"), store.summaryCount), systemImage: "doc")
                Label(String(format: L("logicalSizeValue"), fileSize(store.summaryBytes)),
                      systemImage: "internaldrive")
                if let allocated = store.scanMetrics.allocatedBytes {
                    Text(String(format: L("allocatedSizeValue"), fileSize(allocated)))
                        .help(L("allocatedSizeHelp"))
                }
                if store.category == .uninstall && store.reviewedApplicationName == nil {
                    Text(String(format: L("measuredAppsCount"),
                                store.entries.filter(\.sizeIsKnown).count, store.entries.count))
                }
                if store.hasScanned {
                    Text(store.hasPartialResults ? "partialResults" : "completeResults")
                        .foregroundStyle(store.hasPartialResults ? .orange : .secondary)
                    if store.scanMetrics.omittedCount > 0 {
                        Text(String(format: L("omittedItemsCount"), store.scanMetrics.omittedCount))
                            .foregroundStyle(.orange)
                    }
                }
                Spacer()
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .padding(20)
    }

    private var descriptionKey: LocalizedStringKey {
        switch store.category {
        case .overview: "overviewDescription"
        case .space: "spaceDescription"
        case .large: "largeDescription"
        case .duplicates: "duplicatesDescription"
        case .downloads: "downloadsDescription"
        case .systemCache: "systemCacheDescription"
        case .developerCache: "developerCacheDescription"
        case .uninstall: "uninstallDescription"
        case .orphans: "orphansDescription"
        case .icloud: "icloudDescription"
        }
    }

    private func volumeCard(_ volume: CleanerStore.VolumeSummary) -> some View {
        Button {
            store.chooseFolder(startingAt: URL(fileURLWithPath: volume.id))
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 5) {
                        Image(systemName: "internaldrive")
                        Text(volume.name).fontWeight(.medium)
                    }
                    .foregroundStyle(.primary)
                    Text(String(format: L("volumeUsedValue"), fileSize(volume.usedBytes)))
                    Text(String(format: L("volumeFreeValue"), fileSize(volume.freeBytes)))
                    Text(String(format: L("volumeReclaimableValue"),
                                fileSize(volume.systemReclaimableEstimate)))
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .frame(height: 112)
            .background(.quaternary.opacity(hoveredVolumeID == volume.id ? 0.8 : 0.4),
                        in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.accentColor.opacity(hoveredVolumeID == volume.id ? 0.55 : 0), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .help(L("chooseVolumeFolder"))
        .onHover { hoveredVolumeID = $0 ? volume.id : nil }
    }

    private var scanButton: some View {
        Button(store.hasScanned ? L("scanAgain") : L("startScan")) {
            if store.category == .space { spacePieHasAppeared = false }
            store.scan()
        }
            .buttonStyle(.borderedProminent)
            .hoverHighlight()
            .disabled(store.isScanning || store.isDeleting)
    }

    private var sortMenu: some View {
        Menu {
            Picker("sortField", selection: Binding(
                get: { store.sortSelection.field }, set: { store.setSortField($0) })) {
                    Text("sortSize").tag(ScanSortField.size)
                    Text("sortName").tag(ScanSortField.name)
                    if store.category != .space {
                        Text("sortModified").tag(ScanSortField.modified)
                    }
                }
            Picker("sortDirection", selection: Binding(
                get: { store.sortSelection.direction }, set: { store.setSortDirection($0) })) {
                    Text("sortAscending").tag(ScanSortDirection.ascending)
                    Text("sortDescending").tag(ScanSortDirection.descending)
                }
        } label: {
            Label("sort", systemImage: "arrow.up.arrow.down")
        }
        .menuStyle(.borderedButton)
        .hoverHighlight()
        .disabled(store.isDeleting)
        .help(L("sort"))
    }

    private var overviewContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("overview").font(.largeTitle.bold())
                    Text("overviewDescription").foregroundStyle(.secondary)
                }
                overviewScanControls
                HStack(spacing: 12) {
                    overviewMetric("overviewLocalEstimate", bytes: store.cleanupOverview.localEstimate,
                                   symbol: "internaldrive")
                    overviewMetric("overviewCloudEstimate", bytes: store.cleanupOverview.cloudEstimate,
                                   symbol: "icloud")
                }
                Text("overviewEstimateHelp")
                    .font(.caption).foregroundStyle(.secondary)
                Text("overviewScanBoundaryHelp")
                    .font(.caption).foregroundStyle(.secondary)
                overviewExcludedLocations
                if store.cleanupOverview.duplicateCount > 0 {
                    Text(String(format: L("overviewOverlapCount"), store.cleanupOverview.duplicateCount))
                        .font(.caption).foregroundStyle(.secondary)
                }
                overviewReviewContent
                Text("overviewSources").font(.title3.bold())
                ForEach(store.cleanupOverview.sections) { section in
                    HStack(spacing: 12) {
                        Image(systemName: section.category.symbol)
                            .frame(width: 24)
                            .foregroundStyle(Color.accentColor)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(section.category.title).fontWeight(.semibold)
                            overviewScopePaths(for: section.category)
                            if !section.scanned {
                                Text("overviewNotScanned").foregroundStyle(.secondary)
                            } else if section.category == .space || section.category == .orphans {
                                Text("overviewReadOnly").foregroundStyle(.secondary)
                            } else {
                                Text(String(format: L("overviewCandidateSummary"),
                                            section.candidateCount, fileSize(section.estimatedBytes)))
                                    .foregroundStyle(.secondary)
                            }
                            if section.incomplete {
                                Text("partialResults").foregroundStyle(.orange)
                            }
                            if section.category == .developerCache && section.scanned &&
                                !store.xcodeInventoryWasScanned {
                                Text("overviewXcodeQuickIncomplete")
                                    .font(.caption).foregroundStyle(.orange)
                            }
                            if section.omittedCount > 0 {
                                Text(String(format: L("omittedItemsCount"), section.omittedCount))
                                    .foregroundStyle(.orange)
                            }
                            if section.scanned, !store.diagnostics(for: section.category).isEmpty {
                                overviewDiagnostics(store.diagnostics(for: section.category))
                            }
                            if section.category == .uninstall && section.scanned {
                                if let name = store.lastReviewedApplicationName {
                                    Text(String(format: L("overviewUninstallReviewed"), name))
                                        .foregroundStyle(.secondary)
                                } else {
                                    Text("overviewUninstallHint").foregroundStyle(.secondary)
                                }
                            }
                        }
                        Spacer()
                        Button("overviewOpenCategory") { store.changeCategory(section.category) }
                            .hoverHighlight()
                            .disabled(store.isDeleting)
                    }
                    .font(.callout)
                    .padding(12)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                }
                overviewGrowthContent
                spaceAccountingContent
                Text("overviewXcodeHelp").font(.caption).foregroundStyle(.secondary)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var overviewScanControls: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("overviewQuickCheck").font(.title3.bold())
                Spacer()
                if store.overviewScanState != nil {
                    Button("cancel") { store.cancelOverviewScan() }
                        .hoverHighlight()
                } else {
                    Button("overviewStartCheck") {
                        store.startOverviewScan(categories: overviewScanSelection)
                    }
                    .buttonStyle(.borderedProminent)
                    .hoverHighlight()
                    .disabled(overviewScanSelection.isEmpty || !store.canStartOverviewScan)
                }
            }
            Text("overviewQuickCheckHelp").font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("overviewChooseChecks") {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())],
                          alignment: .leading, spacing: 7) {
                    ForEach(ScanCategory.allCases.filter { $0 != .overview }, id: \.self) { category in
                        Toggle(category == .developerCache ? L("overviewXcodeQuickLabel") : category.title,
                               isOn: Binding(
                            get: { overviewScanSelection.contains(category) },
                            set: { selected in
                                if selected { overviewScanSelection.insert(category) }
                                else { overviewScanSelection.remove(category) }
                            }))
                            .disabled(store.overviewScanState != nil)
                    }
                }
                .padding(.top, 6)
            }
            if let state = store.overviewScanState {
                ProgressView(value: Double(state.completed), total: Double(state.total))
                Text(String(format: L("overviewCheckingCategory"), state.completed + 1,
                            state.total, state.category.title))
                    .font(.callout)
                if let progress = state.progress {
                    Text(String(format: L("scanProgressCounts"), progress.processedFiles,
                                progress.processedDirectories, fileSize(progress.processedBytes)))
                        .font(.caption).foregroundStyle(.secondary)
                    Text(progress.currentPath).font(.caption.monospaced())
                        .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                }
            } else if let count = store.overviewScanCompletedCount {
                Text(String(format: L(store.overviewScanWasCancelled
                    ? "overviewCheckCancelled" : "overviewCheckComplete"), count))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    private var spaceAccountingContent: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("spaceAccountingTitle").font(.title3.bold())
            if let accounting = store.volumeAccountingSummary {
                Text(accounting.rootPath).font(.caption.monospaced())
                    .foregroundStyle(.secondary).textSelection(.enabled)
                if let date = accounting.scannedAt {
                    Text(String(format: L("spaceAccountingDate"), localizedDate(date)))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if accounting.isHistorical {
                    Text("spaceAccountingHistorical").font(.caption).foregroundStyle(.secondary)
                }
                switch accounting.result {
                case .folderOnly:
                    Text("spaceAccountingFolderOnly").foregroundStyle(.secondary)
                case .incomplete:
                    Text("spaceAccountingIncomplete").foregroundStyle(.orange)
                case let .compared(used, scanned, difference):
                    Text(String(format: L("spaceAccountingUsed"),
                                accounting.volumeName ?? accounting.rootPath, fileSize(used)))
                    Text(String(format: L("spaceAccountingScanned"), fileSize(scanned)))
                    Text(String(format: L(difference >= 0 ? "spaceAccountingGap" : "spaceAccountingOver"),
                                fileSize(abs(difference))))
                    if let reclaimable = accounting.systemReclaimableEstimate, reclaimable > 0 {
                        Text(String(format: L("spaceAccountingReclaimable"), fileSize(reclaimable)))
                    }
                    Text("spaceAccountingUnattributed")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("spaceAccountingCaveat").font(.caption).foregroundStyle(.secondary)
                }
                if accounting.omittedCount > 0 {
                    Text(String(format: L("omittedItemsCount"), accounting.omittedCount))
                        .foregroundStyle(.orange)
                }
                if !accounting.diagnostics.isEmpty {
                    DisclosureGroup(String(format: L("spaceAccountingReviewNotices"),
                                           accounting.diagnostics.count),
                                    isExpanded: $showingAccountingNotices) {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(accounting.diagnostics) { issue in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(localizedWarning(issue.detail)).textSelection(.enabled)
                                    Text(L("diagnosticHint_\(issue.kind.rawValue)"))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            if accounting.diagnostics.contains(where: { $0.kind == .unreadable }) {
                                Button("fullDiskAccess") { store.openFullDiskAccess() }
                                    .hoverHighlight()
                            }
                        }
                        .font(.caption)
                    }
                    .foregroundStyle(.orange)
                } else if !accounting.isHistorical {
                    Text("spaceAccountingNoNotices").font(.caption).foregroundStyle(.secondary)
                }
                if !accounting.excludedPaths.isEmpty {
                    DisclosureGroup(String(format: L("spaceAccountingReviewExclusions"),
                                           accounting.excludedPaths.count),
                                    isExpanded: $showingAccountingExclusions) {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(accounting.excludedPaths, id: \.self) { path in
                                Text(path).font(.caption.monospaced()).textSelection(.enabled)
                            }
                        }
                    }
                } else {
                    Text("spaceAccountingNoExclusions").font(.caption).foregroundStyle(.secondary)
                }
                if Set(accounting.excludedPaths) != Set(preferences.excludedPaths) {
                    Text("spaceAccountingExclusionsChanged")
                        .font(.caption).foregroundStyle(.orange)
                }
                HStack(spacing: 12) {
                    Button("spaceAccountingCheckExclusions") { openSettings() }
                        .hoverHighlight()
                    Button("spaceAccountingRescan") { store.rescanSpaceAccounting() }
                        .hoverHighlight()
                        .disabled(!store.canRescanSpaceAccounting)
                }
            } else {
                Text("spaceAccountingNoScan").foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    private var overviewReviewCandidates: [CleanupOverviewItem] {
        let query = overviewQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return store.cleanupOverview.candidates.filter { item in
            (overviewCategory == nil || item.category == overviewCategory) &&
            (reviewOperationFilter == nil || item.operation == reviewOperationFilter) &&
            (reviewRiskFilter == nil || item.risk == reviewRiskFilter) &&
            (query.isEmpty || item.path.localizedCaseInsensitiveContains(query) ||
                (item.displayName?.localizedCaseInsensitiveContains(query) ?? false))
        }
    }

    private var overviewReviewContent: some View {
        let candidates = overviewReviewCandidates
        let pageCount = max(1, (candidates.count + overviewItemsPerPage - 1) / overviewItemsPerPage)
        let page = min(overviewPage, pageCount - 1)
        return VStack(alignment: .leading, spacing: 10) {
            Text("overviewReviewTitle").font(.title3.bold())
            Text("overviewReviewHelp").font(.caption).foregroundStyle(.secondary)
            HStack {
                ClearableSearchField(placeholder: L("overviewReviewSearch"), text: $overviewQuery)
                    .frame(maxWidth: 360)
                Menu {
                    Button("overviewReviewAllCategories") { overviewCategory = nil }
                    ForEach(store.cleanupOverview.sections) { section in
                        Button(section.category.title) { overviewCategory = section.category }
                    }
                } label: {
                    Text(overviewCategory?.title ?? L("overviewReviewAllCategories"))
                }
                .hoverHighlight()
                Menu {
                    Button("overviewReviewAllOperations") { reviewOperationFilter = nil }
                    Button("overviewActionTrash") { reviewOperationFilter = .trash }
                    Button("overviewActionCloud") { reviewOperationFilter = .cloudEviction }
                    Button("overviewActionSimulator") { reviewOperationFilter = .simulator }
                } label: {
                    Text(reviewOperationFilter.map(overviewOperation) ?? L("overviewReviewAllOperations"))
                }
                .hoverHighlight()
                Menu {
                    Button("overviewReviewAllRisks") { reviewRiskFilter = nil }
                    Button("overviewRiskLow") { reviewRiskFilter = .low }
                    Button("overviewRiskReview") { reviewRiskFilter = .review }
                } label: {
                    Text(reviewRiskFilter.map(overviewRisk) ?? L("overviewReviewAllRisks"))
                }
                .hoverHighlight()
            }
            Text(String(format: L("overviewReviewCount"), candidates.count,
                        store.cleanupOverview.candidates.count))
                .font(.caption).foregroundStyle(.secondary)
            overviewPlanContent
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(Array(candidates.dropFirst(page * overviewItemsPerPage)
                    .prefix(overviewItemsPerPage).enumerated()), id: \.offset) { _, item in
                    HStack(spacing: 10) {
                        Toggle("", isOn: Binding(
                            get: { store.overviewPlan[item.path] != nil },
                            set: { store.selectOverviewCandidate(item, selected: $0) }))
                            .labelsHidden()
                            .disabled(!item.canExecute || store.isDeleting ||
                                      store.overviewScanState != nil)
                            .help(L(item.canExecute ? "overviewAddToPlan" : "overviewPlanUnavailable"))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.displayName ?? URL(fileURLWithPath: item.path).lastPathComponent)
                                .fontWeight(.medium).lineLimit(1)
                            Text(item.path).font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                            Text("\(item.category.title) · \(overviewOperation(item.operation)) · \(overviewRisk(item.risk))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Text(fileSize(item.estimatedBytes)).monospacedDigit()
                        Button("overviewOpenCategory") { store.reviewOverviewCandidate(item) }
                            .hoverHighlight()
                            .disabled(store.isDeleting)
                    }
                    .font(.callout)
                    .padding(10)
                    .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                }
            }
            if pageCount > 1 {
                HStack {
                    Button("previousPage") { overviewPage = max(0, page - 1) }
                        .hoverHighlight().disabled(page == 0)
                    Text(String(format: L("overviewReviewPage"), page + 1, pageCount))
                        .foregroundStyle(.secondary)
                    Button("nextPage") { overviewPage = min(pageCount - 1, page + 1) }
                        .hoverHighlight().disabled(page >= pageCount - 1)
                }
                .font(.caption)
            }
        }
    }

    private var overviewPlanContent: some View {
        let items = store.overviewPlanItems
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(String(format: L("overviewPlanSummary"), items.count,
                            fileSize(items.reduce(0) { $0 + $1.estimatedBytes })))
                    .fontWeight(.semibold)
                Spacer()
                Button("overviewClearPlan") { store.clearOverviewPlan() }
                    .hoverHighlight()
                    .disabled(items.isEmpty || store.isDeleting)
                Button("overviewReviewAndExecute") { showingOverviewPlanConfirmation = true }
                    .buttonStyle(.borderedProminent)
                    .hoverHighlight()
                    .disabled(!store.canExecuteOverviewPlan)
            }
            if items.isEmpty {
                Text("overviewPlanEmpty").font(.caption).foregroundStyle(.secondary)
            } else {
                DisclosureGroup("overviewPlanSelectedItems") {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(items, id: \.path) { item in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.displayName ?? URL(fileURLWithPath: item.path).lastPathComponent)
                                            .lineLimit(1)
                                        Text("\(item.category.title) · \(overviewOperation(item.operation)) · \(item.path)")
                                            .font(.caption).foregroundStyle(.secondary)
                                            .lineLimit(1).truncationMode(.middle)
                                    }
                                    Spacer()
                                    Text(fileSize(item.estimatedBytes)).monospacedDigit()
                                    Button {
                                        store.selectOverviewCandidate(item, selected: false)
                                    } label: {
                                        Label("overviewRemoveFromPlan", systemImage: "xmark.circle")
                                            .labelStyle(.iconOnly)
                                    }
                                    .hoverHighlight()
                                    .help(L("overviewRemoveFromPlan"))
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 180)
                }
                .font(.caption)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    private var overviewPlanConfirmationText: String {
        let items = store.overviewPlanItems
        let message = String(format: L("overviewPlanConfirmDetail"), items.count,
            fileSize(items.reduce(0) { $0 + $1.estimatedBytes }),
            items.filter { $0.operation == .trash }.count,
            items.filter { $0.operation == .cloudEviction }.count,
            items.filter { $0.operation == .simulator }.count)
        return message + (items.contains { $0.operation == .simulator }
                          ? "\n\n" + L("overviewPlanSimulatorWarning") : "")
    }

    private func overviewDiagnostics(_ diagnostics: [ScanDiagnostic]) -> some View {
        DisclosureGroup(String(format: L("overviewDiagnosticCount"), diagnostics.count)) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(diagnostics.enumerated()), id: \.offset) { _, issue in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(localizedWarning(issue.detail)).textSelection(.enabled)
                        Text(L("diagnosticHint_\(issue.kind.rawValue)"))
                            .foregroundStyle(.secondary)
                    }
                }
                if diagnostics.contains(where: { $0.kind == .unreadable }) {
                    Button("fullDiskAccess") { store.openFullDiskAccess() }
                        .hoverHighlight()
                }
            }
            .font(.caption)
        }
        .foregroundStyle(.orange)
    }

    private func overviewScopePaths(for category: ScanCategory) -> some View {
        let paths = store.scanScopePaths(for: category)
        return DisclosureGroup(String(format: L("overviewScopeCount"), paths.count)) {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(paths, id: \.self) { path in
                    Text(path).font(.caption.monospaced()).textSelection(.enabled)
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var overviewExcludedLocations: some View {
        let configured = AppPreferences.shared.excludedPaths
        return DisclosureGroup("overviewExcludedTitle") {
            VStack(alignment: .leading, spacing: 6) {
                Text("overviewExcludedHelp")
                ForEach(FileSafety.cloudManagedDirectoryPaths, id: \.self) { path in
                    Text(path).font(.caption.monospaced()).textSelection(.enabled)
                }
                Text("overviewTrashExcluded")
                if !configured.isEmpty {
                    Text("overviewConfiguredExclusions").fontWeight(.semibold)
                    ForEach(configured, id: \.self) { path in
                        Text(path).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
            }
            .font(.caption)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var overviewGrowthContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("spaceGrowthTitle").font(.title3.bold())
            if let error = store.spaceHistoryError {
                Text(String(format: L("spaceGrowthSaveFailed"), error)).foregroundStyle(.orange)
            }
            switch store.spaceGrowthComparison {
            case .noPrevious:
                Text("spaceGrowthNoPrevious").foregroundStyle(.secondary)
            case .sourcesChanged:
                Text("spaceGrowthSourcesChanged").foregroundStyle(.orange)
            case .comparable(let previousDate, let currentDate, let rootPath,
                             let previousTotal, let currentTotal, let sampledCount, let directoryCount,
                             let newSampleCount, let growth):
                Text(rootPath).font(.caption.monospaced()).textSelection(.enabled)
                Text(String(format: L("spaceGrowthPeriod"), localizedDate(previousDate),
                            localizedDate(currentDate)))
                    .font(.caption).foregroundStyle(.secondary)
                Text(String(format: L("spaceGrowthTotal"), fileSize(previousTotal), fileSize(currentTotal)))
                Text(String(format: L("spaceGrowthCoverage"), sampledCount, directoryCount))
                    .font(.caption).foregroundStyle(.secondary)
                if newSampleCount > 0 {
                    Text(String(format: L("spaceGrowthNewSampleCount"), newSampleCount))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if growth.isEmpty {
                    Text("spaceGrowthNoIncrease").foregroundStyle(.secondary)
                } else {
                    ForEach(Array(growth.prefix(20).enumerated()), id: \.offset) { _, item in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(URL(fileURLWithPath: item.path).lastPathComponent).fontWeight(.medium)
                                Text(item.path).font(.caption).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                            Text("+" + fileSize(item.increase))
                                .monospacedDigit()
                        }
                        .font(.callout)
                        .padding(8)
                        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
    }

    private func overviewOperation(_ operation: CleanupOverviewOperation) -> String {
        switch operation {
        case .trash: L("overviewActionTrash")
        case .cloudEviction: L("overviewActionCloud")
        case .simulator: L("overviewActionSimulator")
        }
    }

    private func overviewRisk(_ risk: RiskLevel) -> String {
        switch risk {
        case .low: L("overviewRiskLow")
        case .review: L("overviewRiskReview")
        case .protected: L("overviewRiskProtected")
        }
    }

    private func overviewMetric(_ title: LocalizedStringKey, bytes: Int64, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol).font(.callout.weight(.semibold))
            Text(fileSize(bytes)).font(.title2.monospacedDigit().bold())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
    }

    private var resultsContent: some View {
        VStack(spacing: 0) {
        List(selection: $previewSelection) {
            if store.category == .duplicates {
                let groups = store.visibleDuplicateGroups
                ForEach(Array(groups.enumerated().dropFirst(duplicateGroupPage * duplicateGroupsPerPage)
                    .prefix(duplicateGroupsPerPage)), id: \.offset) { _, group in
                    Section {
                        ForEach(group) { entry in resultRow(entry) }
                    } header: {
                        HStack {
                            Text(String(format: L("duplicateGroupSummary"), group.count,
                                        fileSize(group[0].estimatedBytes)))
                            Text(String(format: L("duplicateReclaimEstimate"),
                                        fileSize(Int64(group.filter(\.canDelete).count) * group[0].estimatedBytes)))
                                .foregroundStyle(.secondary)
                                .help(L("duplicateRetainedRule"))
                            Spacer()
                            Button("selectGroupCopies") { store.selectDuplicateGroup(group) }
                                .hoverHighlight()
                                .disabled(ScanResultGrouping.selectableIDs(in: group)
                                    .isSubset(of: store.selectedIDs) || store.isDeleting)
                            Button("clearGroupSelection") { store.clearDuplicateGroup(group) }
                                .hoverHighlight()
                                .disabled(!group.contains { store.selectedIDs.contains($0.id) } || store.isDeleting)
                            Button("ignoreDuplicateGroup") { store.ignoreDuplicateGroup(group) }
                                .hoverHighlight()
                                .disabled(store.isDeleting)
                        }
                    }
                }
            } else if store.category == .orphans {
                ForEach(OrphanReviewGroup.groups(store.visibleEntries,
                                                  selection: store.sortSelection)) { group in
                    Section {
                        ForEach(group.entries) { entry in resultRow(entry) }
                    } header: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(group.id).fontWeight(.semibold)
                                Text(String(format: L("orphanGroupSummary"), group.entries.count,
                                            fileSize(group.knownBytes), group.unknownCount,
                                            group.sourceNames.joined(separator: ", ")))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("orphanIgnoreIdentifier") { store.ignoreOrphanGroup(group) }
                                .hoverHighlight()
                                .disabled(store.isDeleting || store.isScanning)
                        }
                    }
                }
            } else if store.category == .uninstall && store.reviewedApplicationName != nil {
                Section("appBundleSection") {
                    ForEach(store.visibleEntries.filter { $0.isDirectory && $0.note != "appPossibleRelated" }) {
                        entry in resultRow(entry)
                    }
                }
                Section("appCacheSection") {
                    ForEach(store.visibleEntries.filter { !$0.isDirectory && $0.note != "appPossibleRelated" && isApplicationCache($0) }) {
                        entry in resultRow(entry)
                    }
                }
                Section("appDataSection") {
                    ForEach(store.visibleEntries.filter { !$0.isDirectory && $0.note != "appPossibleRelated" && !isApplicationCache($0) }) {
                        entry in resultRow(entry)
                    }
                }
                if store.visibleEntries.contains(where: { $0.note == "appPossibleRelated" }) {
                    Section("appPossibleRelatedSection") {
                        ForEach(store.visibleEntries.filter { $0.note == "appPossibleRelated" }) {
                            entry in resultRow(entry)
                        }
                    }
                }
            } else {
                ForEach(store.visibleEntries) { entry in resultRow(entry) }
            }
        }
        .listStyle(.inset)
        .id(store.category == .duplicates ? duplicateGroupPage : 0)
        .onKeyPress(.space) {
            guard let id = previewSelection,
                  let entry = store.visibleEntries.first(where: { $0.id == id }),
                  !entry.isDirectory else { return .ignored }
            previewURL = entry.url
            return .handled
        }
        if store.category == .duplicates {
            let groupCount = store.visibleDuplicateGroups.count
            let pageCount = (groupCount + duplicateGroupsPerPage - 1) / duplicateGroupsPerPage
            if pageCount > 1 {
                HStack(spacing: 12) {
                    Button("previousPage") { duplicateGroupPage -= 1 }
                        .hoverHighlight()
                        .disabled(duplicateGroupPage == 0)
                    Text(String(format: L("duplicatePageSummary"), duplicateGroupPage + 1, pageCount,
                                duplicateGroupPage * duplicateGroupsPerPage + 1,
                                min((duplicateGroupPage + 1) * duplicateGroupsPerPage, groupCount)))
                        .foregroundStyle(.secondary)
                    Menu("jumpToGroupRange") {
                        ForEach(0..<pageCount, id: \.self) { page in
                            Button(String(format: L("duplicateGroupRange"),
                                          page * duplicateGroupsPerPage + 1,
                                          min((page + 1) * duplicateGroupsPerPage, groupCount))) {
                                duplicateGroupPage = page
                            }
                        }
                    }
                    .hoverHighlight()
                    Button("nextPage") { duplicateGroupPage += 1 }
                        .hoverHighlight()
                        .disabled(duplicateGroupPage + 1 >= pageCount)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
        }
        }
    }

    private var cloudContent: some View {
        VStack(spacing: 0) {
            if store.isScanning {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("icloudScanning")
                    if let progress = store.scanProgress {
                        Text(progress.currentPath).font(.caption.monospaced())
                            .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Button("cancel") { store.cancel() }.hoverHighlight()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !store.hasScanned {
                ContentUnavailableView {
                    Label("icloud", systemImage: "icloud")
                } description: {
                    Text("icloudStartPrompt")
                } actions: {
                    scanButton
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.entries.isEmpty {
                ContentUnavailableView {
                    Label(store.warnings.isEmpty ? "icloudEmptyTitle" : "icloudUnavailableTitle",
                          systemImage: store.warnings.isEmpty ? "icloud" : "icloud.slash")
                } description: {
                    Text(store.warnings.isEmpty ? "icloudEmpty" : "icloudUnavailableDetail")
                } actions: {
                    scanButton
                    if !store.warnings.isEmpty {
                        Button("fullDiskAccess") { store.openFullDiskAccess() }.hoverHighlight()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 12) {
                    Button { store.cloudFolder = store.cloudFolder.deletingLastPathComponent() } label: {
                        Image(systemName: "chevron.left")
                    }
                    .hoverHighlight()
                    .disabled(store.cloudFolder == ICloudDrive.root || store.isDeleting)
                    Text(store.cloudFolder.path).font(.caption.monospaced())
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(String(format: L("icloudStatusSummary"),
                                store.cloudCurrentCount,
                                store.cloudRemoteCount,
                                fileSize(store.scanMetrics.allocatedBytes ?? 0)))
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 20).padding(.vertical, 8)
                if store.visibleEntries.isEmpty {
                    ContentUnavailableView(store.resultQuery.isEmpty ? "icloudFolderEmpty" : "noMatchingResults",
                                           systemImage: store.resultQuery.isEmpty ? "folder" : "magnifyingglass")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(Array(store.visibleEntries.dropFirst(cloudPage * cloudItemsPerPage)
                            .prefix(cloudItemsPerPage))) { entry in
                            cloudRow(entry)
                        }
                    }
                    .listStyle(.inset)
                    let pageCount = (store.visibleEntries.count + cloudItemsPerPage - 1) / cloudItemsPerPage
                    if pageCount > 1 {
                        HStack {
                            Button("previousPage") { cloudPage -= 1 }
                                .hoverHighlight().disabled(cloudPage == 0)
                            Text(String(format: L("icloudPage"), cloudPage + 1, pageCount))
                                .foregroundStyle(.secondary)
                            Button("nextPage") { cloudPage += 1 }
                                .hoverHighlight().disabled(cloudPage + 1 >= pageCount)
                        }
                        .padding(8)
                    }
                }
                HStack {
                    Text(String(format: L("icloudSelected"), store.selectedEntries.count,
                                fileSize(store.selectedAllocatedBytes ?? 0)))
                        .foregroundStyle(.secondary)
                    if store.hasHiddenSelection {
                        Button("icloudClearHiddenSelection") { store.selectedIDs = [] }
                            .buttonStyle(.link).hoverHighlight()
                    }
                    Spacer()
                    Button("icloudEvict") { showingCloudConfirmation = true }
                        .hoverHighlight()
                        .disabled(store.selectedEntries.isEmpty || store.hasHiddenSelection || store.isDeleting)
                }
                .padding(16).background(.bar)
            }
        }
    }

    private func cloudRow(_ entry: ScanEntry) -> some View {
        HStack(spacing: 10) {
            if entry.canDelete {
                Toggle("", isOn: Binding(get: { store.selectedIDs.contains(entry.id) }, set: { selected in
                    if selected { store.selectedIDs.insert(entry.id) }
                    else { store.selectedIDs.remove(entry.id) }
                }))
                .labelsHidden().disabled(store.isDeleting)
                .accessibilityLabel(entry.url.lastPathComponent)
            } else {
                Image(systemName: entry.isDirectory ? "folder" : "lock.fill")
                    .foregroundStyle(.secondary).frame(width: 22)
                    .help(L(entry.note))
            }
            Image(systemName: entry.isDirectory ? "folder" : "doc")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                if entry.isDirectory {
                    Button(entry.url.lastPathComponent) {
                        store.resultQuery = ""
                        store.cloudFolder = entry.url
                    }
                        .buttonStyle(.plain).hoverHighlight().disabled(store.isDeleting)
                } else {
                    Text(entry.url.lastPathComponent)
                }
                Text(entry.url.path).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                if !entry.isDirectory {
                    Text(Date(timeIntervalSince1970: Double(entry.stamp.modifiedSeconds)),
                         format: .dateTime.year().month().day().hour().minute())
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(L(entry.note)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !entry.isDirectory {
                VStack(alignment: .trailing) {
                    Text(fileSize(entry.estimatedBytes)).monospacedDigit()
                    Text(String(format: L("icloudLocalSize"), fileSize(entry.allocatedBytes ?? 0)))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Button { store.reveal(entry.url) } label: { Image(systemName: "folder") }
                .buttonStyle(.borderless).hoverHighlight()
                .help(L("revealInFinder"))
        }
    }

    private func resultRow(_ entry: ScanEntry) -> some View {
        HStack(spacing: 12) {
                if entry.canDelete {
                    Toggle("", isOn: Binding(get: { store.selectedIDs.contains(entry.id) }, set: { selected in
                        if selected { store.selectedIDs.insert(entry.id) } else { store.selectedIDs.remove(entry.id) }
                    }))
                    .labelsHidden()
                    .disabled(store.isDeleting)
                    .accessibilityLabel(entry.url.lastPathComponent)
                } else if store.category == .uninstall && entry.isDirectory &&
                            entry.note != "appPossibleRelated" &&
                            entry.directorySignature == nil && entry.risk != .protected {
                    Color.clear
                        .frame(width: 22)
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: "lock.fill")
                        .foregroundStyle(.secondary)
                        .frame(width: 22)
                        .help(L(selectionUnavailableReason(for: entry)))
                        .accessibilityLabel(L(selectionUnavailableReason(for: entry)))
                }
                Image(systemName: entry.isDirectory && store.category == .uninstall ? "desktopcomputer" :
                      entry.isDirectory ? "folder" : "doc")
                    .frame(width: 24)
                    .foregroundStyle(entry.canDelete ? .primary : .secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.url.lastPathComponent)
                        .fontWeight(.medium)
                        .foregroundStyle(entry.risk == .protected ? Color.secondary : Color.primary)
                        .lineLimit(1)
                    Text(entry.url.path).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                    Text(Date(timeIntervalSince1970: Double(entry.stamp.modifiedSeconds)),
                         format: .dateTime.year().month().day().hour().minute())
                        .font(.caption).foregroundStyle(.secondary)
                    Text(store.category == .uninstall && store.reviewedApplicationName != nil ?
                         L(entry.note == "appPossibleRelated" ? "appPossibleRelatedBasis" :
                           (entry.isDirectory ? "appBundleBasis" : "appExactMatchBasis")) : L(entry.note))
                        .font(.caption).foregroundStyle(entry.canDelete ? .orange : .secondary)
                }
                Spacer()
                if store.category == .uninstall && entry.isDirectory && entry.note != "appPossibleRelated" &&
                    entry.directorySignature == nil &&
                    entry.risk != .protected {
                    Button("reviewApp") { store.prepareApplication(entry) }
                        .hoverHighlight()
                        .disabled(store.isDeleting)
                }
                VStack(alignment: .trailing, spacing: 2) {
                    if entry.sizeIsKnown {
                        Text(fileSize(entry.estimatedBytes))
                            .font(.callout.monospacedDigit())
                        if let allocated = entry.allocatedBytes {
                            Text(String(format: L("allocatedSizeValue"), fileSize(allocated)))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .help(L("allocatedSizeHelp"))
                        }
                    } else {
                        Text("—").font(.callout).foregroundStyle(.secondary)
                    }
                }
                Button { inspectedEntry = entry } label: { Image(systemName: "info.circle") }
                    .buttonStyle(.borderless)
                    .help(L("cleanupBasis"))
                    .hoverHighlight()
                if !entry.isDirectory {
                    Button { previewURL = entry.url } label: { Image(systemName: "eye") }
                        .buttonStyle(.borderless)
                        .help(L("previewFile"))
                        .hoverHighlight()
                }
                Button { store.reveal(entry.url) } label: { Image(systemName: "folder") }
                    .buttonStyle(.borderless)
                    .help(L("showInFinder"))
                    .hoverHighlight()
        }
        .padding(.vertical, 4)
        .tag(entry.id)
        .contextMenu {
            Button("ignorePathNextScan") { preferences.addExclusion(entry.url) }
            Button("showInFinder") { store.reveal(entry.url) }
        }
    }

    private func isApplicationCache(_ entry: ScanEntry) -> Bool {
        entry.url.path.contains("/Library/Caches/") || entry.url.path.contains("/Library/Logs/")
    }

    private var spaceContent: some View {
        VStack(spacing: 0) {
            spaceAccountingContent.padding(.horizontal, 20).padding(.top, 10)
            HStack {
                Button {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
                        store.spaceFolder = store.spaceFolder?.deletingLastPathComponent()
                    }
                } label: {
                    Label("back", systemImage: "chevron.left")
                }
                .hoverHighlight()
                .disabled(store.spaceFolder == nil || store.spaceFolder?.path == store.root.path)
                Text((store.spaceFolder ?? store.root).path).font(.callout.monospaced())
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
            }
            .padding(.horizontal, 20).padding(.vertical, 10)
            Divider()
            SpacePieChartView(items: store.visibleSpaceChildren,
                              entranceDuration: spacePieHasAppeared ? 0.25 : 0.45,
                              onAppear: { spacePieHasAppeared = true },
                              onOpen: openSpaceItem)
                .id((store.spaceFolder ?? store.root).path)
            List(store.visibleSpaceChildren) { child in
                HStack {
                    Image(systemName: child.isFolder ? "folder.fill" : child.isOther ? "ellipsis" : "doc")
                        .foregroundStyle(child.isFolder ? .blue : .secondary)
                    Text(child.isOther ? L("otherFiles") : child.url.lastPathComponent)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(fileSize(child.bytes))
                        if let allocated = child.allocatedBytes {
                            Text(String(format: L("allocatedSizeValue"), fileSize(allocated)))
                                .font(.caption2)
                                .help(L("allocatedSizeHelp"))
                        }
                    }
                    .foregroundStyle(.secondary)
                    if child.isFolder {
                        Button { openSpaceItem(child) } label: { Image(systemName: "chevron.right") }
                            .buttonStyle(.borderless)
                            .hoverHighlight()
                    } else if !child.isOther {
                        Button { previewURL = child.url } label: { Image(systemName: "eye") }
                            .buttonStyle(.borderless)
                            .help(L("previewFile"))
                            .hoverHighlight()
                        Button { store.reveal(child.url) } label: { Image(systemName: "folder") }
                            .buttonStyle(.borderless)
                            .hoverHighlight()
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    private func openSpaceItem(_ item: SpaceItem) {
        if item.isFolder {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
                store.spaceFolder = item.url
            }
        } else if !item.isOther {
            previewURL = item.url
        }
    }

    private var warningsView: some View {
        DisclosureGroup(String(format: L("scanWarnings"), store.warnings.count)) {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(store.warnings, id: \.self) { warning in
                        Text(localizedWarning(warning)).font(.caption).textSelection(.enabled)
                    }
                    Button("fullDiskAccess") { store.openFullDiskAccess() }
                        .hoverHighlight()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 120)
        }
        .padding(12)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 20).padding(.bottom, 10)
    }

    private func localizedWarning(_ warning: String) -> String {
        if warning.hasPrefix("Cannot read ") {
            return warning.replacingOccurrences(of: "Cannot read ", with: L("cannotRead") + " ")
        }
        if warning.hasPrefix("Changed or unreadable: ") {
            return warning.replacingOccurrences(of: "Changed or unreadable: ", with: L("changedUnreadable") + " ")
        }
        return L(warning)
    }

    private var actionBar: some View {
        HStack {
            Text(String(format: L("selectedSummary"), store.selectedEntries.count,
                        fileSize(store.estimatedSelectedBytes)))
                .foregroundStyle(.secondary)
            if let allocated = store.selectedAllocatedBytes, !store.selectedEntries.isEmpty {
                Text(String(format: L("allocatedSizeValue"), fileSize(allocated)))
                    .foregroundStyle(.secondary)
                    .help(L("allocatedSizeHelp"))
            }
            if store.hasHiddenSelection {
                Button("reviewHiddenSelection") {
                    store.resultQuery = ""
                    store.resultFilter = .all
                }
                .buttonStyle(.link)
                .hoverHighlight()
            }
            Spacer()
            Button("moveToTrash") { pendingMode = .trash; showingConfirmation = true }
                .hoverHighlight()
                .disabled(store.selectedEntries.isEmpty || store.hasHiddenSelection ||
                          store.isDeleting || store.isScanning)
            if store.category != .downloads {
                Button("deletePermanently", role: .destructive) {
                    pendingMode = .permanent
                    showingConfirmation = true
                }
                .hoverHighlight()
                .disabled(store.selectedEntries.isEmpty || store.hasHiddenSelection ||
                          store.isDeleting || store.isScanning)
            }
        }
        .padding(16)
        .background(.bar)
    }

    private var resultsSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("operationResults").font(.title2.bold())
            Text(String(format: L("resultSummaryDetailed"),
                        store.results.filter { $0.status == .success }.count,
                        store.results.filter { $0.status == .skipped }.count,
                        store.results.filter { $0.status == .failed }.count))
            if let delta = store.lastAvailableSpaceDelta {
                Text(String(format: L("observedAvailableChange"),
                            delta >= 0 ? "+" : "-", fileSize(abs(delta))))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("observedAvailableHelp")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("observedAvailableUnavailable")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            List(store.results, id: \.url) { result in
                HStack {
                    Image(systemName: result.success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(result.success ? .green : .orange)
                    VStack(alignment: .leading) {
                        Text(result.url.lastPathComponent)
                        Text(result.url.path).font(.caption).foregroundStyle(.secondary)
                        if let operation = store.overviewResultOperations[result.url.path] {
                            Text(overviewOperation(operation))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Text(L(result.status == .success ? "resultSuccess" :
                           result.status == .skipped ? "resultSkipped" : "resultFailed"))
                        .font(.caption).foregroundStyle(.secondary)
                    Text(L(result.message)).font(.caption)
                }
            }
            Button("done") { store.showResults = false }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .hoverHighlight()
        }
        .padding(20)
        .frame(width: 650, height: 420)
    }

    private func inspectorMessage(for entry: ScanEntry) -> String {
        let modified = localizedDate(Date(timeIntervalSince1970: Double(entry.stamp.modifiedSeconds)))
        var lines = [entry.url.path,
                     "\(L("cleanupBasis")): \(reason(for: entry))"]
        if !(entry.category == .uninstall && entry.isDirectory &&
             entry.directorySignature == nil && entry.estimatedBytes == 0) {
            let size = !entry.sizeIsKnown ? L("notMeasured") :
                fileSize(entry.estimatedBytes)
            lines.append("\(L("estimated")): \(size)")
        }
        lines.append("\(L("modifiedAt")): \(modified)")
        if entry.category == .uninstall && entry.note != "appRunning" &&
            entry.note != "appPossibleRelated" && !entry.note.isEmpty {
            lines.append("\(L("bundleIdentifier")): \(entry.note)")
        }
        return lines.joined(separator: "\n")
    }

    private func reason(for entry: ScanEntry) -> String {
        switch entry.category {
        case .overview: L("overviewDescription")
        case .space: L("analysisOnly")
        case .large: L("reasonLarge")
        case .duplicates: L(entry.canDelete ? "reasonDuplicate" : "keepOriginal")
        case .downloads: L(entry.note)
        case .systemCache: L("reasonSystemCache")
        case .developerCache: L("reasonDeveloperCache")
        case .uninstall:
            if entry.note == "appPossibleRelated" { L("appPossibleRelatedBasis") }
            else if entry.risk == .protected { L("appRunning") }
            else if entry.isDirectory { L("reasonAppBundle") }
            else { L("reasonAppRelated") }
        case .orphans: L("reasonOrphanCandidate")
        case .icloud: L(entry.note)
        }
    }

    private func selectionUnavailableReason(for entry: ScanEntry) -> String {
        if entry.note == "downloadInProgress" { return "downloadInProgress" }
        if entry.category == .orphans { return "orphanCandidate" }
        if entry.note == "keepOriginal" { return "keepOriginal" }
        if entry.note == "appPossibleRelated" { return "appPossibleRelatedBasis" }
        if entry.risk == .protected { return "appRunning" }
        if entry.category == .uninstall { return "reviewApp" }
        return "protected"
    }

    private var historySheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("cleanupHistory").font(.title2.bold())
            if let error = store.historyError {
                Text(String(format: L("historySaveFailed"), error))
                    .foregroundStyle(.orange)
            }
            if let error = store.restoreError {
                Text(error).foregroundStyle(.orange)
            }
            if store.cleanupHistory.isEmpty {
                ContentUnavailableView("historyEmpty", systemImage: "clock")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(store.cleanupHistory) { record in
                        Section("\(localizedDate(record.date)) · \(L(record.category)) · \(L(record.mode == "trash" ? "moveToTrash" : "deletePermanently"))") {
                            ForEach(record.items) { item in
                                HStack {
                                    Image(systemName: item.success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                        .foregroundStyle(item.success ? .green : .orange)
                                    VStack(alignment: .leading) {
                                        Text(URL(fileURLWithPath: item.path).lastPathComponent)
                                        Text(item.path).font(.caption).foregroundStyle(.secondary)
                                            .lineLimit(1).truncationMode(.middle)
                                    }
                                    Spacer()
                                    Text(fileSize(item.estimatedBytes))
                                        .font(.caption).foregroundStyle(.secondary)
                                    Text(L(item.restoredAt == nil ? item.message : "restored"))
                                        .font(.caption)
                                    if item.message == "movedToTrash" && item.restoredAt == nil {
                                        Button("restore") {
                                            store.restoreHistoryItem(recordID: record.id, itemID: item.id)
                                        }
                                        .hoverHighlight()
                                        .disabled(!item.canRestore)
                                        .help(L(item.canRestore ? "restoreHelp" : "restoreUnavailable"))
                                    }
                                }
                            }
                        }
                    }
                }
            }
            Button("done") { store.showHistory = false }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .hoverHighlight()
        }
        .padding(20)
        .frame(width: 700, height: 480)
    }

    private func fileSize(_ bytes: Int64) -> String {
        bytes.formatted(.byteCount(style: .file).locale(preferences.language.locale))
    }

    private func localizedDate(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened)
            .locale(preferences.language.locale))
    }
}

struct ScanCompletionSummaryView: View {
    @EnvironmentObject private var store: CleanerStore
    @EnvironmentObject private var preferences: AppPreferences

    private var scope: String {
        switch store.category {
        case .overview: L("overview")
        case .space, .large, .duplicates: store.root.path
        case .downloads: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads").path
        case .systemCache: L("scanScopeCaches")
        case .developerCache:
            ([XcodeStorage.defaultDerivedDataRoot] + preferences.derivedDataRoots)
                .map(\.path).joined(separator: " · ")
        case .uninstall: L("scanScopeApps")
        case .orphans: L("scanScopeOrphans")
        case .icloud: ICloudDrive.root.path
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Label("scanSummaryTitle", systemImage: "checklist")
                    .font(.callout.weight(.semibold))
                Spacer()
                Text(store.hasPartialResults ? "partialResults" : "completeResults")
                    .foregroundStyle(store.hasPartialResults ? .orange : .secondary)
            }
            Text(String(format: L("scanSummaryScope"), scope))
                .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
            if store.category == .space {
                Text(String(format: L("scanSummarySpaceFiles"), store.summaryCount))
            } else if store.category == .icloud {
                Text(String(format: L("icloudScanSummary"), store.summaryCount,
                            store.entries.filter(\.canDelete).count))
            } else if store.category == .uninstall && store.reviewedApplicationName == nil {
                Text(String(format: L("scanSummaryApps"), store.entries.count))
            } else {
                Text(String(format: L("scanSummaryCounts"), store.entries.count,
                            store.entries.filter(\.canDelete).count))
            }
            if store.scanMetrics.omittedCount > 0 {
                Text(String(format: L("omittedItemsCount"), store.scanMetrics.omittedCount))
                    .foregroundStyle(.orange)
            }
            if !store.warnings.isEmpty {
                Text(String(format: L("scanSummaryWarnings"), store.warnings.count))
                    .foregroundStyle(.orange)
            }
            if !preferences.excludedPaths.isEmpty {
                Text(String(format: L("scanSummaryExclusions"), preferences.excludedPaths.count))
            }
            if store.category != .icloud {
                Text("cloudExcludedFromLocalScan").foregroundStyle(.secondary)
            }
            Text("scanSummaryEstimateHelp").foregroundStyle(.secondary)
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20).padding(.vertical, 10)
        .background(.quaternary.opacity(0.35))
    }
}

private struct SpacePieChartView: View {
    let items: [SpaceItem]
    let entranceDuration: Double
    let onAppear: () -> Void
    let onOpen: (SpaceItem) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.locale) private var locale
    @State private var revealProgress = 0.0
    @State private var hoveredID: String?

    private let colors: [Color] = [
        .blue, .teal, .orange, .purple, .pink, .green
    ]

    private var slices: [SpacePieSlice] { SpacePie.slices(items) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("spacePie").font(.headline)
                Spacer()
                Text("spacePieHint").font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 18) {
                Chart(Array(slices.enumerated()), id: \.element.id) { index, slice in
                    SectorMark(angle: .value(L("sortSize"), slice.bytes),
                               innerRadius: .ratio(0),
                               outerRadius: .ratio(hoveredID == slice.id ? 1 : 0.92),
                               angularInset: 1)
                        .foregroundStyle(color(for: slice, at: index))
                        .opacity(hoveredID == nil || hoveredID == slice.id ? 1 : 0.68)
                }
                .chartLegend(.hidden)
                .chartOverlay { _ in
                    GeometryReader { geometry in
                        Rectangle().fill(.clear).contentShape(Rectangle())
                            .onContinuousHover { phase in
                                switch phase {
                                case .active(let location):
                                    setHovered(slice(at: location, in: geometry.size)?.id)
                                case .ended:
                                    setHovered(nil)
                                }
                            }
                            .onTapGesture { location in
                                if let item = slice(at: location, in: geometry.size)?.item {
                                    onOpen(item)
                                }
                            }
                    }
                }
                .mask(PieRevealMask(progress: revealProgress))
                .frame(width: 220, height: 220)
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(slices.enumerated()), id: \.element.id) { index, slice in
                        let label = slice.item?.url.lastPathComponent ?? L("otherSpaceSlice")
                        let size = slice.bytes.formatted(.byteCount(style: .file).locale(locale))
                        let percentage = slice.fraction.formatted(
                            .percent.precision(.fractionLength(1)).locale(locale))
                        if let item = slice.item {
                            Button { onOpen(item) } label: {
                                legendRow(label: label, size: size, percentage: percentage,
                                          color: color(for: slice, at: index))
                            }
                            .buttonStyle(.plain)
                            .contentShape(Rectangle())
                            .hoverHighlight()
                            .onHover { setHovered($0 ? slice.id : nil) }
                            .help("\(label) · \(size) · \(percentage)")
                        } else {
                            legendRow(label: label, size: size, percentage: percentage,
                                      color: .gray)
                                .help("\(label) · \(size) · \(percentage)")
                        }
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 220)
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
        .onAppear {
            onAppear()
            if reduceMotion {
                revealProgress = 1
            } else {
                DispatchQueue.main.async {
                    withAnimation(.easeOut(duration: entranceDuration)) { revealProgress = 1 }
                }
            }
        }
        .onChange(of: reduceMotion) { _, isReduced in
            if isReduced { revealProgress = 1 }
        }
    }

    private func legendRow(label: String, size: String, percentage: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 10, height: 10)
            Text(label).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 3)
            Text(size).foregroundStyle(.secondary)
            Text(percentage).foregroundStyle(.secondary).frame(width: 48, alignment: .trailing)
        }
        .font(.caption)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private func color(for slice: SpacePieSlice, at index: Int) -> Color {
        if slice.isOther { return .gray }
        let individualIndex = slices.prefix(index).filter { !$0.isOther }.count
        return colors[individualIndex % colors.count]
    }

    private func setHovered(_ id: String?) {
        guard hoveredID != id else { return }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { hoveredID = id }
    }

    private func slice(at point: CGPoint, in size: CGSize) -> SpacePieSlice? {
        let x = point.x - size.width / 2
        let y = point.y - size.height / 2
        let radius = min(size.width, size.height) / 2
        guard hypot(x, y) <= radius else { return nil }
        let angle = atan2(x, -y)
        let fraction = (angle < 0 ? angle + 2 * .pi : angle) / (2 * .pi)
        return SpacePie.slice(at: fraction, in: slices)
    }
}

private struct PieRevealMask: Shape {
    var progress: Double
    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        guard progress < 1 else { return Path(rect) }
        guard progress > 0 else { return Path() }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = hypot(rect.width, rect.height)
        var path = Path()
        path.move(to: center)
        path.addArc(center: center, radius: radius,
                    startAngle: .degrees(-90), endAngle: .degrees(-90 + progress * 360),
                    clockwise: false)
        path.closeSubpath()
        return path
    }
}

struct ClearableSearchField: NSViewRepresentable {
    let placeholder: String
    @Binding var text: String

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = placeholder
        field.stringValue = text
        field.sendsSearchStringImmediately = true
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.searchChanged(_:))
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        field.placeholderString = placeholder
        context.coordinator.text = $text
        if field.stringValue != text { field.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>

        init(text: Binding<String>) { self.text = text }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            text.wrappedValue = field.stringValue
        }

        @objc func searchChanged(_ field: NSSearchField) {
            text.wrappedValue = field.stringValue
        }
    }
}
