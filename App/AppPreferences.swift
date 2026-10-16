import AppKit
import SwiftUI

enum AppLanguage: String, CaseIterable, Identifiable {
    case system, chinese, english

    var id: String { rawValue }

    var locale: Locale {
        switch self {
        case .system: Locale.autoupdatingCurrent
        case .chinese: Locale(identifier: "zh-Hans")
        case .english: Locale(identifier: "en")
        }
    }

    var bundle: Bundle {
        let folder: String
        switch self {
        case .system: return .main
        case .chinese: folder = "zh-Hans"
        case .english: folder = "en"
        }
        guard let path = Bundle.main.path(forResource: folder, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return .main }
        return bundle
    }
}

enum AppTheme: String, CaseIterable, Identifiable {
    case system, dark, light

    var id: String { rawValue }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .dark: .dark
        case .light: .light
        }
    }
}

enum AppLogo: String, CaseIterable, Identifiable {
    case orbit, sweep, disk, layers, shield, spark

    var id: String { rawValue }
    var assetName: String { "Logo-\(rawValue.capitalized)" }

    var image: NSImage? { NSImage(named: NSImage.Name(assetName)) }

    var menuBarImage: NSImage {
        // MenuBarExtra uses the native image's size; a SwiftUI frame does not
        // shrink the 512-point asset before the status item measures it.
        let source = image ?? NSImage(systemSymbolName: "externaldrive.fill", accessibilityDescription: nil)
            ?? NSImage(size: NSSize(width: 18, height: 18))
        let size = NSSize(width: 18, height: 18)
        return NSImage(size: size, flipped: false) { rect in
            source.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
    }
}

@MainActor
final class AppPreferences: ObservableObject {
    static let shared = AppPreferences()
    static let languageKey = "AppLanguage"
    static let themeKey = "AppTheme"
    static let logoKey = "AppLogo"
    private static let sortKeyPrefix = "ScanSort."

    @Published var language: AppLanguage {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: Self.languageKey) }
    }
    @Published var theme: AppTheme {
        didSet { UserDefaults.standard.set(theme.rawValue, forKey: Self.themeKey) }
    }
    @Published var logo: AppLogo {
        didSet {
            UserDefaults.standard.set(logo.rawValue, forKey: Self.logoKey)
            applyIcon()
        }
    }

    private init() {
        let defaults = UserDefaults.standard
        language = AppLanguage(rawValue: defaults.string(forKey: Self.languageKey) ?? "") ?? .system
        theme = AppTheme(rawValue: defaults.string(forKey: Self.themeKey) ?? "") ?? .system
        logo = AppLogo(rawValue: defaults.string(forKey: Self.logoKey) ?? "") ?? .orbit
    }

    func applyIcon() {
        if let image = logo.image { NSApp.applicationIconImage = image }
    }

    func sortSelection(for category: ScanCategory) -> ScanSortSelection {
        let key = Self.sortKeyPrefix + category.rawValue
        let defaults = UserDefaults.standard
        let field = ScanSortField(rawValue: defaults.string(forKey: key + ".field") ?? "") ?? .size
        let direction = ScanSortDirection(rawValue: defaults.string(forKey: key + ".direction") ?? "") ?? .descending
        return ScanSortSelection(field: category == .space && field == .modified ? .size : field,
                                 direction: direction)
    }

    func setSortSelection(_ selection: ScanSortSelection, for category: ScanCategory) {
        let key = Self.sortKeyPrefix + category.rawValue
        UserDefaults.standard.set(selection.field.rawValue, forKey: key + ".field")
        UserDefaults.standard.set(selection.direction.rawValue, forKey: key + ".direction")
    }

}
