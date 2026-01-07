#!/usr/bin/env python3
import argparse
import json
import os
import sys


def _error(message: str, code: int) -> None:
    print(message, file=sys.stderr)
    sys.exit(code)


def _image_size(path: str):
    try:
        from PIL import Image
        with Image.open(path) as image:
            return image.size
    except Exception:
        try:
            import cv2
            image = cv2.imread(path)
            if image is None:
                return None
            height, width = image.shape[:2]
            return width, height
        except Exception:
            return None


def _is_line_entry(entry):
    if not isinstance(entry, (list, tuple)) or len(entry) < 2:
        return False
    box = entry[0]
    text_entry = entry[1]
    if not isinstance(box, (list, tuple)):
        return False
    if not isinstance(text_entry, (list, tuple)):
        return False
    return True


def _flatten_result(result):
    if not result:
        return []
    if len(result) == 1 and isinstance(result[0], list) and result[0] and _is_line_entry(result[0][0]):
        return result[0]
    if _is_line_entry(result[0]):
        return result
    return []


def _has_model_files(path: str) -> bool:
    if not path or not os.path.isdir(path):
        return False
    markers = (
        "inference.yml",
        "inference.pdmodel",
        "inference.pdiparams",
        "model.pdmodel",
        "model.pdiparams",
        "model.pdparams",
    )
    return any(os.path.exists(os.path.join(path, marker)) for marker in markers)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--image")
    parser.add_argument("--stdin", action="store_true")
    args = parser.parse_args()

    try:
        from paddleocr import PaddleOCR
    except Exception as exc:
        _error("Failed to import paddleocr: %s" % exc, 2)

    model_dir = os.environ.get("PADDLEOCR_VL_MODEL_DIR")
    det_dir = os.environ.get("PADDLEOCR_VL_DET_DIR")
    rec_dir = os.environ.get("PADDLEOCR_VL_REC_DIR")
    cls_dir = os.environ.get("PADDLEOCR_VL_CLS_DIR")
    lang = os.environ.get("PADDLEOCR_VL_LANG", "en")
    use_gpu = os.environ.get("PADDLEOCR_VL_USE_GPU", "false").lower() in ("1", "true", "yes")

    if model_dir and not (det_dir or rec_dir or cls_dir):
        det_dir = os.path.join(model_dir, "det")
        rec_dir = os.path.join(model_dir, "rec")
        cls_dir = os.path.join(model_dir, "cls")

    if not det_dir or not rec_dir:
        _error(
            "Set PADDLEOCR_VL_MODEL_DIR (with det/rec/cls subdirs) or PADDLEOCR_VL_DET_DIR and PADDLEOCR_VL_REC_DIR.",
            3,
        )

    use_angle_cls = _has_model_files(cls_dir)
    if not use_angle_cls:
        cls_dir = None

    try:
        import inspect
        signature = inspect.signature(PaddleOCR)
        params = signature.parameters
    except Exception:
        params = {}

    kwargs = {"lang": lang}

    if "text_detection_model_dir" in params:
        kwargs["text_detection_model_dir"] = det_dir
    else:
        kwargs["det_model_dir"] = det_dir

    if "text_recognition_model_dir" in params:
        kwargs["text_recognition_model_dir"] = rec_dir
    else:
        kwargs["rec_model_dir"] = rec_dir

    if use_angle_cls:
        if "textline_orientation_model_dir" in params:
            kwargs["textline_orientation_model_dir"] = cls_dir
        elif "cls_model_dir" in params:
            kwargs["cls_model_dir"] = cls_dir

    if "use_textline_orientation" in params:
        kwargs["use_textline_orientation"] = use_angle_cls
    elif "use_angle_cls" in params:
        kwargs["use_angle_cls"] = use_angle_cls

    if "use_gpu" in params:
        kwargs["use_gpu"] = use_gpu
    elif "device" in params:
        kwargs["device"] = "gpu" if use_gpu else "cpu"
    elif "device_type" in params:
        kwargs["device_type"] = "gpu" if use_gpu else "cpu"

    if "show_log" in params:
        kwargs["show_log"] = False

    ocr = PaddleOCR(**kwargs)

    if args.stdin:
        try:
            import cv2
            import numpy as np
        except Exception as exc:
            _error("Failed to import cv2/numpy: %s" % exc, 4)
        payload = sys.stdin.buffer.read()
        if not payload:
            _error("No image data received on stdin", 5)
        image = cv2.imdecode(np.frombuffer(payload, np.uint8), cv2.IMREAD_COLOR)
        if image is None:
            _error("Failed to decode image from stdin", 6)
        height, width = image.shape[:2]
        result = ocr.ocr(image, cls=use_angle_cls)
    else:
        if not args.image:
            _error("Missing --image or --stdin", 7)
        size = _image_size(args.image)
        if not size:
            _error("Failed to read image size", 8)
        width, height = size
        result = ocr.ocr(args.image, cls=use_angle_cls)
    lines = _flatten_result(result)

    boxes = []
    for line in lines:
        if not _is_line_entry(line):
            continue
        box = line[0]
        text_info = line[1]
        text = text_info[0] if text_info else ""
        if not text or not str(text).strip():
            continue

        xs = [point[0] for point in box]
        ys = [point[1] for point in box]
        min_x, max_x = min(xs), max(xs)
        min_y, max_y = min(ys), max(ys)
        rect_width = max_x - min_x
        rect_height = max_y - min_y
        flipped_y = height - max_y

        boxes.append(
            {
                "text": str(text).strip(),
                "rect": [float(min_x), float(flipped_y), float(rect_width), float(rect_height)],
            }
        )

    payload = {"width": float(width), "height": float(height), "boxes": boxes}
    sys.stdout.write(json.dumps(payload))


if __name__ == "__main__":
    main()
