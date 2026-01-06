import Foundation

final class DanubePostProcessor: @unchecked Sendable {
    static let shared = DanubePostProcessor()

    private let queue = DispatchQueue(label: "ocr-screenshot.danube.postprocessor", qos: .userInitiated)
    private var process: Process?
    private var inputHandle: FileHandle?
    private var outputHandle: FileHandle?
    private var buffer = Data()
    private var pending: [(String, @Sendable (String) -> Void)] = []
    private var inFlight: (original: String, completion: @Sendable (String) -> Void)?
    private var isStarting = false
    private var isReady = false
    private var pendingReadyCallbacks: [@MainActor @Sendable () -> Void] = []
    private var hasLoggedNotReady = false

    func waitUntilReady(_ completion: @escaping @MainActor @Sendable () -> Void) {
        guard isEnabled else {
            Task { @MainActor in completion() }
            return
        }
        queue.async {
            if self.isReady {
                Task { @MainActor in completion() }
                return
            }
            self.pendingReadyCallbacks.append(completion)
            self.startIfNeeded()
        }
    }

    func isReadySync() -> Bool {
        guard isEnabled else { return true }
        return queue.sync { isReady }
    }

    func postProcess(text: String, completion: @escaping @Sendable (String) -> Void) {
        guard isEnabled else {
            completion(text)
            return
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            completion(text)
            return
        }

        queue.async {
            AppLog.info("Postprocess queued (\(text.count) chars).")
            self.pending.append((text, completion))
            self.startIfNeeded()
            self.sendNextIfIdle()
        }
    }

    func prewarm() {
        guard isEnabled else { return }
        queue.async {
            self.startIfNeeded()
        }
    }

    private var isEnabled: Bool {
        ProcessInfo.processInfo.environment["OCR_DANUBE_POSTPROCESS"] != "0"
    }

    private func startIfNeeded() {
        guard process == nil, !isStarting else { return }
        isStarting = true
        isReady = false
        hasLoggedNotReady = false

        if !ensureRuntime() {
            isStarting = false
            drainPendingFallback()
            drainReadyFallback()
            return
        }

        guard let scriptURL = Bundle.module.url(forResource: "danube_postprocess", withExtension: "py") else {
            AppLog.error("Postprocess script missing.")
            isStarting = false
            drainPendingFallback()
            return
        }

        let pythonURL = danubePythonURL()
        let process = Process()
        process.executableURL = pythonURL
        process.arguments = [scriptURL.path]
        process.environment = danubeEnvironment()

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let strongSelf = self
        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                strongSelf.queue.async {
                    strongSelf.handleProcessExit()
                }
                return
            }
            strongSelf.queue.async {
                strongSelf.buffer.append(data)
                strongSelf.consumeOutputLines()
            }
        }

        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                return
            }
            if let message = String(data: data, encoding: .utf8) {
                for line in message.split(separator: "\n") {
                    AppLog.info(String(line))
                }
            }
        }

        process.terminationHandler = { _ in
            strongSelf.queue.async {
                strongSelf.handleProcessExit()
            }
        }

        do {
            try process.run()
            self.process = process
            self.inputHandle = inputPipe.fileHandleForWriting
            self.outputHandle = outputPipe.fileHandleForReading
            AppLog.info("Postprocessor started.")
        } catch {
            AppLog.error("Failed to start postprocessor: \(error)")
            self.process = nil
            self.inputHandle = nil
            self.outputHandle = nil
            drainReadyFallback()
        }

        isStarting = false
    }

    private func handleProcessExit() {
        process = nil
        inputHandle = nil
        outputHandle = nil
        buffer.removeAll()
        isReady = false
        hasLoggedNotReady = false

        if let inFlight {
            let original = inFlight.original
            inFlight.completion(original)
            self.inFlight = nil
        }
        if !pending.isEmpty {
            drainPendingFallback()
        }
        drainReadyFallback()
    }

    private func sendNextIfIdle() {
        guard inFlight == nil, let inputHandle, process != nil else { return }
        guard !pending.isEmpty else { return }
        guard isReady else {
            if !hasLoggedNotReady {
                AppLog.info("Postprocess waiting for model warmup.")
                hasLoggedNotReady = true
            }
            return
        }
        hasLoggedNotReady = false

        let (text, completion) = pending.removeFirst()
        inFlight = (original: text, completion: completion)
        AppLog.info("Postprocess sending (\(text.count) chars).")
        let payload: [String: String] = ["text": text]
        do {
            let data = try JSONSerialization.data(withJSONObject: payload)
            var line = data
            line.append(0x0A)
            try inputHandle.write(contentsOf: line)
        } catch {
            AppLog.error("Postprocess write failed: \(error)")
            let original = inFlight?.original ?? text
            let callback = inFlight?.completion ?? completion
            inFlight = nil
            callback(original)
            sendNextIfIdle()
        }
    }

    private func consumeOutputLines() {
        while let range = buffer.firstRange(of: Data([0x0A])) {
            let lineData = buffer.subdata(in: 0..<range.lowerBound)
            buffer.removeSubrange(0...range.lowerBound)
            handleOutputLine(lineData)
        }
    }

    private func handleOutputLine(_ data: Data) {
        guard let message = parseMessage(data) else {
            AppLog.info("Postprocess skipped (invalid response).")
            return
        }

        if message.ready == true {
            if !isReady {
                AppLog.info("Postprocessor ready.")
                isReady = true
            }
            hasLoggedNotReady = false
            let callbacks = pendingReadyCallbacks
            pendingReadyCallbacks.removeAll()
            for callback in callbacks {
                Task { @MainActor in
                    callback()
                }
            }
            sendNextIfIdle()
            return
        }

        guard let inFlight else {
            AppLog.info("Postprocess skipped (no in-flight request).")
            return
        }

        let original = inFlight.original
        let completion = inFlight.completion
        self.inFlight = nil

        guard let payload = message.text else {
            AppLog.info("Postprocess skipped (missing text).")
            completion(original)
            sendNextIfIdle()
            return
        }

        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            AppLog.info("Postprocess skipped (empty output).")
            completion(original)
        } else {
            AppLog.info("Postprocess applied (\(trimmed.count) chars).")
            completion(trimmed)
        }
        sendNextIfIdle()
    }

    private func parseMessage(_ data: Data) -> (text: String?, ready: Bool?)? {
        guard !data.isEmpty else { return nil }
        do {
            let json = try JSONSerialization.jsonObject(with: data)
            if let dict = json as? [String: Any] {
                let text = dict["text"] as? String
                let ready = dict["ready"] as? Bool
                if text == nil, ready == nil {
                    return nil
                }
                return (text: text, ready: ready)
            }
        } catch {
            AppLog.error("Postprocess JSON parse failed: \(error)")
        }
        return nil
    }


    private func danubeRootURL() -> URL {
        let supportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return supportURL.appendingPathComponent("ocr-screenshot/danube", isDirectory: true)
    }

    private func danubePythonURL() -> URL {
        let venvURL = danubeRootURL().appendingPathComponent("venv", isDirectory: true)
        return venvURL.appendingPathComponent("bin/python3")
    }

    private func danubeEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let modelDir = danubeRootURL().appendingPathComponent("models", isDirectory: true).path
        env["DANUBE_MODEL_DIR"] = env["DANUBE_MODEL_DIR"] ?? modelDir
        env["PYTHONUNBUFFERED"] = "1"
        return env
    }

    private func ensureRuntime() -> Bool {
        let rootURL = danubeRootURL()
        do {
            try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(
                at: rootURL.appendingPathComponent("models", isDirectory: true),
                withIntermediateDirectories: true
            )
        } catch {
            AppLog.error("Failed to create postprocessor directories: \(error)")
            return false
        }

        let pythonURL = danubePythonURL()
        if !FileManager.default.fileExists(atPath: pythonURL.path) {
            let systemPython = ProcessInfo.processInfo.environment["PADDLEOCR_VL_PYTHON"] ?? "/usr/bin/python3"
            AppLog.info("Creating postprocessor venv.")
            let venvRoot = pythonURL.deletingLastPathComponent().deletingLastPathComponent().path
            let status = runProcess(systemPython, arguments: ["-m", "venv", venvRoot])
            if status != 0 {
                AppLog.error("Postprocessor venv creation failed.")
                return false
            }
        }

        guard FileManager.default.fileExists(atPath: pythonURL.path) else {
            AppLog.error("Postprocessor venv python missing after creation.")
            return false
        }

        if !pythonModuleAvailable(pythonURL: pythonURL, moduleName: "llama_cpp") {
            AppLog.info("Installing llama-cpp-python for postprocessor.")
            _ = runProcess(pythonURL.path, arguments: ["-m", "pip", "install", "--upgrade", "pip"])
            let status = runProcess(pythonURL.path, arguments: ["-m", "pip", "install", "llama-cpp-python"])
            if status != 0 {
                AppLog.error("Failed to install llama-cpp-python.")
                return false
            }
        }

        return true
    }

    private func pythonModuleAvailable(pythonURL: URL, moduleName: String) -> Bool {
        let status = runProcess(pythonURL.path, arguments: ["-c", "import \(moduleName)"])
        return status == 0
    }

    @discardableResult
    private func runProcess(_ launchPath: String, arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        process.environment = danubeEnvironment()

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            AppLog.error("Failed to run \(launchPath): \(error)")
            return 1
        }

        process.waitUntilExit()
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        if let output = String(data: outputData, encoding: .utf8), !output.isEmpty {
            AppLog.info(output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if let error = String(data: errorData, encoding: .utf8), !error.isEmpty {
            AppLog.error(error.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return process.terminationStatus
    }

    private func drainPendingFallback() {
        let pending = self.pending
        let inFlight = self.inFlight
        self.pending.removeAll()
        self.inFlight = nil
        if let inFlight {
            inFlight.completion(inFlight.original)
        }
        for (text, completion) in pending {
            completion(text)
        }
    }

    private func drainReadyFallback() {
        let callbacks = pendingReadyCallbacks
        pendingReadyCallbacks.removeAll()
        for callback in callbacks {
            Task { @MainActor in
                callback()
            }
        }
    }
}
