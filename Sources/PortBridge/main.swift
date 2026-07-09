import AppKit
import PortBridgeCore

private var retainedDelegate: AppDelegate?

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let appState = AppState()
    private var menuController: MenuController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        menuController = MenuController(appState: appState)
        appState.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        appState.stop()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
retainedDelegate = delegate
app.delegate = delegate
app.run()
