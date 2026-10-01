import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if AppState.isSelfTest {
            Task { @MainActor in
                if let model = ProcessInfo.processInfo.environment["MP_TEST_MODEL"] {
                    await SelfTest.runModel(AppState.shared, needle: model)
                } else {
                    await SelfTest.run(AppState.shared)
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            AppState.shared.saveSessions()
            AppState.shared.stopServer()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct ModelPlaygroundApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @State private var state = AppState.shared

    var body: some Scene {
        WindowGroup("Model Playground") {
            ContentView()
                .environment(state)
                .frame(minWidth: 1000, minHeight: 660)
                .task { if !AppState.isSelfTest { await state.boot() } }
        }
        .defaultSize(width: 1280, height: 820)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Chat") { state.newChat() }.keyboardShortcut("n")
            }
            CommandMenu("Model") {
                Button("Compare Models") { state.sidebarSelection = .compare }.keyboardShortcut("k")
                Button("Benchmarks") { state.sidebarSelection = .benchmarks }.keyboardShortcut("u")
                Button("Leaderboard") { state.sidebarSelection = .leaderboard }.keyboardShortcut("b")
                Button("Model Library") { state.sidebarSelection = .models }.keyboardShortcut("l")
                Divider()
                Button("Stop Generating") { state.stopGenerating(); state.stopCompare(); state.stopBenchmarks() }.keyboardShortcut(".")
                Button("Unload Model from Memory") { Task { await state.api.unload(); await state.refreshModels() } }
                Button("Restart Engine") { Task { await state.restartServer() } }
            }
        }

        Settings {
            SettingsView()
                .environment(state)
                .frame(width: 640, height: 560)
        }
    }
}
