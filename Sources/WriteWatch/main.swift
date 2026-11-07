import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: MainWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Registered defaults live in memory only, unlike set(_:forKey:), which goes to disk.
        UserDefaults.standard.register(defaults: [
            "NSQuitAlwaysKeepsWindows": false,
            "ApplePersistenceIgnoreState": true,
        ])

        NSApp.applicationIconImage = Self.makeIcon()
        NSApp.mainMenu = Self.makeMenu(target: self)

        let controller = MainWindowController()
        self.controller = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)

        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--replay"), index + 1 < arguments.count {
            controller.loadReplay(path: arguments[index + 1])
            if let pane = arguments.firstIndex(of: "--pane"), pane + 1 < arguments.count, let value = Int(arguments[pane + 1]) {
                controller.selectPaneForDebug(value)
            }
            if let shot = arguments.firstIndex(of: "--snapshot"), shot + 1 < arguments.count {
                let path = arguments[shot + 1]
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    controller.writeWindowSnapshot(to: path)
                    exit(0)
                }
            }
            return
        }
        #endif

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            controller.beginInitialCapture()
        }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        controller?.confirmQuit() == false ? .terminateCancel : .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.shutDown()
    }

    @objc func saveCapture(_ sender: Any?) {
        controller?.saveCapture()
    }

    private static func makeMenu(target: AppDelegate) -> NSMenu {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About WriteWatch", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide WriteWatch", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit WriteWatch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        let save = NSMenuItem(title: "Save Capture…", action: #selector(saveCapture(_:)), keyEquivalent: "s")
        save.target = target
        fileMenu.addItem(save)
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = fileMenu
        main.addItem(fileItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.windowsMenu = windowMenu

        return main
    }

    /// Drawn at launch, so the app ships no image files.
    private static func makeIcon() -> NSImage {
        NSImage(size: NSSize(width: 512, height: 512), flipped: false) { rect in
            let tile = rect.insetBy(dx: 44, dy: 44)
            NSColor(srgbRed: 0.10, green: 0.11, blue: 0.13, alpha: 1).setFill()
            NSBezierPath(roundedRect: tile, xRadius: 92, yRadius: 92).fill()
            let heights: [CGFloat] = [0.25, 0.45, 0.30, 0.72, 0.52, 0.88]
            let barWidth = (tile.width - 110) / CGFloat(heights.count * 2 - 1)
            NSColor(srgbRed: 0.22, green: 0.53, blue: 0.90, alpha: 1).setFill()
            for (index, height) in heights.enumerated() {
                let bar = NSRect(
                    x: tile.minX + 55 + CGFloat(index) * 2 * barWidth, y: tile.minY + 62,
                    width: barWidth, height: (tile.height - 124) * height)
                NSBezierPath(roundedRect: bar, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
            }
            return true
        }
    }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
