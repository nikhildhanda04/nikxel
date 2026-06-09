import Cocoa

class NikxelAppDelegate: NSObject, NSApplicationDelegate {
    var window: NikxelWindow!
    var statusItem: NSStatusItem!
    var agentMonitor: AgentMonitor!
    var inputHandler: InputHandler!
    var stateMachine: StateMachine!

    func applicationDidFinishLaunching(_ notification: Notification) {
        stateMachine = StateMachine()
        agentMonitor = AgentMonitor(stateMachine: stateMachine)
        inputHandler = InputHandler(stateMachine: stateMachine)

        window = NikxelWindow(stateMachine: stateMachine)
        inputHandler.nikxelView = window.nikxelView
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        setupMenuBar()
        agentMonitor.startMonitoring()
        inputHandler.startMonitoring()
    }

    func applicationWillTerminate(_ notification: Notification) {
        agentMonitor.stopMonitoring()
        inputHandler.stopMonitoring()
    }

    func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let btn = statusItem.button { btn.title = "🐱" }
        let menu = NSMenu()
        let toggle = NSMenuItem(title: "Show/Hide Nikxel", action: #selector(toggle), keyEquivalent: "")
        toggle.target = self; menu.addItem(toggle)
        menu.addItem(NSMenuItem.separator())
        let quit = NSMenuItem(title: "Quit Nikxel", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self; menu.addItem(quit)
        statusItem.menu = menu
    }

    @objc func toggle() {
        if window.isVisible { window.orderOut(nil) }
        else { window.makeKeyAndOrderFront(nil) }
    }

    @objc func quitApp() { NSApp.terminate(nil) }
}

@main
struct NikxelMain {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = NikxelAppDelegate()
        app.delegate = delegate
        _ = delegate // keep strong reference
        app.run()
    }
}
