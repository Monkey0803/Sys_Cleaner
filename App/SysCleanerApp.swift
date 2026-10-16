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
                .preferredColorScheme(preferences.theme.colorScheme)
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
                .preferredColorScheme(preferences.theme.colorScheme)
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
