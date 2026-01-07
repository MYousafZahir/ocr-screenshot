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

## Installer (plug and play)

Run the installer to set up Python venvs, download models, and build the app:

```bash
./install.sh
```

Optional flags:
- `--no-permissions` skips opening System Settings.
- `--no-start` skips starting the app.

The installer writes `.scap.env` with model paths and uses it automatically when you run `./scap`.

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
- Clipboard is cleared when a capture starts to avoid stale pastes; set `OCR_CLEAR_CLIPBOARD_ON_CAPTURE=0` to keep the previous clipboard until results arrive.
- Tables are emitted as pipe-delimited Markdown when column alignment is detected; set `OCR_TABLE_FORMAT=0` to disable or `OCR_TABLE_MARKDOWN=0` to omit the header separator row.
- Crop padding defaults to 8 points. Override with `OCR_CROP_PADDING` (set to `0` to disable).
- OCR merges Paddle + Vision when quality is low; set `OCR_COMBINE_BACKENDS=0` to disable.
- OCR runs a second preprocessing pass when quality is low; set `OCR_MULTI_PASS=0` to disable.
- Low-quality OCR triggers a secondary backend pass (and optional Vision fallback). Control with `OCR_QUALITY_FALLBACK=0` and `OCR_QUALITY_THRESHOLD=0.62`.
- Qwen3-1.7B (Q4 GGUF) post-processing is enabled by default. Disable with `OCR_DANUBE_POSTPROCESS=0`.
- The downloader requires Q4 GGUFs and falls back to Qwen2.5-1.5B Q4 if needed. Set `DANUBE_ALLOW_NON_Q4=1` to allow larger quantizations.
- Configure the model source with `DANUBE_MODEL_REPO`, `DANUBE_MODEL_FILE`, `DANUBE_MODEL_PATH`, `DANUBE_MODEL_DIR`, or a direct `DANUBE_MODEL_URL`.
- Tune runtime with `DANUBE_N_CTX` (default 2048), `DANUBE_N_THREADS`, and `DANUBE_GPU_LAYERS`.
- On first run, the app creates a local Python venv and downloads the model; this can take a while.
- If a model repo is gated, set `HUGGINGFACE_TOKEN` (or `HF_TOKEN`) or log in with `huggingface-cli login`.

## Structure

- `Sources/ocr-screenshot/SelectionOverlay.swift`: selection UI
- `Sources/ocr-screenshot/ScreenCapture.swift`: screenshot capture
- `Sources/ocr-screenshot/OCRProcessor.swift`: OCR and bounding boxes
- `Sources/ocr-screenshot/PaddleOCRRunner.swift`: PaddleOCR-VL bridge
- `Sources/ocr-screenshot/Resources/paddle_ocr_vl.py`: PaddleOCR-VL runner script
- `Sources/ocr-screenshot/LayoutFormatter.swift`: deterministic layout formatting
- `Sources/ocr-screenshot/ClipboardWriter.swift`: clipboard output
