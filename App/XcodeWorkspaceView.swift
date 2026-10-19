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
    @State private var archiveWarnings: [String] = []
    @State private var deviceSupportWarnings: [String] = []
    @State private var runtimeError: String?
    @State private var simulatorInventoryError: String?
    @State private var archiveScan: InventoryScan = .notScanned
    @State private var simulatorScan: InventoryScan = .notScanned
    @State private var runtimeScan: InventoryScan = .notScanned
    @State private var deviceSupportScan: InventoryScan = .notScanned
    @State private var extraRefreshID = UUID()
    @State private var selectedSimulatorIDs = Set<String>()
    @State private var showingTrashConfirmation = false
    @State private var showingSimulatorConfirmation = false
    @State private var operationError: String?
    @State private var projectQuery = ""
    @State private var projectFilter: ProjectFilter = .all
    @State private var projectSort: ProjectSort = .size

    private enum Section: String, CaseIterable, Identifiable {
        case overview, projects, archives, simulators
        var id: Self { self }
    }

    private enum InventoryScan {
        case notScanned, scanning
        case complete(TimeInterval), partial(TimeInterval), unavailable(TimeInterval)

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
                    .disabled(store.isDeleting)
                    .hoverHighlight()
            }
            .padding(20)
            Picker("xcodeSection", selection: $section) {
                Text("xcodeOverview").tag(Section.overview)
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
        .alert("xcodeTrashConfirm", isPresented: $showingTrashConfirmation) {
            Button("moveToTrash", role: .destructive) { store.delete(.trash) }
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
    }

    private var overviewView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("xcodeOverviewExplain")
                    .font(.caption).foregroundStyle(.secondary)
                if store.isScanning { ProgressView("scanning") }
                overviewRow("xcodeProjects", count: store.entries.count,
                            bytes: store.entries.reduce(0) { $0 + $1.estimatedBytes },
                            status: store.isScanning ? L("scanning") : store.hasScanned
                                ? L(store.hasPartialResults ? "partialResults" : "completeResults")
                                : L("xcodeNotScanned"), isScanning: store.isScanning)
                overviewRow("xcodeArchives", count: archives.count,
                            bytes: archives.reduce(0) { $0 + $1.logicalBytes },
                            status: scanStatus(archiveScan), isScanning: archiveScan.isScanning)
                overviewRow("xcodeSimulators", count: simulators.count,
                            bytes: simulators.allSatisfy { $0.dataBytes != nil }
                                ? simulators.reduce(0) { $0 + ($1.dataBytes ?? 0) } : nil,
                            status: scanStatus(simulatorScan), isScanning: simulatorScan.isScanning)
                overviewRow("xcodeRuntimes", count: runtimes.count,
                            bytes: runtimes.allSatisfy { $0.logicalBytes != nil }
                                ? runtimes.reduce(0) { $0 + ($1.logicalBytes ?? 0) } : nil,
                            status: scanStatus(runtimeScan), isScanning: runtimeScan.isScanning)
                overviewRow("xcodeDeviceSupport", count: deviceSupport.count,
                            bytes: deviceSupport.reduce(0) { $0 + $1.logicalBytes },
                            status: scanStatus(deviceSupportScan), isScanning: deviceSupportScan.isScanning)
                HStack {
                    Text("xcodeOtherArtifacts")
                    Spacer()
                    Text("xcodeNotCovered").foregroundStyle(.secondary)
                }
                .font(.callout).padding(10)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                Text("xcodeOtherArtifactsHelp").font(.caption).foregroundStyle(.secondary)

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
                            }
                            Spacer()
                            Text(runtime.logicalBytes.map { bytes in
                                String(format: L("xcodeEstimatedSize"),
                                       ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                            } ?? L("notMeasured"))
                                .font(.caption).foregroundStyle(.secondary)
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
        case .notScanned, .partial, .unavailable:
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
        }
    }

    private func overviewRow(_ title: LocalizedStringKey, count: Int, bytes: Int64?,
                             status: String, isScanning: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout.weight(.semibold))
                Text(String(format: L("xcodeOverviewCount"), count))
                    .font(.caption).foregroundStyle(.secondary)
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
                                Button { preferences.removeDerivedDataRoot(root); store.invalidateScan(); store.scan() } label: {
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
                    .disabled(store.selectedEntries.isEmpty || store.isScanning || store.isDeleting)
                    .hoverHighlight()
            }
            .padding(16)
            .background(.bar)
        }
    }

    private func projectGroupRow(_ group: XcodeProjectGroup) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(projectName(group)).font(.headline)
                if let path = group.projectPath {
                    Text(path).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Text(String(format: L("xcodeBuildDirectories"), group.entries.count))
                    .font(.caption).foregroundStyle(.secondary)
                Text(String(format: L("xcodeLastActivity"), group.lastActivity.formatted()))
                    .font(.caption2).foregroundStyle(.secondary)
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
                    HStack(spacing: 12) {
                        Toggle("", isOn: Binding(get: { selectedSimulatorIDs.contains(device.id) }, set: { selected in
                            if selected { selectedSimulatorIDs.insert(device.id) }
                            else { selectedSimulatorIDs.remove(device.id) }
                        }))
                        .labelsHidden().disabled(!device.canDelete)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(device.name).font(.headline)
                            Text("\(device.runtimeName) · \(device.state)")
                                .font(.caption).foregroundStyle(.secondary)
                            if let date = device.lastUsed { Text(date.formatted()).font(.caption2).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        Text(device.dataBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
                             ?? L("notMeasured"))
                    }.padding(.vertical, 6)
                }
            }
            HStack {
                Spacer()
                Button("xcodeDeleteDevices", role: .destructive) { showingSimulatorConfirmation = true }
                    .disabled(selectedSimulatorIDs.isEmpty || simulatorScan.isScanning)
                    .hoverHighlight()
            }.padding(16).background(.bar)
        }
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
                store.invalidateScan()
                store.scan()
            } else {
                operationError = L("xcodeInvalidRoot")
            }
        }
    }

    private func refresh() {
        store.scan()
        Task { await refreshExtras() }
    }

    private func refreshExtras() async {
        let refreshID = UUID()
        extraRefreshID = refreshID
        archiveScan = .scanning
        simulatorScan = .scanning
        runtimeScan = .scanning
        deviceSupportScan = .scanning
        archives = []
        simulators = []
        runtimes = []
        deviceSupport = []
        archiveWarnings = []
        deviceSupportWarnings = []
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
                    archiveScan = inventory.isComplete ? .complete(seconds) : .partial(seconds)
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
                    deviceSupportScan = inventory.isComplete ? .complete(seconds) : .partial(seconds)
                }
            }
        }
    }

    private func deleteSelectedSimulators() {
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
        }
    }
}
