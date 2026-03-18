/// PMuxApp — SwiftUI App entry point with NSApplicationDelegateAdaptor.

import SwiftUI

@main
struct PMuxApp: App {
    @NSApplicationDelegateAdaptor(PMuxAppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appDelegate.appState)
                .environment(appDelegate.sessionManager)
        }
        .defaultSize(width: 1280, height: 800)
        .windowStyle(.hiddenTitleBar)
    }
}

// MARK: - App Delegate (lifecycle only)

class PMuxAppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()
    let sessionManager: SessionManager

    override init() {
        sessionManager = SessionManager(appState: appState)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureWindows()

        // SwiftUI may create windows slightly after launch — retry
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.configureWindows()
        }
    }

    private func configureWindows() {
        for window in NSApp.windows {
            window.backgroundColor = PMuxColors.NS.base
            window.collectionBehavior.insert(.fullScreenPrimary)
            window.acceptsMouseMovedEvents = true
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        sessionManager.shutdown()
    }
}
