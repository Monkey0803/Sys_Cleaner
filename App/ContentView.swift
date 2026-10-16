import AppKit
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
                } else if (store.entries.isEmpty && store.spaceItems.isEmpty) ||
                            (store.category == .uninstall && store.visibleEntries.isEmpty) {
                    ContentUnavailableView {
                        Label("noResults", systemImage: "checkmark.circle")
                    } description: {
                        Text("noResultsDetail")
                    } actions: {
                        scanButton
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
            .sheet(item: $inspectedEntry) { entry in entryInspector(entry) }
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
            if store.category == .uninstall && store.reviewedApplicationName == nil {
                HStack {
                    TextField("searchApps", text: $store.appQuery)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 360)
                    Button("chooseApp") { store.chooseApplication() }
                        .disabled(store.isScanning || store.isDeleting)
                    Text("dropAppHint").font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 12) {
                Label(String(format: L("itemsCount"), store.summaryCount), systemImage: "doc")
                Label(ByteCountFormatter.string(fromByteCount: store.summaryBytes,
                                                countStyle: .file), systemImage: "internaldrive")
                Text(store.category == .orphans ? "knownFileSize" : "estimated")
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
        Button(store.hasScanned ? L("scanAgain") : L("startScan")) { store.scan() }
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
        List(store.visibleEntries) { entry in
            HStack(spacing: 12) {
                if entry.canDelete {
                    Toggle("", isOn: Binding(get: { store.selectedIDs.contains(entry.id) }, set: { selected in
                        if selected { store.selectedIDs.insert(entry.id) } else { store.selectedIDs.remove(entry.id) }
                    }))
                    .labelsHidden()
                    .disabled(store.isDeleting)
                    .accessibilityLabel(entry.url.lastPathComponent)
                } else {
                    Image(systemName: "lock.fill")
                        .foregroundStyle(.secondary)
                        .frame(width: 22)
                        .help(L(selectionUnavailableReason(for: entry)))
                        .accessibilityLabel(L(selectionUnavailableReason(for: entry)))
                }
                Image(systemName: entry.isDirectory ? "app" : "doc")
                    .frame(width: 24)
                    .foregroundStyle(entry.canDelete ? .primary : .secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.url.lastPathComponent).fontWeight(.medium).lineLimit(1)
                    Text(entry.url.path).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                    Text(Date(timeIntervalSince1970: Double(entry.stamp.modifiedSeconds)),
                         format: .dateTime.year().month().day().hour().minute())
                        .font(.caption).foregroundStyle(.secondary)
                    Text(L(entry.note)).font(.caption).foregroundStyle(entry.canDelete ? .orange : .secondary)
                }
                Spacer()
                if store.category == .uninstall && entry.isDirectory && entry.directorySignature == nil {
                    if entry.risk != .protected {
                        Button("reviewApp") { store.prepareApplication(entry) }
                    }
                }
                if store.category == .orphans && entry.isDirectory {
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
        .listStyle(.inset)
    }

    private var spaceContent: some View {
        VStack(spacing: 0) {
            HStack {
                Button { store.spaceFolder?.deleteLastPathComponent() } label: {
                    Label("back", systemImage: "chevron.left")
                }
                .disabled(store.spaceFolder == nil || store.spaceFolder?.path == store.root.path)
                Text((store.spaceFolder ?? store.root).path).font(.callout.monospaced())
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
            }
            .padding(.horizontal, 20).padding(.vertical, 10)
            Divider()
            spaceMap
            List(store.visibleSpaceChildren) { child in
                HStack {
                    Image(systemName: child.isFolder ? "folder.fill" : child.isOther ? "ellipsis" : "doc")
                        .foregroundStyle(child.isFolder ? .blue : .secondary)
                    Text(child.isOther ? L("otherFiles") : child.url.lastPathComponent)
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: child.bytes, countStyle: .file))
                        .foregroundStyle(.secondary)
                    if child.isFolder {
                        Button { store.spaceFolder = child.url } label: { Image(systemName: "chevron.right") }
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

    private var spaceMap: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("spaceMap").font(.headline)
                Spacer()
                Text("spaceMapHint").font(.caption).foregroundStyle(.secondary)
            }
            GeometryReader { geometry in
                let cells = SpaceTreemap.layout(store.visibleSpaceChildren, in: geometry.size)
                ZStack(alignment: .topLeading) {
                    ForEach(Array(cells.enumerated()), id: \.element.id) { index, cell in
                        let name = cell.item.map { $0.isOther ? L("otherFiles") : $0.url.lastPathComponent }
                            ?? L("remainingSpaceItems")
                        let size = ByteCountFormatter.string(fromByteCount: cell.bytes, countStyle: .file)
                        Button {
                            guard let item = cell.item else { return }
                            if item.isFolder { store.spaceFolder = item.url }
                            else if !item.isOther { previewURL = item.url }
                        } label: {
                            RoundedRectangle(cornerRadius: 5)
                                .fill(cell.item == nil || cell.item?.isOther == true ? Color.gray.opacity(0.65) :
                                      Color(hue: (0.53 + Double(index) * 0.073)
                                        .truncatingRemainder(dividingBy: 1),
                                            saturation: 0.72, brightness: 0.62))
                                .overlay(alignment: .topLeading) {
                                    if cell.frame.width > 75 && cell.frame.height > 44 {
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(name).font(.caption.bold()).lineLimit(1)
                                            Text(size).font(.caption2).opacity(0.85)
                                        }
                                        .foregroundStyle(.white)
                                        .padding(8)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                        .disabled(cell.item == nil || cell.item?.isOther == true)
                        .help("\(name) · \(size)")
                        .accessibilityLabel("\(name), \(size)")
                        .frame(width: max(0, cell.frame.width - 2), height: max(0, cell.frame.height - 2))
                        .position(x: cell.frame.midX, y: cell.frame.midY)
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
            .frame(height: 240)
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
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

    private func entryInspector(_ entry: ScanEntry) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(entry.url.lastPathComponent).font(.title2.bold())
            Text(entry.url.path).font(.callout.monospaced()).textSelection(.enabled)
            Divider()
            LabeledContent("cleanupBasis", value: reason(for: entry))
            LabeledContent("estimated", value: entry.category == .orphans && entry.isDirectory ?
                           L("notMeasured") : ByteCountFormatter.string(
                            fromByteCount: entry.estimatedBytes, countStyle: .file))
            LabeledContent("modifiedAt", value: Date(timeIntervalSince1970: Double(entry.stamp.modifiedSeconds))
                .formatted(date: .abbreviated, time: .shortened))
            if !entry.note.isEmpty && entry.category == .uninstall {
                LabeledContent("bundleIdentifier", value: entry.note)
            }
            Text("reviewCaveat").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("done") { inspectedEntry = nil }.frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(24)
        .frame(width: 560, height: 320)
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
