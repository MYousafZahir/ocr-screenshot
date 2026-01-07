#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

log() {
  printf "[install] %s\n" "$*"
}

die() {
  printf "[install] ERROR: %s\n" "$*" >&2
  exit 1
}

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
app_support="${HOME}/Library/Application Support/ocr-screenshot"
paddle_root="${app_support}/paddle"
paddle_models="${paddle_root}/models"
paddle_venv="${paddle_root}/venv"
paddle_python="${paddle_venv}/bin/python3"
danube_root="${app_support}/danube"
danube_models="${danube_root}/models"
danube_venv="${danube_root}/venv"
danube_python="${danube_venv}/bin/python3"
env_file="${repo_dir}/.scap.env"
danube_script="${repo_dir}/Sources/ocr-screenshot/Resources/danube_postprocess.py"

skip_permissions=0
skip_start=0

for arg in "$@"; do
  case "$arg" in
    --no-permissions) skip_permissions=1 ;;
    --no-start) skip_start=1 ;;
    *)
      die "Unknown argument: $arg"
      ;;
  esac
done

if ! command -v python3 >/dev/null 2>&1; then
  die "python3 is required. Install Python 3 and re-run."
fi

if ! command -v swift >/dev/null 2>&1; then
  log "Swift not found. Triggering Xcode Command Line Tools install..."
  if ! xcode-select --install >/dev/null 2>&1; then
    log "Xcode Command Line Tools install prompt may already be open."
  fi
  die "Install Xcode Command Line Tools, then re-run this installer."
fi

mkdir -p "$paddle_root" "$paddle_models" "$danube_root" "$danube_models"

setup_venv() {
  local venv_path="$1"
  if [[ ! -x "${venv_path}/bin/python3" ]]; then
    log "Creating venv at $venv_path"
    python3 -m venv "$venv_path"
  fi
}

install_paddle() {
  log "Setting up PaddleOCR venv and libraries..."
  setup_venv "$paddle_venv"
  "$paddle_python" -m pip install --upgrade pip
  "$paddle_python" -m pip install paddlepaddle paddleocr pillow opencv-python numpy

  log "Downloading PaddleOCR models..."
  local det_dir="${paddle_models}/det"
  local rec_dir="${paddle_models}/rec"
  local cls_dir="${paddle_models}/cls"
  mkdir -p "$det_dir" "$rec_dir" "$cls_dir"

  "$paddle_python" - <<PY
import inspect
import os
from paddleocr import PaddleOCR

os.environ.setdefault("DISABLE_MODEL_SOURCE_CHECK", "True")
kwargs = {
    "det_model_dir": r"""$det_dir""",
    "rec_model_dir": r"""$rec_dir""",
    "cls_model_dir": r"""$cls_dir""",
    "use_gpu": False,
    "lang": "en",
}
sig = inspect.signature(PaddleOCR)
if "use_textline_orientation" in sig.parameters:
    kwargs["use_textline_orientation"] = True
elif "use_angle_cls" in sig.parameters:
    kwargs["use_angle_cls"] = True
if "show_log" in sig.parameters:
    kwargs["show_log"] = False
PaddleOCR(**kwargs)
print(r"""$det_dir""")
print(r"""$rec_dir""")
print(r"""$cls_dir""")
PY

  export PADDLEOCR_VL_PYTHON="$paddle_python"
  export PADDLEOCR_VL_DET_DIR="$det_dir"
  export PADDLEOCR_VL_REC_DIR="$rec_dir"
  export PADDLEOCR_VL_CLS_DIR="$cls_dir"
  log "PaddleOCR models ready."
}

install_danube() {
  log "Setting up post-processor (LLM) venv and model..."
  setup_venv "$danube_venv"
  "$danube_python" -m pip install --upgrade pip
  "$danube_python" -m pip install llama-cpp-python

  DANUBE_MODEL_DIR="$danube_models" "$danube_python" - <<PY
import importlib.util
import os

script_path = r"""$danube_script"""
spec = importlib.util.spec_from_file_location("danube_postprocess", script_path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
os.environ.setdefault("DANUBE_MODEL_DIR", r"""$danube_models""")
model_path = module._ensure_model()
print(f"Downloaded model: {model_path}")
PY
}

write_env_file() {
  if [[ -f "$env_file" ]]; then
    cp "$env_file" "${env_file}.bak.$(date +%s)"
  fi

  {
    echo "export PADDLEOCR_VL_PYTHON=\"${PADDLEOCR_VL_PYTHON}\""
    echo "export PADDLEOCR_VL_DET_DIR=\"${PADDLEOCR_VL_DET_DIR}\""
    echo "export PADDLEOCR_VL_REC_DIR=\"${PADDLEOCR_VL_REC_DIR}\""
    echo "export PADDLEOCR_VL_CLS_DIR=\"${PADDLEOCR_VL_CLS_DIR}\""
    echo "export DANUBE_MODEL_DIR=\"${danube_models}\""
    echo "export DANUBE_N_CTX=\"2048\""
  } > "$env_file"

  log "Wrote environment config to $env_file"
}

build_app() {
  log "Building release binary..."
  (cd "$repo_dir" && SWIFTPM_DISABLE_SANDBOX=1 swift build -c release)
}

prompt_permissions() {
  log "Opening System Settings for Screen Recording and Accessibility..."
  open "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture" || true
  open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" || true
  log "Enable Screen Recording + Accessibility for ocr-screenshot, then return here."
}

start_app() {
  log "Starting app..."
  "$repo_dir/scap" start
}

install_paddle
install_danube
write_env_file
build_app

if [[ "$skip_permissions" -eq 0 ]]; then
  prompt_permissions
fi

if [[ "$skip_start" -eq 0 ]]; then
  start_app
else
  log "Run ./scap start when ready."
fi

log "Install complete."
