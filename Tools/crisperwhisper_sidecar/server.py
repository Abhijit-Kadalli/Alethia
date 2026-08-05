#!/usr/bin/env python3
"""Local CrisperWhisper HTTP sidecar for Alethia (macOS).

Endpoints:
  GET  /health
  POST /transcribe  — multipart field `audio` (WAV) or raw WAV body
      query/form: mode=intended|verbatim, language=en, word_timestamps=0|1

Env:
  ALETHIA_CRISPER_HOST (default 127.0.0.1)
  ALETHIA_CRISPER_PORT (default 8765)
  ALETHIA_CRISPER_MODEL (default small — snappy dictation; use turbo for quality)
  ALETHIA_CRISPER_DEVICE (default auto — prefers MPS on Apple Silicon)
  ALETHIA_CRISPER_STUB=1 — no model load; returns deterministic stub text
"""

from __future__ import annotations

import os
import tempfile
import time
from typing import Any

from flask import Flask, jsonify, request

app = Flask(__name__)

_MODEL = None
_STUB = os.environ.get("ALETHIA_CRISPER_STUB", "").strip() in ("1", "true", "yes")
_MODEL_NAME = os.environ.get("ALETHIA_CRISPER_MODEL", "small").strip() or "small"
_DEVICE = os.environ.get("ALETHIA_CRISPER_DEVICE", "auto").strip() or "auto"
_LOAD_ERROR: str | None = None


def _resolve_device() -> str:
    if _DEVICE != "auto":
        return _DEVICE
    try:
        import torch

        if torch.backends.mps.is_available():
            return "mps"
    except Exception:
        pass
    return "cpu"


def get_model():
    global _MODEL, _LOAD_ERROR
    if _STUB:
        return None
    if _MODEL is None:
        from crisperwhisper import CrisperWhisperModel

        backend = os.environ.get("ALETHIA_CRISPER_BACKEND", "transformers")
        device = _resolve_device()
        print(f"Loading model={_MODEL_NAME} backend={backend} device={device}", flush=True)
        try:
            _MODEL = CrisperWhisperModel(
                _MODEL_NAME,
                backend=backend,
                device=device,
                compute_type="float16" if device in ("mps", "cuda") else "float32",
            )
            _LOAD_ERROR = None
        except Exception as exc:  # noqa: BLE001
            _LOAD_ERROR = str(exc)
            raise
    return _MODEL


@app.get("/health")
def health():
    return jsonify(
        {
            "ok": True,
            "stub": _STUB,
            "model": _MODEL_NAME,
            "device": None if _STUB else _resolve_device(),
            "loaded": _STUB or _MODEL is not None,
            "error": _LOAD_ERROR,
        }
    )


def _word_text(w: Any) -> str:
    return (getattr(w, "word", None) or getattr(w, "text", None) or "").strip()


def _segments_from_words(words: list[Any], fallback_duration_s: float, gap_s: float = 0.45) -> list[dict]:
    """Group timed words into phrase segments on pauses (for speaker turns)."""
    usable = []
    for w in words:
        t = _word_text(w)
        if not t:
            continue
        start = float(getattr(w, "start", 0.0) or 0.0)
        end = float(getattr(w, "end", start) or start)
        usable.append((start, end, t))
    if not usable:
        return []

    segs: list[dict] = []
    cur_words = [usable[0][2]]
    cur_start = usable[0][0]
    cur_end = usable[0][1]
    for start, end, t in usable[1:]:
        if start - cur_end >= gap_s or (end - cur_start) >= 3.0:
            text = " ".join(cur_words).strip()
            if text:
                segs.append(
                    {
                        "start_ms": int(cur_start * 1000),
                        "end_ms": max(int(cur_end * 1000), int(cur_start * 1000) + 1),
                        "text": text,
                    }
                )
            cur_words = [t]
            cur_start = start
            cur_end = end
        else:
            cur_words.append(t)
            cur_end = max(cur_end, end)
    text = " ".join(cur_words).strip()
    if text:
        segs.append(
            {
                "start_ms": int(cur_start * 1000),
                "end_ms": max(int(cur_end * 1000), int(cur_start * 1000) + 1),
                "text": text,
            }
        )
    if not segs:
        return []
    # Ensure coverage end isn't before fallback when needed
    if segs[-1]["end_ms"] < 1:
        segs[-1]["end_ms"] = max(int(fallback_duration_s * 1000), 1)
    return segs


def _segments_from_result(result: Any, fallback_duration_s: float) -> list[dict]:
    words = getattr(result, "words", None) or []
    if words:
        segs = _segments_from_words(list(words), fallback_duration_s)
        if segs:
            return segs

    text = (getattr(result, "text", None) or "").strip()
    if not text:
        return []
    return [
        {
            "start_ms": 0,
            "end_ms": max(int(fallback_duration_s * 1000), 1),
            "text": text,
        }
    ]


@app.post("/transcribe")
def transcribe():
    t0 = time.perf_counter()
    mode = (request.args.get("mode") or request.form.get("mode") or "intended").strip().lower()
    if mode not in ("intended", "verbatim"):
        mode = "intended"
    language = (request.args.get("language") or request.form.get("language") or "en").strip() or "en"
    word_ts = (request.args.get("word_timestamps") or request.form.get("word_timestamps") or "0") in (
        "1",
        "true",
        "yes",
    )

    audio_bytes: bytes | None = None
    if "audio" in request.files:
        audio_bytes = request.files["audio"].read()
    elif request.content_type and "wav" in request.content_type:
        audio_bytes = request.get_data()
    elif request.data:
        audio_bytes = request.get_data()

    if not audio_bytes:
        return jsonify({"error": "missing audio"}), 400

    if _STUB:
        return jsonify(
            {
                "text": "stub transcript",
                "segments": [{"start_ms": 0, "end_ms": 1000, "text": "stub transcript"}],
                "mode": mode,
                "stub": True,
                "elapsed_ms": 0,
            }
        )

    try:
        model = get_model()
    except Exception as exc:  # noqa: BLE001
        return jsonify({"error": f"model load failed: {exc}", "stub": False}), 503

    with tempfile.NamedTemporaryFile(suffix=".wav", delete=True) as tmp:
        tmp.write(audio_bytes)
        tmp.flush()
        kwargs: dict[str, Any] = {
            "language": language,
            "mode": mode,
            "word_timestamps": bool(word_ts),
            "hallucination_mitigation": False,
        }
        try:
            result = model.transcribe(tmp.name, **kwargs)
        except ModuleNotFoundError as exc:
            if "ctranslate2" in str(exc) and kwargs.get("word_timestamps"):
                kwargs["word_timestamps"] = False
                result = model.transcribe(tmp.name, **kwargs)
            else:
                return jsonify({"error": str(exc), "stub": False}), 500
        except Exception as exc:  # noqa: BLE001
            # Retry without word timestamps if attention path fails.
            if kwargs.get("word_timestamps"):
                try:
                    kwargs["word_timestamps"] = False
                    result = model.transcribe(tmp.name, **kwargs)
                except Exception as exc2:  # noqa: BLE001
                    return jsonify({"error": str(exc2), "stub": False}), 500
            else:
                return jsonify({"error": str(exc), "stub": False}), 500

    duration_s = 1.0
    if len(audio_bytes) > 44:
        duration_s = max((len(audio_bytes) - 44) / 2 / 16_000.0, 0.1)
    duration_s = max(float(getattr(result, "duration", 0) or 0), duration_s)

    segments = _segments_from_result(result, duration_s)
    text = (getattr(result, "text", None) or "").strip()
    if not text and segments:
        text = " ".join(s["text"] for s in segments)

    words_out: list[dict] = []
    for w in getattr(result, "words", None) or []:
        t = _word_text(w)
        if not t:
            continue
        start = float(getattr(w, "start", 0.0) or 0.0)
        end = float(getattr(w, "end", start) or start)
        words_out.append(
            {
                "word": t,
                "start_ms": int(start * 1000),
                "end_ms": max(int(end * 1000), int(start * 1000) + 1),
            }
        )

    elapsed_ms = int((time.perf_counter() - t0) * 1000)
    print(
        f"transcribe mode={mode} audio={duration_s:.2f}s elapsed={elapsed_ms}ms "
        f"segs={len(segments)} words={len(words_out)} chars={len(text)} word_ts={word_ts}",
        flush=True,
    )
    return jsonify(
        {
            "text": text,
            "segments": segments,
            "words": words_out,
            "mode": mode,
            "stub": False,
            "elapsed_ms": elapsed_ms,
        }
    )


def main():
    host = os.environ.get("ALETHIA_CRISPER_HOST", "127.0.0.1")
    port = int(os.environ.get("ALETHIA_CRISPER_PORT", "8765"))
    if not _STUB:
        print(f"Loading CrisperWhisper model={_MODEL_NAME}…", flush=True)
        get_model()
        print("Model ready.", flush=True)
    else:
        print("CrisperWhisper sidecar running in STUB mode.", flush=True)

    from waitress import serve

    print(f"Listening on http://{host}:{port}", flush=True)
    serve(app, host=host, port=port, threads=4)


if __name__ == "__main__":
    main()
