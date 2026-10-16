import AppKit
import SwiftUI

@main
struct SysCleanerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = CleanerStore()
    @StateObject private var preferences = AppPreferences.shared

    var body: some Scene {
        Window("Sys Cleaner", id: "main") {
            ContentView()
                .id(preferences.language)
                .environmentObject(store)
                .environmentObject(preferences)
                .environment(\.locale, preferences.language.locale)
                .frame(minWidth: 980, minHeight: 640)
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        Settings {
            SettingsView()
                .environmentObject(preferences)
                .environment(\.locale, preferences.language.locale)
        }

        MenuBarExtra {
            MenuBarActions()
                .environment(\.locale, preferences.language.locale)
        } label: {
            Image(nsImage: preferences.logo.menuBarImage)
                .renderingMode(.original)
                .accessibilityLabel("Sys Cleaner")
        }
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppPreferences.shared.applyIcon()
        AppPreferences.shared.applyAppearance()
        NSApp.servicesProvider = self
    }

    @objc(reviewApplication:userData:error:)
    func reviewApplication(_ pasteboard: NSPasteboard, userData: String?,
                           error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let files = (pasteboard.readObjects(forClasses: [NSURL.self],
                                            options: [.urlReadingFileURLsOnly: true]) ?? [])
            .compactMap { $0 as? URL }
            .filter { $0.isFileURL && $0.pathExtension.lowercased() == "app" }
        guard files.count == 1 else {
            error.pointee = L("finderSelectOneApp") as NSString
            return
        }
        FinderReviewBridge.shared.review(files[0])
    }
}

@MainActor
final class FinderReviewBridge {
    static let shared = FinderReviewBridge()
    private weak var store: CleanerStore?
    private var openMainWindow: (() -> Void)?
    private var pendingApp: URL?

    func connect(store: CleanerStore, openMainWindow: @escaping () -> Void) {
        self.store = store
        self.openMainWindow = openMainWindow
        processPending()
    }

    func review(_ app: URL) {
        pendingApp = app
        openMainWindow?()
        NSApp.activate(ignoringOtherApps: true)
        processPending()
    }

    private func processPending() {
        guard let app = pendingApp, let store, !store.isDeleting else { return }
        store.changeCategory(.uninstall)
        if store.isScanning { store.cancel() }
        store.openApplication(app)
        pendingApp = nil
    }
}

private struct MenuBarActions: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button("openMainWindow") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("settings") {
            openSettings()
            NSApp.activate(ignoringOtherApps: true)
        }
        Divider()
        Button("quitApp") {
            NSApp.terminate(nil)
        }
    }
}
