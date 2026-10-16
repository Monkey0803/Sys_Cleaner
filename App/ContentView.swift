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
    @State private var spacePieHasAppeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { store.category }, set: { store.changeCategory($0) })) {
                Section(L("explore")) {
                    categoryRow(.space)
                    categoryRow(.large)
                    categoryRow(.duplicates)
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
                header
                Divider()
                if store.isScanning {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text(L("scanStage_\(store.scanProgress?.stage.rawValue ?? "discovering")"))
                            .font(.headline)
                        if let progress = store.scanProgress {
                            Text(String(format: L("scanProgressCounts"), progress.processedFiles,
                                        progress.processedDirectories,
                                        ByteCountFormatter.string(fromByteCount: progress.processedBytes,
                                                                  countStyle: .file)))
                                .foregroundStyle(.secondary)
                            Text(progress.currentPath)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: 440)
                        }
                        Button("cancel") { store.cancel() }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if !store.hasScanned && store.entries.isEmpty && store.spaceItems.isEmpty {
                    ContentUnavailableView {
                        Label(store.category.title, systemImage: store.category.symbol)
                    } description: {
                        Text("startPrompt")
                    } actions: {
                        scanButton
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if store.entries.isEmpty && store.spaceItems.isEmpty {
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
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if store.category == .space {
                    spaceContent
                } else {
                    resultsContent
                }
                if !store.warnings.isEmpty { warningsView }
                if store.category != .space && store.category != .orphans { actionBar }
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
                }
                ToolbarItem(placement: .automatic) {
                    Button { openSettings() } label: { Label("settings", systemImage: "gearshape") }
                        .help(L("settings"))
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
                            ByteCountFormatter.string(fromByteCount: store.estimatedSelectedBytes, countStyle: .file)))
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
                        .disabled(store.isDeleting)
                        .padding(.bottom, 4)
                    }
                    Text(store.reviewedApplicationName ?? store.category.title).font(.largeTitle.bold())
                    Text(descriptionKey).foregroundStyle(.secondary)
                }
                Spacer()
                if store.hasScanned && !store.isScanning &&
                    (store.category == .space ? !store.spaceItems.isEmpty : !store.entries.isEmpty) {
                    sortMenu
                }
                if store.reviewedApplicationName == nil && store.hasScanned && !store.isScanning &&
                    (store.category == .space ? !store.spaceItems.isEmpty : !store.visibleEntries.isEmpty) {
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
                }
                .padding(10)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            }
            if store.category == .large {
                HStack {
                    Picker("minimumSize", selection: $store.minimumMB) {
                        Text("100 MB").tag(100)
                        Text("500 MB").tag(500)
                        Text("1 GB").tag(1024)
                    }
                    .frame(width: 220)
                    Picker("olderThan", selection: $store.olderThanDays) {
                        Text("anyTime").tag(0)
                        Text("30 days").tag(30)
                        Text("180 days").tag(180)
                    }
                    .frame(width: 220)
                    Spacer()
                }
            }
            if store.category != .space {
                HStack {
                    TextField(store.category == .uninstall && store.reviewedApplicationName == nil ?
                              "searchApps" : "searchResults", text: $store.resultQuery)
                        .textFieldStyle(.roundedBorder)
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
                    .disabled(store.isScanning)
                    if store.hasScanned && (!store.resultQuery.isEmpty || store.resultFilter != .all) {
                        Text(String(format: L("visibleResultCount"), store.visibleEntries.count,
                                    store.entries.count))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if store.category == .uninstall && store.reviewedApplicationName == nil {
                        Button("chooseApp") { store.chooseApplication() }
                            .disabled(store.isScanning || store.isDeleting)
                        Text("dropAppHint").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            HStack(spacing: 12) {
                Label(String(format: L("itemsCount"), store.summaryCount), systemImage: "doc")
                Label(ByteCountFormatter.string(fromByteCount: store.summaryBytes,
                                                countStyle: .file), systemImage: "internaldrive")
                Text(store.category == .uninstall && store.reviewedApplicationName == nil ?
                     (store.summaryBytes > 0 ? "reviewedAppSizes" : "appSizesOnReview") : "estimated")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .padding(20)
    }

    private var descriptionKey: LocalizedStringKey {
        switch store.category {
        case .space: "spaceDescription"
        case .large: "largeDescription"
        case .duplicates: "duplicatesDescription"
        case .systemCache: "systemCacheDescription"
        case .developerCache: "developerCacheDescription"
        case .uninstall: "uninstallDescription"
        case .orphans: "orphansDescription"
        }
    }

    private var scanButton: some View {
        Button(store.hasScanned ? L("scanAgain") : L("startScan")) {
            if store.category == .space { spacePieHasAppeared = false }
            store.scan()
        }
            .buttonStyle(.borderedProminent)
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
        .disabled(store.isDeleting)
        .help(L("sort"))
    }

    private var resultsContent: some View {
        List {
            if store.category == .duplicates {
                ForEach(Array(store.visibleDuplicateGroups.enumerated()), id: \.offset) { _, group in
                    Section {
                        ForEach(group) { entry in resultRow(entry) }
                    } header: {
                        HStack {
                            Text(String(format: L("duplicateGroupSummary"), group.count,
                                        ByteCountFormatter.string(fromByteCount: group[0].estimatedBytes,
                                                                  countStyle: .file)))
                            Spacer()
                            Button("selectGroupCopies") { store.selectDuplicateGroup(group) }
                                .disabled(ScanResultGrouping.selectableIDs(in: group)
                                    .isSubset(of: store.selectedIDs) || store.isDeleting)
                            Button("clearGroupSelection") { store.clearDuplicateGroup(group) }
                                .disabled(!group.contains { store.selectedIDs.contains($0.id) } || store.isDeleting)
                        }
                    }
                }
            } else {
                ForEach(store.visibleEntries) { entry in resultRow(entry) }
            }
        }
        .listStyle(.inset)
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
                    Text(L(entry.note)).font(.caption).foregroundStyle(entry.canDelete ? .orange : .secondary)
                }
                Spacer()
                if store.category == .uninstall && entry.isDirectory && entry.directorySignature == nil &&
                    entry.risk != .protected {
                    Button("reviewApp") { store.prepareApplication(entry) }
                        .disabled(store.isDeleting)
                }
                if !entry.sizeIsKnown {
                    Text("—").font(.callout).foregroundStyle(.secondary)
                } else if entry.estimatedBytes > 0 || store.category != .uninstall || entry.directorySignature != nil {
                    Text(ByteCountFormatter.string(fromByteCount: entry.estimatedBytes, countStyle: .file))
                        .font(.callout.monospacedDigit())
                } else {
                    Text("—").font(.callout).foregroundStyle(.secondary)
                }
                Button { inspectedEntry = entry } label: { Image(systemName: "info.circle") }
                    .buttonStyle(.borderless)
                    .help(L("cleanupBasis"))
                Button { store.reveal(entry.url) } label: { Image(systemName: "folder") }
                    .buttonStyle(.borderless)
                    .help(L("showInFinder"))
        }
        .padding(.vertical, 4)
    }

    private var spaceContent: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
                        store.spaceFolder = store.spaceFolder?.deletingLastPathComponent()
                    }
                } label: {
                    Label("back", systemImage: "chevron.left")
                }
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
                    Text(ByteCountFormatter.string(fromByteCount: child.bytes, countStyle: .file))
                        .foregroundStyle(.secondary)
                    if child.isFolder {
                        Button { openSpaceItem(child) } label: { Image(systemName: "chevron.right") }
                            .buttonStyle(.borderless)
                    } else if !child.isOther {
                        Button { previewURL = child.url } label: { Image(systemName: "eye") }
                            .buttonStyle(.borderless)
                            .help(L("previewFile"))
                        Button { store.reveal(child.url) } label: { Image(systemName: "folder") }
                            .buttonStyle(.borderless)
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
                        ByteCountFormatter.string(fromByteCount: store.estimatedSelectedBytes, countStyle: .file)))
                .foregroundStyle(.secondary)
            Spacer()
            Button("moveToTrash") { pendingMode = .trash; showingConfirmation = true }
                .disabled(store.selectedEntries.isEmpty || store.isDeleting || store.isScanning)
            Button("deletePermanently", role: .destructive) {
                pendingMode = .permanent
                showingConfirmation = true
            }
            .disabled(store.selectedEntries.isEmpty || store.isDeleting || store.isScanning)
        }
        .padding(16)
        .background(.bar)
    }

    private var resultsSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("operationResults").font(.title2.bold())
            Text(String(format: L("resultSummary"), store.results.filter(\.success).count,
                        store.results.filter { !$0.success }.count))
            List(store.results, id: \.url) { result in
                HStack {
                    Image(systemName: result.success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(result.success ? .green : .orange)
                    VStack(alignment: .leading) {
                        Text(result.url.lastPathComponent)
                        Text(result.url.path).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(L(result.message)).font(.caption)
                }
            }
            Button("done") { store.showResults = false }
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(20)
        .frame(width: 650, height: 420)
    }

    private func inspectorMessage(for entry: ScanEntry) -> String {
        let modified = Date(timeIntervalSince1970: Double(entry.stamp.modifiedSeconds))
            .formatted(date: .abbreviated, time: .shortened)
        var lines = [entry.url.path,
                     "\(L("cleanupBasis")): \(reason(for: entry))"]
        if !(entry.category == .uninstall && entry.isDirectory &&
             entry.directorySignature == nil && entry.estimatedBytes == 0) {
            let size = !entry.sizeIsKnown ? L("notMeasured") :
                ByteCountFormatter.string(fromByteCount: entry.estimatedBytes, countStyle: .file)
            lines.append("\(L("estimated")): \(size)")
        }
        lines.append("\(L("modifiedAt")): \(modified)")
        if entry.category == .uninstall && entry.note != "appRunning" && !entry.note.isEmpty {
            lines.append("\(L("bundleIdentifier")): \(entry.note)")
        }
        return lines.joined(separator: "\n")
    }

    private func reason(for entry: ScanEntry) -> String {
        switch entry.category {
        case .space: L("analysisOnly")
        case .large: L("reasonLarge")
        case .duplicates: L(entry.canDelete ? "reasonDuplicate" : "keepOriginal")
        case .systemCache: L("reasonSystemCache")
        case .developerCache: L("reasonDeveloperCache")
        case .uninstall:
            if entry.risk == .protected { L("appRunning") }
            else if entry.isDirectory { L("reasonAppBundle") }
            else { L("reasonAppRelated") }
        case .orphans: L("reasonOrphanCandidate")
        }
    }

    private func selectionUnavailableReason(for entry: ScanEntry) -> String {
        if entry.category == .orphans { return "orphanCandidate" }
        if entry.note == "keepOriginal" { return "keepOriginal" }
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
                        Section("\(record.date.formatted(date: .abbreviated, time: .shortened)) · \(L(record.category)) · \(L(record.mode == "trash" ? "moveToTrash" : "deletePermanently"))") {
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
                                    Text(ByteCountFormatter.string(fromByteCount: item.estimatedBytes,
                                                                   countStyle: .file))
                                        .font(.caption).foregroundStyle(.secondary)
                                    Text(L(item.restoredAt == nil ? item.message : "restored"))
                                        .font(.caption)
                                    if item.message == "movedToTrash" && item.restoredAt == nil {
                                        Button("restore") {
                                            store.restoreHistoryItem(recordID: record.id, itemID: item.id)
                                        }
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
        }
        .padding(20)
        .frame(width: 700, height: 480)
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
