import AppKit

enum ClipboardWriter {
    static func write(text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if pasteboard.setString(text, forType: .string) {
            AppLog.info("Clipboard updated (\(text.count) chars).")
        } else {
            AppLog.error("Clipboard write failed.")
        }
    }
}
