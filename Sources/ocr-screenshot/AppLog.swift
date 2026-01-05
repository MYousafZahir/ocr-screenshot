import Foundation

enum AppLog {
    static func info(_ message: String) {
        write(message, handle: .standardOutput)
    }

    static func error(_ message: String) {
        write(message, handle: .standardError)
    }

    private static func write(_ message: String, handle: FileHandle) {
        let line = "[ocr-screenshot] \(message)\n"
        if let data = line.data(using: .utf8) {
            handle.write(data)
        }
    }
}
