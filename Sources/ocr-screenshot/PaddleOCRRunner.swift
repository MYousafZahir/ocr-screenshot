import AppKit

enum PaddleOCRRunnerError: Error {
    case scriptMissing
    case imageEncodingFailed
    case processFailed(String)
    case invalidResponse
}

final class PaddleOCRRunner: @unchecked Sendable {
    private let scriptURL: URL
    private let pythonPath: String

    init?() {
        guard let url = Bundle.module.url(forResource: "paddle_ocr_vl", withExtension: "py") else {
            return nil
        }
        self.scriptURL = url
        self.pythonPath = ProcessInfo.processInfo.environment["PADDLEOCR_VL_PYTHON"] ?? "/usr/bin/python3"
    }

    func recognizeText(in image: CGImage, completion: @escaping @Sendable (Result<[RecognizedTextBox], Error>) -> Void) {
        let scriptURL = scriptURL
        let pythonPath = pythonPath
        DispatchQueue.global(qos: .userInitiated).async {
            autoreleasepool {
                do {
                    let imageData = try Self.encodePNG(image)
                    let result = try Self.runOCR(imageData: imageData, scriptURL: scriptURL, pythonPath: pythonPath)
                    completion(.success(result))
                } catch {
                    completion(.failure(error))
                }
            }
        }
    }

    private static func encodePNG(_ image: CGImage) throws -> Data {
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw PaddleOCRRunnerError.imageEncodingFailed
        }
        return data
    }

    private static func runOCR(imageData: Data, scriptURL: URL, pythonPath: String) throws -> [RecognizedTextBox] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: pythonPath)
        process.arguments = [scriptURL.path, "--stdin"]

        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONUNBUFFERED"] = "1"
        process.environment = environment

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        do {
            try inputPipe.fileHandleForWriting.write(contentsOf: imageData)
        } catch {
            inputPipe.fileHandleForWriting.closeFile()
            throw PaddleOCRRunnerError.processFailed("Failed to write OCR input: \(error)")
        }
        inputPipe.fileHandleForWriting.closeFile()
        process.waitUntilExit()

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

        if process.terminationStatus != 0 {
            let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            throw PaddleOCRRunnerError.processFailed(errorMessage)
        }

        guard !outputData.isEmpty else {
            throw PaddleOCRRunnerError.invalidResponse
        }

        let response = try JSONDecoder().decode(PaddleOCRResponse.self, from: outputData)
        let boxes = response.boxes.compactMap { box -> RecognizedTextBox? in
            guard box.rect.count == 4 else { return nil }
            let rect = CGRect(
                x: box.rect[0],
                y: box.rect[1],
                width: box.rect[2],
                height: box.rect[3]
            )
            let trimmed = box.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return nil }
            return RecognizedTextBox(text: trimmed, rect: rect)
        }
        if boxes.isEmpty {
            throw PaddleOCRRunnerError.invalidResponse
        }
        return boxes
    }
}

private struct PaddleOCRResponse: Decodable {
    let width: Double
    let height: Double
    let boxes: [PaddleOCRBox]
}

private struct PaddleOCRBox: Decodable {
    let text: String
    let rect: [Double]
}
