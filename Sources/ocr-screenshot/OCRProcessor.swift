import Foundation
@preconcurrency import Vision

struct RecognizedTextBox: Sendable {
    let text: String
    let rect: CGRect
}

enum OCRProcessorError: Error {
    case noResults
    case visionError(Error)
    case paddleUnavailable
}

enum OCRBackend: String {
    case paddle
    case vision

    static var current: OCRBackend {
        let value = ProcessInfo.processInfo.environment["OCR_BACKEND"]?.lowercased()
        return OCRBackend(rawValue: value ?? "") ?? .paddle
    }
}

final class OCRProcessor: @unchecked Sendable {
    private let backend: OCRBackend
    private let paddleRunner: PaddleOCRRunner?
    private let combineBackends: Bool

    init(backend: OCRBackend = .current) {
        self.backend = backend
        self.paddleRunner = PaddleOCRRunner()
        self.combineBackends = ProcessInfo.processInfo.environment["OCR_COMBINE_BACKENDS"] != "0"
    }

    func recognizeText(in image: CGImage, completion: @escaping @Sendable (Result<[RecognizedTextBox], Error>) -> Void) {
        if combineBackends, paddleRunner != nil {
            switch backend {
            case .paddle:
                recognizeWithBoth(in: image, primary: .paddle, completion: completion)
                return
            case .vision:
                recognizeWithBoth(in: image, primary: .vision, completion: completion)
                return
            }
        }

        switch backend {
        case .paddle:
            guard let paddleRunner else {
                AppLog.info("PaddleOCR unavailable. Falling back to Vision.")
                recognizeWithVision(in: image, completion: completion)
                return
            }
            paddleRunner.recognizeText(in: image) { [weak self] result in
                switch result {
                case .success:
                    completion(result)
                case .failure:
                    AppLog.error("PaddleOCR failed. Falling back to Vision.")
                    guard let self else {
                        completion(result)
                        return
                    }
                    self.recognizeWithVision(in: image) { fallbackResult in
                        switch fallbackResult {
                        case .success:
                            completion(fallbackResult)
                        case .failure:
                            completion(result)
                        }
                    }
                }
            }
        case .vision:
            recognizeWithVision(in: image, completion: completion)
        }
    }

    private func recognizeWithBoth(
        in image: CGImage,
        primary: OCRBackend,
        completion: @escaping @Sendable (Result<[RecognizedTextBox], Error>) -> Void
    ) {
        let group = DispatchGroup()
        let store = OCRResultStore()

        group.enter()
        runBackend(primary, in: image) { result in
            store.lock.lock()
            store.primary = result
            store.lock.unlock()
            group.leave()
        }

        let secondary: OCRBackend = (primary == .paddle) ? .vision : .paddle
        group.enter()
        runBackend(secondary, in: image) { result in
            store.lock.lock()
            store.secondary = result
            store.lock.unlock()
            group.leave()
        }

        group.notify(queue: .global(qos: .userInitiated)) {
            store.lock.lock()
            let primaryResult = store.primary
            let secondaryResult = store.secondary
            store.lock.unlock()

            guard let primaryResult else {
                completion(secondaryResult ?? .failure(OCRProcessorError.noResults))
                return
            }
            switch (primaryResult, secondaryResult) {
            case (.success(let primaryBoxes), .success(let secondaryBoxes)):
                let merged = RecognizedTextMerger.merge(primary: primaryBoxes, secondary: secondaryBoxes)
                completion(.success(merged))
            case (.success, .failure), (.success, .none):
                completion(primaryResult)
            case (.failure, .success), (.failure, .none):
                completion(secondaryResult ?? primaryResult)
            case (.failure, .failure):
                completion(primaryResult)
            }
        }
    }

    private func runBackend(
        _ backend: OCRBackend,
        in image: CGImage,
        completion: @escaping @Sendable (Result<[RecognizedTextBox], Error>) -> Void
    ) {
        switch backend {
        case .paddle:
            guard let paddleRunner else {
                completion(.failure(OCRProcessorError.paddleUnavailable))
                return
            }
            paddleRunner.recognizeText(in: image, completion: completion)
        case .vision:
            recognizeWithVision(in: image, completion: completion)
        }
    }

    private func recognizeWithVision(in image: CGImage, completion: @escaping @Sendable (Result<[RecognizedTextBox], Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let request = VNRecognizeTextRequest { request, error in
                    if let error {
                        completion(.failure(OCRProcessorError.visionError(error)))
                        return
                    }

                    guard let observations = request.results as? [VNRecognizedTextObservation] else {
                        completion(.failure(OCRProcessorError.noResults))
                        return
                    }

                    let width = CGFloat(image.width)
                    let height = CGFloat(image.height)
                    var boxes: [RecognizedTextBox] = []
                    boxes.reserveCapacity(observations.count)

                    for observation in observations {
                        guard let candidate = observation.topCandidates(1).first else { continue }
                        let rect = VNImageRectForNormalizedRect(observation.boundingBox, Int(width), Int(height))
                        let trimmed = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                        if trimmed.isEmpty { continue }
                        boxes.append(RecognizedTextBox(text: trimmed, rect: rect))
                    }

                    if boxes.isEmpty {
                        completion(.failure(OCRProcessorError.noResults))
                        return
                    }

                    completion(.success(boxes))
                }

                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = false
                request.minimumTextHeight = 0.004

                let handler = VNImageRequestHandler(cgImage: image, options: [:])
                try handler.perform([request])
            } catch {
                completion(.failure(OCRProcessorError.visionError(error)))
            }
        }
    }
}

private final class OCRResultStore: @unchecked Sendable {
    let lock = NSLock()
    var primary: Result<[RecognizedTextBox], Error>?
    var secondary: Result<[RecognizedTextBox], Error>?
}
