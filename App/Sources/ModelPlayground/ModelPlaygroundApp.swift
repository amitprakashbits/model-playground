import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // macOS restores the last window size; if an earlier version left it taller than the
        // screen, the message box ends up off-screen. Pull every window back inside the screen.
        for delay in [0.3, 1.0, 2.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { Self.fitWindowsToScreen() }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { _ in
            Self.fitWindowsToScreen()
        }
        if AppState.isSelfTest {
            Task { @MainActor in
                if AppState.isDiagnosis {
                    await SelfTest.runDiagnosis(AppState.shared)
                } else if ProcessInfo.processInfo.environment["MP_STUDIO"] != nil {
                    await SelfTest.runStudio(AppState.shared)
                } else if ProcessInfo.processInfo.environment["MP_PERF"] != nil {
                    await SelfTest.runPerf(AppState.shared)
                } else if let model = ProcessInfo.processInfo.environment["MP_TEST_MODEL"] {
                    await SelfTest.runModel(AppState.shared, needle: model)
                } else {
                    await SelfTest.run(AppState.shared)
                }
            }
        }
    }

    static func fitWindowsToScreen() {
        for window in NSApp.windows {
            if ProcessInfo.processInfo.environment["MP_DEBUG_WINDOWS"] != nil {
                FileHandle.standardError.write(Data("window \(window.frame) visible \(window.isVisible) titled \(window.styleMask.contains(.titled)) screen \(window.screen?.visibleFrame ?? .zero) zoomed \(window.isZoomed) min \(window.minSize)\n".utf8))
            }
            guard window.isVisible, window.styleMask.contains(.titled),
                  let visible = (window.screen ?? NSScreen.main)?.visibleFrame else { continue }
            var frame = window.frame
            if frame.height > visible.height { frame.size.height = visible.height }
            if frame.width > visible.width { frame.size.width = visible.width }
            frame.origin.x = min(max(frame.origin.x, visible.minX), visible.maxX - frame.width)
            frame.origin.y = min(max(frame.origin.y, visible.minY), visible.maxY - frame.height)
            if frame != window.frame { window.setFrame(frame, display: true, animate: false) }
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
                Button("Design Studio") { state.sidebarSelection = .studio }.keyboardShortcut("d", modifiers: [.command, .shift])
                Button("Agents") { state.sidebarSelection = .agents }.keyboardShortcut("g")
                Button("Compare Models") { state.sidebarSelection = .compare }.keyboardShortcut("k")
                Button("Benchmarks") { state.sidebarSelection = .benchmarks }.keyboardShortcut("u")
                Button("Leaderboard") { state.sidebarSelection = .leaderboard }.keyboardShortcut("b")
                Button("Model Library") { state.sidebarSelection = .models }.keyboardShortcut("l")
                Divider()
                Button("Stop Generating") { state.stopGenerating(); state.stopCompare(); state.stopBenchmarks(); state.stopAgents(); state.stopStudio() }.keyboardShortcut(".")
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
