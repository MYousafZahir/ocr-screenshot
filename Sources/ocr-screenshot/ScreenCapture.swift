import AppKit

@MainActor
enum ScreenCapture {
    private static var didRequestAccess = false

    static func capture(rect: CGRect) -> CGImage? {
        let normalizedRect = rect.integral
        guard normalizedRect.width > 1, normalizedRect.height > 1 else {
            return nil
        }

        if !CGPreflightScreenCaptureAccess() {
            if !didRequestAccess {
                didRequestAccess = true
                CGRequestScreenCaptureAccess()
            }
            AppLog.error("Screen Recording permission missing.")
            return nil
        }

        AppLog.info("Capture rect points: \(normalizedRect).")
        let method = ProcessInfo.processInfo.environment["OCR_CAPTURE_METHOD"]?.lowercased()
        let preferDisplay = method == "display"
        let preferWindow = method == "window"

        if !preferWindow {
        if let (displayID, displayRect) = captureRectInDisplayPoints(for: normalizedRect) {
            AppLog.info("Capture rect display points: \(displayRect) on display \(displayID).")
            if let image = CGDisplayCreateImage(displayID, rect: displayRect) {
                AppLog.info("Capture method: display.")
                return image
            }
            AppLog.error("CGDisplayCreateImage returned nil.")
        }
            if preferDisplay {
                return nil
            }
        }

        if !preferDisplay {
            return captureWithWindowList(rect: normalizedRect)
        }
        return nil
    }

    private static func captureWithWindowList(rect: CGRect) -> CGImage? {
        let image = CGWindowListCreateImage(
            rect,
            .optionOnScreenOnly,
            kCGNullWindowID,
            [.boundsIgnoreFraming, .bestResolution]
        )
        if image == nil {
            AppLog.error("CGWindowListCreateImage returned nil.")
        } else {
            AppLog.info("Capture method: window-list.")
        }
        return image
    }

    private static func captureRectInDisplayPoints(for rect: CGRect) -> (CGDirectDisplayID, CGRect)? {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return nil }

        var bestScreen: NSScreen?
        var bestArea: CGFloat = 0
        for screen in screens {
            let intersection = rect.intersection(screen.frame)
            let area = max(0, intersection.width) * max(0, intersection.height)
            if area > bestArea {
                bestArea = area
                bestScreen = screen
            }
        }
        guard let screen = bestScreen, bestArea > 0 else { return nil }
        guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }

        let displayID = CGDirectDisplayID(screenNumber.uint32Value)
        let localRect = rect.intersection(screen.frame)
        let localX = localRect.origin.x - screen.frame.origin.x
        let localY = localRect.origin.y - screen.frame.origin.y
        let displayX = localX
        let displayY = screen.frame.height - (localY + localRect.height)
        let displayRect = CGRect(
            x: displayX,
            y: displayY,
            width: localRect.width,
            height: localRect.height
        ).integral

        if displayRect.width <= 1 || displayRect.height <= 1 {
            return nil
        }
        AppLog.info("Display bounds: \(CGDisplayBounds(displayID)), scale: \(screen.backingScaleFactor).")
        return (displayID, displayRect)
    }

}
