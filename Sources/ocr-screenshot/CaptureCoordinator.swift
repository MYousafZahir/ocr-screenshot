import AppKit

@MainActor
final class CaptureCoordinator {
    private let selectionController = SelectionOverlayController()
    private let primaryProcessor: OCRProcessor
    private let secondaryProcessor: OCRProcessor
    private let combineBackendsEnabled: Bool
    private let postProcessor = DanubePostProcessor.shared
    private let formatter = LayoutFormatter()
    private let upscaleFactor = 2
    private let defaultPadding: CGFloat = 8
    private var captureSequence: UInt64 = 0
    private var latestCaptureID: UInt64 = 0

    init() {
        let backend = OCRBackend.current
        let secondary = backend == .paddle ? OCRBackend.vision : OCRBackend.paddle
        self.primaryProcessor = OCRProcessor(backend: backend, combineBackends: false)
        self.secondaryProcessor = OCRProcessor(backend: secondary, combineBackends: false)
        self.combineBackendsEnabled = ProcessInfo.processInfo.environment["OCR_COMBINE_BACKENDS"] != "0"
    }

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
        let scale = upscaleFactor
        let alternateImageProvider: @Sendable () -> CGImage? = {
            ImageUpscaler.upscale(image, scale: scale)
        }

        runAdaptiveOCR(
            primaryImage: upscaledImage,
            alternateImageProvider: alternateImageProvider,
            focusRect: focusRectUpscaled,
            formatter: formatter
        ) { result in
            Task { @MainActor in
                switch result {
                case .success(let finalText):
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
                case .failure(let error):
                    AppLog.error("OCR failed: \(error)")
                    NSSound.beep()
                    completion?(.failure(error))
                }
            }
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

    private func runAdaptiveOCR(
        primaryImage: CGImage,
        alternateImageProvider: @escaping @Sendable () -> CGImage?,
        focusRect: CGRect,
        formatter: LayoutFormatter,
        completion: @escaping @Sendable (Result<String, Error>) -> Void
    ) {
        let threshold = qualityThreshold()
        let multiPass = multiPassEnabled()
        let allowFallback = qualityFallbackEnabled() || combineBackendsEnabled
        let primaryProcessor = self.primaryProcessor

        primaryProcessor.recognizeText(in: primaryImage) { result in
            Task { @MainActor in
                switch result {
                case .failure(let error):
                    completion(.failure(error))
                case .success(let boxes):
                    let filtered = Self.filterBoxes(boxes, focusRect: focusRect)
                    guard !filtered.isEmpty else {
                        completion(.failure(OCRProcessorError.noResults))
                        return
                    }
                    AppLog.info("OCR succeeded with \(filtered.count) boxes.")
                    var currentBoxes = filtered
                    var currentText = formatter.format(boxes: filtered)
                    guard !currentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        completion(.failure(OCRProcessorError.noResults))
                        return
                    }

                    var currentScore = (multiPass || allowFallback)
                        ? TextQualityScorer.score(currentText)
                        : 1.0
                    guard currentScore < threshold, (multiPass || allowFallback) else {
                        completion(.success(currentText))
                        return
                    }

                    let finalize: @MainActor @Sendable () -> Void = {
                        completion(.success(currentText))
                    }

                    let runSecondaryBackendIfNeeded: @MainActor @Sendable () -> Void = {
                        guard currentScore < threshold, allowFallback else {
                            finalize()
                            return
                        }
                        AppLog.info("OCR adaptive: score \(String(format: "%.2f", currentScore)) below \(threshold). Running secondary backend.")
                        let secondaryProcessor = self.secondaryProcessor
                        secondaryProcessor.recognizeText(in: primaryImage) { secondaryResult in
                            Task { @MainActor in
                                switch secondaryResult {
                                case .success(let secondaryBoxes):
                                    let filteredSecondary = Self.filterBoxes(secondaryBoxes, focusRect: focusRect)
                                    guard !filteredSecondary.isEmpty else {
                                        finalize()
                                        return
                                    }
                                    if self.combineBackendsEnabled {
                                        let mergedBoxes = RecognizedTextMerger.merge(primary: currentBoxes, secondary: filteredSecondary)
                                        let mergedText = formatter.format(boxes: mergedBoxes)
                                        let chosen = TextQualityScorer.chooseBetter(
                                            primary: currentText,
                                            primaryScore: currentScore,
                                            secondary: mergedText
                                        )
                                        currentText = chosen.text
                                        currentScore = chosen.score
                                        if chosen.text == mergedText {
                                            currentBoxes = mergedBoxes
                                        }
                                    } else {
                                        let candidateText = formatter.format(boxes: filteredSecondary)
                                        let chosen = TextQualityScorer.chooseBetter(
                                            primary: currentText,
                                            primaryScore: currentScore,
                                            secondary: candidateText
                                        )
                                        currentText = chosen.text
                                        currentScore = chosen.score
                                    }
                                case .failure:
                                    break
                                }
                                finalize()
                            }
                        }
                    }

                    guard multiPass else {
                        runSecondaryBackendIfNeeded()
                        return
                    }

                    AppLog.info("OCR adaptive: score \(String(format: "%.2f", currentScore)) below \(threshold). Running multipass.")
                    if let alternateImage = alternateImageProvider() {
                        primaryProcessor.recognizeText(in: alternateImage) { secondaryResult in
                            Task { @MainActor in
                                switch secondaryResult {
                                case .success(let secondaryBoxes):
                                    let filteredSecondary = Self.filterBoxes(secondaryBoxes, focusRect: focusRect)
                                    if !filteredSecondary.isEmpty {
                                        let mergedBoxes = RecognizedTextMerger.merge(primary: currentBoxes, secondary: filteredSecondary)
                                        let mergedText = formatter.format(boxes: mergedBoxes)
                                        let chosen = TextQualityScorer.chooseBetter(
                                            primary: currentText,
                                            primaryScore: currentScore,
                                            secondary: mergedText
                                        )
                                        currentText = chosen.text
                                        currentScore = chosen.score
                                        if chosen.text == mergedText {
                                            currentBoxes = mergedBoxes
                                        }
                                    }
                                case .failure:
                                    break
                                }
                                runSecondaryBackendIfNeeded()
                            }
                        }
                    } else {
                        runSecondaryBackendIfNeeded()
                    }
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
