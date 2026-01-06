#!/usr/bin/env python3
import json
import os
import re
import sys
import urllib.error
import urllib.request


def log(message: str) -> None:
    sys.stderr.write(f"[postprocess] {message}\n")
    sys.stderr.flush()


def _env(name: str, default: str) -> str:
    return os.environ.get(name, default)


def _load_hf_token() -> str:
    for key in ("HUGGINGFACE_TOKEN", "HF_TOKEN", "HUGGINGFACEHUB_TOKEN", "HF_ACCESS_TOKEN"):
        value = os.environ.get(key)
        if value:
            return value.strip()

    token_paths = [
        os.path.expanduser("~/.huggingface/token"),
        os.path.expanduser("~/.cache/huggingface/token"),
        os.path.expanduser("~/.config/huggingface/token"),
    ]
    for path in token_paths:
        try:
            if os.path.isfile(path):
                with open(path, "r", encoding="utf-8") as handle:
                    value = handle.read().strip()
                    if value:
                        return value
        except Exception:
            continue

    return ""


def _request(url: str, token: str):
    headers = {"User-Agent": "ocr-screenshot/1.0"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    req = urllib.request.Request(url, headers=headers)
    return urllib.request.urlopen(req)


def _select_repo():
    override = os.environ.get("DANUBE_MODEL_REPO")
    if override:
        return override, [override]
    candidates = [
        "Qwen/Qwen3-1.7B-Instruct-GGUF",
        "Qwen/Qwen3-1.7B-GGUF",
        "Qwen/Qwen3-1.7B-Instruct",
        "Qwen/Qwen3-1.7B",
        "bartowski/Qwen3-1.7B-Instruct-GGUF",
        "bartowski/Qwen3-1.7B-GGUF",
        "lmstudio-community/Qwen3-1.7B-GGUF",
        "Qwen/Qwen2.5-1.5B-Instruct-GGUF",
        "Qwen/Qwen2.5-1.5B-GGUF",
        "Qwen/Qwen2.5-1.5B-Instruct",
        "Qwen/Qwen2.5-1.5B",
        "bartowski/Qwen2.5-1.5B-Instruct-GGUF",
        "bartowski/Qwen2.5-1.5B-GGUF",
    ]
    return candidates[0], candidates


def _list_repo_files(repo: str, token: str):
    url = f"https://huggingface.co/api/models/{repo}"
    try:
        with _request(url, token) as response:
            payload = json.loads(response.read().decode("utf-8"))
            return [item.get("rfilename", "") for item in payload.get("siblings", [])]
    except urllib.error.HTTPError as exc:
        if exc.code == 401:
            if token:
                log(f"Repo lookup unauthorized for {repo}. Accept the model license on Hugging Face.")
            else:
                log(f"Repo lookup unauthorized for {repo}. Set HUGGINGFACE_TOKEN or login with huggingface-cli.")
        else:
            log(f"Repo lookup failed for {repo}: {exc}")
    except Exception as exc:
        log(f"Repo lookup error for {repo}: {exc}")
    return []


def _choose_gguf(files, require_q4: bool):
    ggufs = [f for f in files if f.endswith(".gguf")]
    if not ggufs:
        return ""
    preferred = [
        "Q4_K_M",
        "Q4_K",
        "Q4",
        "q4",
    ]
    for tag in preferred:
        for name in ggufs:
            if tag in name:
                return name
    if require_q4:
        return ""
    return ggufs[0]


def _download_file(url: str, destination: str, token: str) -> None:
    try:
        with _request(url, token) as response, open(destination, "wb") as handle:
            while True:
                chunk = response.read(1024 * 1024)
                if not chunk:
                    break
                handle.write(chunk)
    except Exception as exc:
        if os.path.exists(destination):
            try:
                os.remove(destination)
            except Exception:
                pass
        raise RuntimeError(f"Failed to download model: {exc}") from exc


def _ensure_model():
    model_path = os.environ.get("DANUBE_MODEL_PATH")
    if model_path and os.path.isfile(model_path):
        return model_path

    model_dir = _env("DANUBE_MODEL_DIR", os.path.expanduser("~/Library/Application Support/ocr-screenshot/danube/models"))
    os.makedirs(model_dir, exist_ok=True)
    model_url = os.environ.get("DANUBE_MODEL_URL")
    if model_url:
        filename = model_url.split("/")[-1].split("?")[0]
        if filename:
            direct_path = os.path.join(model_dir, filename)
            if os.path.isfile(direct_path):
                return direct_path
            token = _load_hf_token()
            log(f"Downloading model from URL: {filename}...")
            _download_file(model_url, direct_path, token)
            return direct_path
    model_file = os.environ.get("DANUBE_MODEL_FILE")
    if model_file:
        candidate = os.path.join(model_dir, model_file)
        if os.path.isfile(candidate):
            return candidate

    repo_override = os.environ.get("DANUBE_MODEL_REPO")
    if repo_override:
        repos_to_try = [repo_override]
    else:
        first, candidates = _select_repo()
        repos_to_try = [first] + [repo for repo in candidates if repo != first]

    token = _load_hf_token()
    selected_repo = None
    selected_file = None
    require_q4 = os.environ.get("DANUBE_ALLOW_NON_Q4", "0") == "0"
    for repo in repos_to_try:
        files = _list_repo_files(repo, token)
        chosen = _choose_gguf(files, require_q4=require_q4)
        if chosen:
            selected_repo = repo
            selected_file = chosen
            break

    if not selected_repo or not selected_file:
        raise RuntimeError("Could not locate a Q4 GGUF model for Qwen3-1.7B (or fallback Qwen2.5-1.5B).")

    log(f"Selected model {selected_repo}/{selected_file}")
    model_path = os.path.join(model_dir, selected_file)
    if os.path.isfile(model_path):
        return model_path
    url = f"https://huggingface.co/{selected_repo}/resolve/main/{selected_file}"
    log(f"Downloading model {selected_repo}/{selected_file}...")
    _download_file(url, model_path, token)
    return model_path


def _make_prompt(text: str) -> str:
    return (
        "You are a text post-processor.\n"
        "Rules:\n"
        "- Only adjust whitespace, line breaks, and indentation.\n"
        "- Fix missing spaces between words (example: \"andthe\" -> \"and the\").\n"
        "- Do not change words, punctuation, or numbers.\n"
        "- Do not add or remove content.\n"
        "- Preserve table pipes and dashes (\"|\" and \"-\") if present.\n"
        "- If table rows are present, keep the number of rows and column separators unchanged.\n"
        "- Add a blank line before and after any Markdown table block.\n"
        "- Add a blank line before multiple-choice answer blocks (A., B., C., etc.).\n"
        "- Do not repeat the input or any markers.\n"
        "Return only the corrected text.\n"
        "End your response with <<<ENDOUT>>> on its own line.\n\n"
        "Text:\n"
        "<<<TEXT>>>\n"
        f"{text}\n"
        "<<<END>>>\n\n"
        "Corrected:\n"
        "<<<OUT>>>\n"
    )


def _max_tokens(text: str, n_ctx: int) -> int:
    estimate = max(128, len(text) // 2)
    return max(128, min(2048, min(estimate, max(128, n_ctx - 128))))


def _load_llm(model_path: str):
    from llama_cpp import Llama

    n_ctx = int(_env("DANUBE_N_CTX", "4096"))
    n_threads = int(_env("DANUBE_N_THREADS", str(max(1, (os.cpu_count() or 4) - 1))))
    n_gpu_layers = int(_env("DANUBE_GPU_LAYERS", "0"))
    log(f"Loading model {os.path.basename(model_path)} (ctx={n_ctx}, threads={n_threads}, gpu_layers={n_gpu_layers})...")
    llm = Llama(
        model_path=model_path,
        n_ctx=n_ctx,
        n_threads=n_threads,
        n_gpu_layers=n_gpu_layers,
        seed=0,
        verbose=False,
    )
    return llm, n_ctx


def _process_one(llm, n_ctx: int, text: str) -> str:
    prompt = _make_prompt(text)
    max_tokens = _max_tokens(text, n_ctx)
    result = llm(
        prompt,
        max_tokens=max_tokens,
        temperature=0.0,
        top_p=0.9,
        repeat_penalty=1.05,
        stop=["<<<ENDOUT>>>"],
    )
    output = result["choices"][0]["text"]
    cleaned = _clean_output(output)
    if not cleaned:
        return ""
    cleaned = _add_table_spacing(cleaned)
    return _add_option_spacing(cleaned)


def _strip_code_fences(text: str) -> str:
    cleaned = text
    if cleaned.startswith("```"):
        cleaned = re.sub(r"^```[^\n]*\n", "", cleaned)
    if cleaned.endswith("```"):
        cleaned = re.sub(r"\n```$", "", cleaned)
    return cleaned


def _strip_prefix_lines(text: str) -> str:
    lines = text.splitlines()
    while lines:
        line = lines[0].strip()
        if re.match(r"(?i)^(the\s+)?corrected\s+text\s+is\s+as\s+follows:?\s*$", line):
            lines.pop(0)
            continue
        break
    return "\n".join(lines).strip()


def _extract_between(text: str, start: str, end: str) -> str:
    start_idx = text.rfind(start)
    if start_idx == -1:
        return ""
    start_idx += len(start)
    end_idx = text.find(end, start_idx)
    if end_idx == -1:
        return ""
    return text[start_idx:end_idx].strip()


def _clean_output(output: str) -> str:
    cleaned = output.strip()
    if not cleaned:
        return ""
    cleaned = _strip_code_fences(cleaned).strip()
    cleaned = _strip_prefix_lines(cleaned)

    if "<<<TEXT>>>" in cleaned and "<<<END>>>" in cleaned:
        extracted = _extract_between(cleaned, "<<<TEXT>>>", "<<<END>>>")
        if extracted:
            cleaned = extracted

    if "<<<OUT>>>" in cleaned:
        tail = cleaned.rsplit("<<<OUT>>>", 1)[1].strip()
        if tail:
            cleaned = tail

    for marker in ("<<<TEXT>>>", "<<<END>>>", "<<<OUT>>>", "<<<ENDOUT>>>"):
        cleaned = cleaned.replace(marker, "")

    cleaned = _strip_prefix_lines(cleaned)
    cleaned = _strip_code_fences(cleaned).strip()
    return cleaned


def _add_table_spacing(text: str) -> str:
    lines = text.splitlines()
    if not lines:
        return text

    def is_table_line(line: str) -> bool:
        stripped = line.lstrip()
        return stripped.startswith("|") and stripped.count("|") >= 2

    result = []
    i = 0
    while i < len(lines):
        if is_table_line(lines[i]):
            start = i
            while i < len(lines) and is_table_line(lines[i]):
                i += 1
            if result and result[-1].strip():
                result.append("")
            result.extend(lines[start:i])
            if i < len(lines) and lines[i].strip():
                result.append("")
        else:
            result.append(lines[i])
            i += 1
    return "\n".join(result).rstrip()


def _add_option_spacing(text: str) -> str:
    lines = text.splitlines()
    if not lines:
        return text

    option_pattern = re.compile(r"^\s*([A-H]|\d{1,2})[.)]\s+")
    result = []
    in_option_block = False

    for line in lines:
        stripped = line.strip()
        is_option = bool(option_pattern.match(line))
        if is_option:
            if not in_option_block and result and result[-1].strip():
                result.append("")
            in_option_block = True
            result.append(line)
            continue

        result.append(line)
        if stripped:
            in_option_block = False

    return "\n".join(result).rstrip()


def main() -> int:
    try:
        model_path = _ensure_model()
        llm, n_ctx = _load_llm(model_path)
    except Exception as exc:
        log(str(exc))
        return 2
    sys.stdout.write(json.dumps({"ready": True}) + "\n")
    sys.stdout.flush()

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            payload = json.loads(line)
            text = payload.get("text", "")
            if not text:
                sys.stdout.write(json.dumps({"text": ""}) + "\n")
                sys.stdout.flush()
                continue
            output = _process_one(llm, n_ctx, text)
            sys.stdout.write(json.dumps({"text": output}) + "\n")
            sys.stdout.flush()
        except Exception as exc:
            log(f"Processing error: {exc}")
            sys.stdout.write(json.dumps({"text": ""}) + "\n")
            sys.stdout.flush()

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
