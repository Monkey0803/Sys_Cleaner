import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: CleanerStore
    @Environment(\.openSettings) private var openSettings
    @State private var pendingMode: DeleteMode = .trash
    @State private var showingConfirmation = false

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
                        Text("scanning")
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
                if store.category != .space { actionBar }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .navigationTitle(store.category.title)
            .toolbar {
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
        }
        .onChange(of: store.minimumMB) { _, _ in store.invalidateScan() }
        .onChange(of: store.olderThanDays) { _, _ in store.invalidateScan() }
    }

    private func categoryRow(_ category: ScanCategory) -> some View {
        Label(category.title, systemImage: category.symbol).tag(category)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(store.category.title).font(.largeTitle.bold())
                    Text(descriptionKey).foregroundStyle(.secondary)
                }
                Spacer()
                if store.hasScanned && !store.isScanning &&
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
            if store.category == .uninstall {
                TextField("searchApps", text: $store.appQuery)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 360)
            }
            HStack(spacing: 12) {
                Label(String(format: L("itemsCount"), store.summaryCount), systemImage: "doc")
                Label(ByteCountFormatter.string(fromByteCount: store.summaryBytes,
                                                countStyle: .file), systemImage: "internaldrive")
                Text("estimated").foregroundStyle(.secondary)
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
        }
    }

    private var scanButton: some View {
        Button(store.hasScanned ? L("scanAgain") : L("startScan")) { store.scan() }
            .buttonStyle(.borderedProminent)
            .disabled(store.isScanning || store.isDeleting)
    }

    private var resultsContent: some View {
        List(store.visibleEntries) { entry in
            HStack(spacing: 12) {
                Toggle("", isOn: Binding(get: { store.selectedIDs.contains(entry.id) }, set: { selected in
                    if selected { store.selectedIDs.insert(entry.id) } else { store.selectedIDs.remove(entry.id) }
                }))
                .labelsHidden()
                .disabled(!entry.canDelete || store.isDeleting)
                Image(systemName: entry.isDirectory ? "app" : "doc")
                    .frame(width: 24)
                    .foregroundStyle(entry.canDelete ? .primary : .secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.url.lastPathComponent).fontWeight(.medium).lineLimit(1)
                    Text(entry.url.path).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                    Text(L(entry.note)).font(.caption).foregroundStyle(entry.canDelete ? .orange : .secondary)
                }
                Spacer()
                if store.category == .uninstall && entry.isDirectory && entry.directorySignature == nil {
                    if entry.risk == .protected {
                        EmptyView()
                    } else {
                        Button("reviewApp") { store.prepareApplication(entry) }
                    }
                } else {
                    Text(ByteCountFormatter.string(fromByteCount: entry.estimatedBytes, countStyle: .file))
                        .font(.callout.monospacedDigit())
                }
                Button { store.reveal(entry.url) } label: { Image(systemName: "folder") }
                    .buttonStyle(.borderless)
                    .help(L("showInFinder"))
            }
            .padding(.vertical, 4)
        }
        .listStyle(.inset)
    }

    private var spaceChildren: [SpaceItem] {
        let base = (store.spaceFolder ?? store.root).standardizedFileURL
        return store.spaceItems.filter { $0.parent.path == base.path }.sorted { $0.bytes > $1.bytes }
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
            List(spaceChildren) { child in
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
                        Button { store.reveal(child.url) } label: { Image(systemName: "folder") }
                            .buttonStyle(.borderless)
                    }
                }
            }
            .listStyle(.inset)
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
}
