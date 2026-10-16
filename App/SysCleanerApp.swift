import AppKit
import SwiftUI

@main
struct SysCleanerApp: App {
    @StateObject private var store = CleanerStore()

    var body: some Scene {
        Window("Sys Cleaner", id: "main") {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 980, minHeight: 640)
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        MenuBarExtra("Sys Cleaner", systemImage: "externaldrive.fill") {
            MenuBarActions()
        }
    }
}

private struct MenuBarActions: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("openMainWindow") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Divider()
        Button("quitApp") {
            NSApp.terminate(nil)
        }
    }
}
