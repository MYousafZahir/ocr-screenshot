# Formatted Screenshot OCR (macOS)

Lightweight macOS menu bar app that captures a screen region, runs PaddleOCR-VL-0.9B, and copies layout-preserving text to the clipboard. It aims for mechanical fidelity (line breaks, indentation, columns) rather than semantic cleanup.

## Quick start

1. Build and run:
   - `swift run`
   - or open `Package.swift` in Xcode and run the app target
2. Trigger capture:
   - Menu bar item **OCR** -> **Capture Text**
   - Default hotkey: **Cmd + Shift + 6**
3. Drag to select a region. The extracted text is placed on the clipboard.

## Permissions

macOS will request permissions the first time you run:
- Screen Recording: required to capture screen content
- Accessibility: may be required for global hotkeys on some systems

Grant these in **System Settings -> Privacy & Security**.

## PaddleOCR-VL-0.9B setup

The app uses PaddleOCR-VL-0.9B by default via `Sources/ocr-screenshot/Resources/paddle_ocr_vl.py`.

1. Create a Python environment and install dependencies:
   - `python3 -m venv .venv`
   - `source .venv/bin/activate`
   - `pip install paddlepaddle paddleocr pillow opencv-python numpy`
2. Download the PaddleOCR-VL-0.9B model weights and set one of:
   - `export PADDLEOCR_VL_MODEL_DIR=/path/to/PaddleOCR-VL-0.9B`
   - or `export PADDLEOCR_VL_DET_DIR=/path/to/det` and `export PADDLEOCR_VL_REC_DIR=/path/to/rec`
   - optionally `export PADDLEOCR_VL_CLS_DIR=/path/to/cls`
3. Optional:
   - `export PADDLEOCR_VL_PYTHON=/path/to/python`
   - `export PADDLEOCR_VL_USE_GPU=true`

## Output

The current formatter outputs plain text with layout preserved using spacing heuristics.
Future output formats (Markdown/HTML) can be added in `Sources/ocr-screenshot/LayoutFormatter.swift`.

## Notes

- PaddleOCR runs locally with no network dependency once the model is installed.
- The Paddle runner streams PNG data to Python over stdin (no files written).
- If PaddleOCR is unavailable or fails, the app falls back to the built-in Vision OCR automatically.
- To force Vision OCR, set `OCR_BACKEND=vision`.
- For troubleshooting, run with `OCR_SELFTEST=1` (optional `OCR_SELFTEST_LOOP=3`) to show a test window, capture it, and log clipboard updates.
- Crop padding defaults to 8 points. Override with `OCR_CROP_PADDING` (set to `0` to disable).
- OCR merges Paddle + Vision by default for completeness; set `OCR_COMBINE_BACKENDS=0` to disable.
- OCR runs a second preprocessing pass by default; set `OCR_MULTI_PASS=0` to disable.

## Structure

- `Sources/ocr-screenshot/SelectionOverlay.swift`: selection UI
- `Sources/ocr-screenshot/ScreenCapture.swift`: screenshot capture
- `Sources/ocr-screenshot/OCRProcessor.swift`: OCR and bounding boxes
- `Sources/ocr-screenshot/PaddleOCRRunner.swift`: PaddleOCR-VL bridge
- `Sources/ocr-screenshot/Resources/paddle_ocr_vl.py`: PaddleOCR-VL runner script
- `Sources/ocr-screenshot/LayoutFormatter.swift`: deterministic layout formatting
- `Sources/ocr-screenshot/ClipboardWriter.swift`: clipboard output
