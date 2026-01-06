import AppKit
import Carbon
import Darwin

@main
@MainActor
final class OCRScreenshotApp: NSObject, NSApplicationDelegate {
    private let coordinator = CaptureCoordinator()
    private var hotKeyManager: HotKeyManager?
    private var statusItem: NSStatusItem?
    private var selfTestRunner: SelfTestRunner?
    private let terminationReason = "Keep OCR screenshot running in menu bar."
    private var activity: NSObjectProtocol?

    static func main() {
        signal(SIGPIPE, SIG_IGN)
        let app = NSApplication.shared
        let delegate = OCRScreenshotApp()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppLog.info("App launched.")
        setupStatusItem()
        ProcessInfo.processInfo.disableAutomaticTermination(terminationReason)
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: terminationReason
        )

        let hotKeyManager = HotKeyManager(
            keyCode: UInt32(kVK_ANSI_6),
            modifiers: UInt32(cmdKey | shiftKey)
        ) { [weak self] in
            Task { @MainActor [weak self] in
                self?.startCapture()
            }
        }
        hotKeyManager.register()
        self.hotKeyManager = hotKeyManager
        DanubePostProcessor.shared.prewarm()
        startSelfTestIfNeeded()
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppLog.info("App terminating.")
        ProcessInfo.processInfo.enableAutomaticTermination(terminationReason)
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
        hotKeyManager?.unregister()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func setupStatusItem() {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "OCR"
        let menu = NSMenu()
        let captureItem = NSMenuItem(title: "Capture Text (Cmd+Shift+6)", action: #selector(startCapture), keyEquivalent: "")
        captureItem.target = self
        menu.addItem(captureItem)
        menu.addItem(NSMenuItem.separator())

        let aboutItem = NSMenuItem(title: "About", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        self.statusItem = statusItem
    }

    @objc private func startCapture() {
        coordinator.startCapture()
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func startSelfTestIfNeeded() {
        let env = ProcessInfo.processInfo.environment
        let shouldRun = env["OCR_SELFTEST"] != nil || env["OCR_SELFTEST_LOOP"] != nil
        guard shouldRun else { return }

        let expectedText = env["OCR_SELFTEST_EXPECT"] ?? "OCR TEST 123"
        let runCount = Int(env["OCR_SELFTEST_LOOP"] ?? "")
        let interval = TimeInterval(env["OCR_SELFTEST_INTERVAL"] ?? "") ?? 1.5

        let runner = SelfTestRunner(
            coordinator: coordinator,
            expectedText: expectedText,
            runCount: runCount,
            interval: interval
        )
        selfTestRunner = runner
        runner.start()
    }
}
