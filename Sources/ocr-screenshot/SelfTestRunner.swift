import AppKit

@MainActor
final class SelfTestRunner {
    private let coordinator: CaptureCoordinator
    private let expectedText: String
    private let interval: TimeInterval
    private var remainingRuns: Int?
    private var window: NSWindow?
    private var runIndex: Int = 0

    init(coordinator: CaptureCoordinator, expectedText: String, runCount: Int?, interval: TimeInterval) {
        self.coordinator = coordinator
        self.expectedText = expectedText
        self.remainingRuns = runCount
        self.interval = interval
    }

    func start() {
        scheduleNextRun()
    }

    private func scheduleNextRun() {
        if let remainingRuns, remainingRuns <= 0 {
            AppLog.info("Self-test complete.")
            return
        }
        let interval = self.interval
        Task { @MainActor [weak self] in
            let delay = UInt64(max(0, interval) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: delay)
            self?.runOnce()
        }
    }

    private func runOnce() {
        if let remainingRuns {
            self.remainingRuns = max(0, remainingRuns - 1)
        }
        runIndex += 1
        AppLog.info("Self-test run \(runIndex) starting.")

        let window = makeTestWindow(text: expectedText)
        self.window = window
        window.makeKeyAndOrderFront(nil)

        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            self?.captureWindow()
        }
    }

    private func captureWindow() {
        guard let window else {
            AppLog.error("Self-test window missing.")
            scheduleNextRun()
            return
        }
        let rect = window.frame
        coordinator.capture(rect: rect) { [weak self] result in
            guard let self else { return }
            let passed: Bool
            switch result {
            case .success(let text):
                passed = self.matchesExpected(text)
                if !passed {
                    AppLog.info("Self-test OCR text: \(self.sanitized(text)).")
                }
            case .failure:
                passed = false
            }
            AppLog.info("Self-test run \(self.runIndex) result: \(passed ? "pass" : "fail").")
            window.orderOut(nil)
            self.window = nil
            self.scheduleNextRun()
        }
    }

    private func makeTestWindow(text: String) -> NSWindow {
        let size = NSSize(width: 520, height: 180)
        let frame = centeredFrame(for: size)
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.level = .floating
        window.isOpaque = true
        window.backgroundColor = .white
        window.hasShadow = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.ignoresMouseEvents = true
        window.contentView = SelfTestView(frame: NSRect(origin: .zero, size: size), text: text)
        return window
    }

    private func centeredFrame(for size: NSSize) -> NSRect {
        let screenFrame = NSScreen.main?.visibleFrame ?? NSScreen.screens.first?.visibleFrame ?? .zero
        let origin = CGPoint(
            x: screenFrame.midX - size.width / 2,
            y: screenFrame.midY - size.height / 2
        )
        return NSRect(origin: origin, size: size)
    }

    private func matchesExpected(_ text: String) -> Bool {
        let normalizedExpected = expectedText.filter { !$0.isWhitespace }
        let normalizedText = text.filter { !$0.isWhitespace }
        return !normalizedText.isEmpty && normalizedText.contains(normalizedExpected)
    }

    private func sanitized(_ text: String) -> String {
        let replaced = text.replacingOccurrences(of: "\n", with: "\\n")
        if replaced.count > 200 {
            return String(replaced.prefix(200)) + "..."
        }
        return replaced
    }
}

final class SelfTestView: NSView {
    private let text: String

    init(frame: NSRect, text: String) {
        self.text = text
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        NSBezierPath(rect: bounds).fill()

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 44, weight: .regular),
            .foregroundColor: NSColor.black,
            .paragraphStyle: paragraph,
        ]

        let attributed = NSAttributedString(string: text, attributes: attributes)
        let textSize = attributed.size()
        let rect = NSRect(
            x: (bounds.width - textSize.width) / 2,
            y: (bounds.height - textSize.height) / 2,
            width: textSize.width,
            height: textSize.height
        )
        attributed.draw(in: rect)
    }
}
