import AppKit

@MainActor
final class SelectionOverlayController {
    private var windows: [SelectionWindow] = []
    private weak var activeWindow: SelectionWindow?
    private var completion: ((CGRect?) -> Void)?

    func beginSelection(completion: @escaping (CGRect?) -> Void) {
        guard windows.isEmpty else { return }
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }

        for screen in screens {
            let frame = screen.frame
            let window = SelectionWindow(
                contentRect: frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false,
                screen: screen
            )
            window.level = .screenSaver
            window.backgroundColor = .clear
            window.isOpaque = false
            window.hasShadow = false
            window.ignoresMouseEvents = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

            let selectionView = SelectionView(frame: window.contentView?.bounds ?? frame)
            selectionView.autoresizingMask = [.width, .height]
            selectionView.onActivate = { [weak self, weak window] in
                guard let self, let window else { return false }
                if self.activeWindow == nil || self.activeWindow === window {
                    self.activeWindow = window
                    return true
                }
                return false
            }
            selectionView.onSelection = { [weak self] rect in
                self?.finish(with: rect)
            }
            selectionView.onCancel = { [weak self] in
                self?.finish(with: nil)
            }
            window.contentView = selectionView
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(selectionView)
            windows.append(window)
        }
        self.completion = completion
    }

    private func finish(with rect: CGRect?) {
        if let rect {
            AppLog.info("Selection finished: \(rect).")
        } else {
            AppLog.info("Selection canceled.")
        }
        for window in windows {
            window.orderOut(nil)
        }
        windows.removeAll()
        activeWindow = nil
        completion?(rect)
        completion = nil
    }
}

final class SelectionWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class SelectionView: NSView {
    var onActivate: (() -> Bool)?
    var onSelection: ((CGRect?) -> Void)?
    var onCancel: (() -> Void)?

    private var startPoint: CGPoint?
    private var selectionRect: CGRect?
    private var isActive = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }

    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.25).setFill()
        NSBezierPath(rect: bounds).fill()

        if let selectionRect {
            NSGraphicsContext.saveGraphicsState()
            if let context = NSGraphicsContext.current {
                context.compositingOperation = .clear
            }
            NSBezierPath(rect: selectionRect).fill()
            NSGraphicsContext.restoreGraphicsState()
            NSColor.systemBlue.setStroke()
            let path = NSBezierPath(rect: selectionRect)
            path.lineWidth = 2.0
            path.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {
        if onActivate?() == false {
            return
        }
        isActive = true
        startPoint = convert(event.locationInWindow, from: nil)
        selectionRect = CGRect(origin: startPoint ?? .zero, size: .zero)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard isActive else { return }
        guard let startPoint else { return }
        let current = convert(event.locationInWindow, from: nil)
        selectionRect = CGRect(
            x: min(startPoint.x, current.x),
            y: min(startPoint.y, current.y),
            width: abs(current.x - startPoint.x),
            height: abs(current.y - startPoint.y)
        )
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard isActive else { return }
        isActive = false
        guard let selectionRect else {
            onCancel?()
            return
        }

        if selectionRect.width < 4 || selectionRect.height < 4 {
            onCancel?()
            return
        }

        guard let window else {
            onCancel?()
            return
        }

        let rectInWindow = convert(selectionRect, to: nil)
        let rectOnScreen = window.convertToScreen(rectInWindow)
        if let screen = window.screen {
            AppLog.info("Selection screen frame: \(screen.frame).")
        }
        onSelection?(rectOnScreen)
    }

    override func rightMouseDown(with event: NSEvent) {
        if isActive {
            onCancel?()
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            if isActive {
                onCancel?()
            }
            return
        }
        super.keyDown(with: event)
    }
}
