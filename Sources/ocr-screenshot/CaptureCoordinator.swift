import AppKit

@MainActor
final class CaptureCoordinator {
    private let selectionController = SelectionOverlayController()
    private let ocrProcessor = OCRProcessor()
    private let visionFallbackProcessor = OCRProcessor(backend: .vision, combineBackends: false)
    private let postProcessor = DanubePostProcessor.shared
    private let formatter = LayoutFormatter()
    private let upscaleFactor = 2
    private let defaultPadding: CGFloat = 8
    private var captureSequence: UInt64 = 0
    private var latestCaptureID: UInt64 = 0

    func startCapture() {
        NSApp.activate(ignoringOtherApps: true)
        AppLog.info("Capture started.")
        selectionController.beginSelection { [weak self] rect in
            self?.handleSelection(rect, completion: nil)
        }
    }

    func capture(rect: CGRect, completion: (@MainActor @Sendable (Result<String, Error>) -> Void)? = nil) {
        handleSelection(rect, completion: completion)
    }

    private func handleSelection(_ rect: CGRect?, completion: (@MainActor @Sendable (Result<String, Error>) -> Void)?) {
        guard let rect else {
            AppLog.info("Capture canceled.")
            completion?(.failure(OCRProcessorError.noResults))
            return
        }
        let captureID = nextCaptureID()
        clearClipboardForCapture()
        let paddedRect = applyPadding(to: rect)
        guard let image = ScreenCapture.capture(rect: paddedRect) else {
            AppLog.error("Screen capture failed.")
            NSSound.beep()
            completion?(.failure(OCRProcessorError.noResults))
            return
        }
        let flipY = paddingBlurFlipY()
        let focusRect = focusRectInImage(
            image: image,
            originalRect: rect,
            paddedRect: paddedRect,
            flipY: flipY
        )
        let preparedImage = applyPaddingBlur(
            to: image,
            focusRect: focusRect,
            flipY: flipY,
            enabled: paddedRect != rect
        )
        let upscaledImage = ImageUpscaler.upscale(preparedImage, scale: upscaleFactor)
        let focusRectUpscaled = focusRect
            .applying(CGAffineTransform(scaleX: CGFloat(upscaleFactor), y: CGFloat(upscaleFactor)))
            .integral

        let formatter = self.formatter
        let handleResult: @Sendable (Result<[RecognizedTextBox], Error>) -> Void = { result in
            Task { @MainActor in
                switch result {
                case .success(let boxes):
                    AppLog.info("OCR succeeded with \(boxes.count) boxes.")
                    let text = formatter.format(boxes: boxes)
                    self.maybeRunQualityFallback(
                        baseText: text,
                        image: upscaledImage,
                        formatter: formatter
                    ) { finalText in
                        self.postProcessor.postProcess(text: finalText) { processedText in
                            Task { @MainActor in
                                if captureID == self.latestCaptureID {
                                    ClipboardWriter.write(text: processedText)
                                } else {
                                    AppLog.info("Clipboard update skipped for stale capture \(captureID).")
                                }
                                completion?(.success(processedText))
                            }
                        }
                    }
                case .failure(let error):
                    AppLog.error("OCR failed: \(error)")
                    NSSound.beep()
                    completion?(.failure(error))
                }
            }
        }

        if multiPassEnabled() {
            let alternateImage = ImageUpscaler.upscale(image, scale: upscaleFactor)
            performMultiPassOCR(
                primary: upscaledImage,
                secondary: alternateImage,
                focusRect: focusRectUpscaled,
                completion: handleResult
            )
        } else {
            ocrProcessor.recognizeText(in: upscaledImage, completion: handleResult)
        }
    }

    private func applyPadding(to rect: CGRect) -> CGRect {
        let padding = max(0, cropPadding())
        guard padding > 0 else { return rect }
        let padded = rect.insetBy(dx: -padding, dy: -padding)
        AppLog.info("Capture padding: \(padding).")
        AppLog.info("Capture rect padded: \(padded).")
        return padded
    }

    private func cropPadding() -> CGFloat {
        let raw = ProcessInfo.processInfo.environment["OCR_CROP_PADDING"]
        if let raw, let value = Double(raw) {
            return CGFloat(value)
        }
        return defaultPadding
    }

    private func nextCaptureID() -> UInt64 {
        captureSequence &+= 1
        latestCaptureID = captureSequence
        return captureSequence
    }

    private func clearClipboardForCapture() {
        guard shouldClearClipboardOnCapture() else { return }
        ClipboardWriter.clear()
    }

    private func shouldClearClipboardOnCapture() -> Bool {
        ProcessInfo.processInfo.environment["OCR_CLEAR_CLIPBOARD_ON_CAPTURE"] != "0"
    }

    private func applyPaddingBlur(to image: CGImage, focusRect: CGRect, flipY: Bool, enabled: Bool) -> CGImage {
        guard enabled else { return image }
        return PaddingBlur.apply(to: image, focusRect: focusRect, flipY: flipY)
    }

    private func focusRectInImage(
        image: CGImage,
        originalRect: CGRect,
        paddedRect: CGRect,
        flipY: Bool
    ) -> CGRect {
        let scaleX = CGFloat(image.width) / max(1, paddedRect.width)
        let scaleY = CGFloat(image.height) / max(1, paddedRect.height)
        let localX = originalRect.origin.x - paddedRect.origin.x
        let localY = originalRect.origin.y - paddedRect.origin.y
        let imageY = flipY ? (paddedRect.height - (localY + originalRect.height)) : localY
        let rect = CGRect(
            x: localX * scaleX,
            y: imageY * scaleY,
            width: originalRect.width * scaleX,
            height: originalRect.height * scaleY
        ).integral
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        return rect.intersection(bounds)
    }

    private func paddingBlurFlipY() -> Bool {
        ProcessInfo.processInfo.environment["OCR_PADDING_BLUR_FLIP_Y"] != "0"
    }

    private func multiPassEnabled() -> Bool {
        ProcessInfo.processInfo.environment["OCR_MULTI_PASS"] != "0"
    }

    private func maybeRunQualityFallback(
        baseText: String,
        image: CGImage,
        formatter: LayoutFormatter,
        completion: @escaping @Sendable (String) -> Void
    ) {
        guard qualityFallbackEnabled() else {
            completion(baseText)
            return
        }

        let score = TextQualityScorer.score(baseText)
        let threshold = qualityThreshold()
        if score >= threshold {
            completion(baseText)
            return
        }

        AppLog.info("OCR quality score \(String(format: "%.2f", score)) below \(threshold). Running Vision fallback.")
        visionFallbackProcessor.recognizeText(in: image) { result in
            Task { @MainActor in
                switch result {
                case .success(let boxes):
                    let candidate = formatter.format(boxes: boxes)
                    let chosen = TextQualityScorer.chooseBetter(primary: baseText, secondary: candidate)
                    if chosen != baseText {
                        AppLog.info("OCR quality fallback selected Vision output.")
                    }
                    completion(chosen)
                case .failure:
                    completion(baseText)
                }
            }
        }
    }

    private func qualityFallbackEnabled() -> Bool {
        ProcessInfo.processInfo.environment["OCR_QUALITY_FALLBACK"] != "0"
    }

    private func qualityThreshold() -> Double {
        if let raw = ProcessInfo.processInfo.environment["OCR_QUALITY_THRESHOLD"],
           let value = Double(raw) {
            return value
        }
        return 0.62
    }

    private func performMultiPassOCR(
        primary: CGImage,
        secondary: CGImage,
        focusRect: CGRect,
        completion: @escaping @Sendable (Result<[RecognizedTextBox], Error>) -> Void
    ) {
        AppLog.info("OCR multipass started.")
        let ocrProcessor = self.ocrProcessor
        ocrProcessor.recognizeText(in: primary) { primaryResult in
            let primaryFiltered = primaryResult.map { Self.filterBoxes($0, focusRect: focusRect) }
            AppLog.info("OCR multipass primary done.")
            ocrProcessor.recognizeText(in: secondary) { secondaryResult in
                let secondaryFiltered = secondaryResult.map { Self.filterBoxes($0, focusRect: focusRect) }
                AppLog.info("OCR multipass secondary done.")

                switch (primaryFiltered, secondaryFiltered) {
                case (.success(let primaryBoxes), .success(let secondaryBoxes)):
                    AppLog.info("OCR multipass boxes: primary \(primaryBoxes.count), secondary \(secondaryBoxes.count).")
                    let merged = RecognizedTextMerger.merge(primary: primaryBoxes, secondary: secondaryBoxes)
                    completion(.success(merged))
                case (.success, .failure):
                    completion(primaryFiltered)
                case (.failure, .success):
                    completion(secondaryFiltered)
                case (.failure, .failure):
                    completion(primaryFiltered)
                }
            }
        }
    }

    nonisolated private static func filterBoxes(_ boxes: [RecognizedTextBox], focusRect: CGRect) -> [RecognizedTextBox] {
        guard !focusRect.isEmpty else { return boxes }
        return boxes.filter { box in
            let center = CGPoint(x: box.rect.midX, y: box.rect.midY)
            if focusRect.contains(center) {
                return true
            }
            let intersection = box.rect.intersection(focusRect)
            if intersection.isNull || intersection.isEmpty {
                return false
            }
            let area = box.rect.width * box.rect.height
            guard area > 0 else { return false }
            let intersectionArea = intersection.width * intersection.height
            return (intersectionArea / area) >= 0.4
        }
    }
}
