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
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                tabButton(.general, title: "settingsGeneral", symbol: "gearshape")
                tabButton(.logos, title: "settingsLogo", symbol: "app")
                tabButton(.about, title: "settingsAbout", symbol: "info.circle")
            }
            .padding(.top, 24)
            .padding(.bottom, 8)

            Divider()

            Group {
                switch selectedTab {
                case .general: general
                case .logos: logos
                case .about: about
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 600, height: 460)
    }

    private func tabButton(_ tab: SettingsTab, title: String, symbol: String) -> some View {
        let isSelected = selectedTab == tab
        return Button {
            selectedTab = tab
        } label: {
            VStack(spacing: 3) {
                Image(systemName: symbol)
                    .font(.system(size: 20))
                    .frame(height: 23)
                Text(L(title))
                    .font(.caption)
            }
            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            .frame(width: 72, height: 48)
            .background(isSelected ? Color.accentColor.opacity(0.08) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .accessibilityAddTraits(isSelected ? .isSelected : [])
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
            Text("settingsAppliesNow")
                .font(.caption)
                .foregroundStyle(.secondary)
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
