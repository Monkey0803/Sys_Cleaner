import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var preferences: AppPreferences
    @State private var selectedTab: SettingsTab = .general

    private enum SettingsTab {
        case general
        case logos
        case about
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            general
                .tabItem { Label("settingsGeneral", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            logos
                .tabItem { Label("settingsLogo", systemImage: "app") }
                .tag(SettingsTab.logos)
            about
                .tabItem { Label("settingsAbout", systemImage: "info.circle") }
                .tag(SettingsTab.about)
        }
        .padding(20)
        .frame(width: 640, height: 500)
    }

    private var general: some View {
        Form {
            Picker("settingsLanguage", selection: $preferences.language) {
                Text("languageSystem").tag(AppLanguage.system)
                Text("languageChinese").tag(AppLanguage.chinese)
                Text("languageEnglish").tag(AppLanguage.english)
            }
            Picker("settingsTheme", selection: $preferences.theme) {
                Text("themeSystem").tag(AppTheme.system)
                Text("themeDark").tag(AppTheme.dark)
                Text("themeLight").tag(AppTheme.light)
            }
            WorkspaceStatus(title: L("settingsAppliesNow"), symbol: "checkmark.circle")
            Section("settingsExclusions") {
                ForEach(preferences.excludedPaths, id: \.self) { path in
                    HStack {
                        Text(path).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button {
                            preferences.removeExclusion(path)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .help(L("removeExclusion"))
                        .hoverHighlight()
                    }
                }
                Button("addExclusion") {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = true
                    panel.canChooseDirectories = true
                    panel.allowsMultipleSelection = true
                    if panel.runModal() == .OK {
                        panel.urls.forEach(preferences.addExclusion)
                    }
                }
                .hoverHighlight()
                Text("exclusionsNextScan")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !preferences.ignoredDuplicateHashes.isEmpty {
                    Button(String(format: L("clearIgnoredDuplicateGroups"),
                                  preferences.ignoredDuplicateHashes.count)) {
                        preferences.clearIgnoredDuplicateGroups()
                    }
                    .hoverHighlight()
                }
            }
        }
        .formStyle(.grouped)
    }

    private var logos: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("logoDescription")
                .foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 3), spacing: 12) {
                ForEach(AppLogo.allCases) { logo in
                    Button { preferences.logo = logo } label: {
                        VStack(spacing: 6) {
                            if let image = logo.image {
                                Image(nsImage: image)
                                    .resizable()
                                    .interpolation(.high)
                                    .frame(width: 80, height: 80)
                            }
                            Text(L("logo_\(logo.rawValue)"))
                                .font(.callout)
                            Image(systemName: preferences.logo == logo ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(preferences.logo == logo ? Color.accentColor : Color.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(8)
                        .background(preferences.logo == logo ? Color.accentColor.opacity(0.12) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 12))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .hoverHighlight()
                    .accessibilityLabel(Text(L("logo_\(logo.rawValue)")))
                    .accessibilityAddTraits(preferences.logo == logo ? .isSelected : [])
                }
            }
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
        .padding(.bottom, 8)
    }

    private var about: some View {
        VStack(spacing: 12) {
            if let image = preferences.logo.image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 88, height: 88)
            }
            Text("Sys Cleaner").font(.title.bold())
            Text("aboutDescription")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 420)
            Text(versionText).font(.callout).foregroundStyle(.secondary)
            Divider().frame(width: 300)
            Text("aboutPrivacy").multilineTextAlignment(.center)
            Text("aboutLicense").font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.top, 30)
    }

    private var versionText: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "1.0.0"
        let build = info["CFBundleVersion"] as? String ?? "1"
        return String(format: L("aboutVersion"), version, build)
    }
}
