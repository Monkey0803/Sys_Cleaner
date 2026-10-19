import AppKit
import SwiftUI

struct XcodeWorkspaceView: View {
    @EnvironmentObject private var store: CleanerStore
    @EnvironmentObject private var preferences: AppPreferences
    @State private var section: Section = .projects
    @State private var archives: [XcodeArchive] = []
    @State private var simulators: [XcodeSimulator] = []
    @State private var selectedSimulatorIDs = Set<String>()
    @State private var showingTrashConfirmation = false
    @State private var showingSimulatorConfirmation = false
    @State private var loadingExtras = false
    @State private var operationError: String?
    @State private var projectQuery = ""
    @State private var projectFilter: ProjectFilter = .all
    @State private var projectSort: ProjectSort = .size

    private enum Section: String, CaseIterable, Identifiable {
        case projects, archives, simulators
        var id: Self { self }
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
                    .disabled(store.isDeleting || loadingExtras)
            }
            .padding(20)
            Picker("xcodeSection", selection: $section) {
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

    private var projectsView: some View {
        VStack(spacing: 0) {
            HStack {
                Text("xcodeDerivedDataHelp").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("xcodeAddRoot") { chooseRoot() }
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
                            }
                            .padding(6).background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }.padding(.horizontal, 20)
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
        }
        .padding(.vertical, 6)
    }

    private var archivesView: some View {
        VStack(spacing: 0) {
            Text("xcodeArchivesReadOnly").font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(16)
            if archives.isEmpty {
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
                    }.padding(.vertical, 6)
                }
            }
        }
    }

    private var simulatorsView: some View {
        VStack(spacing: 0) {
            Text("xcodeSimulatorHelp").font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(16)
            if simulators.isEmpty {
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
                    .disabled(selectedSimulatorIDs.isEmpty)
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
        loadingExtras = true
        let result = await Task.detached(priority: .utility) { () -> ([XcodeArchive], [XcodeSimulator], String?) in
            let archives = XcodeStorage.archives()
            do { return (archives, try XcodeStorage.simulators(), nil) }
            catch { return (archives, [], error.localizedDescription) }
        }.value
        archives = result.0
        simulators = result.1
        operationError = result.2
        selectedSimulatorIDs.formIntersection(Set(simulators.filter(\.canDelete).map(\.id)))
        loadingExtras = false
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
