#!/usr/bin/env python3
"""Local CrisperWhisper HTTP sidecar for Alethia (macOS).

Endpoints:
  GET  /health
  POST /transcribe  — multipart field `audio` (WAV) or raw WAV body
      query/form: mode=intended|verbatim, language=en, word_timestamps=1

Env:
  ALETHIA_CRISPER_HOST (default 127.0.0.1)
  ALETHIA_CRISPER_PORT (default 8765)
  ALETHIA_CRISPER_MODEL (default turbo)
  ALETHIA_CRISPER_STUB=1 — no model load; returns deterministic stub text
"""

from __future__ import annotations

import os
import tempfile
from typing import Any

from flask import Flask, jsonify, request

app = Flask(__name__)

_MODEL = None
_STUB = os.environ.get("ALETHIA_CRISPER_STUB", "").strip() in ("1", "true", "yes")
_MODEL_NAME = os.environ.get("ALETHIA_CRISPER_MODEL", "turbo").strip() or "turbo"


def get_model():
    global _MODEL
    if _STUB:
        return None
    if _MODEL is None:
        from crisperwhisper import CrisperWhisperModel

        # ct2 wheels are Linux-only; on macOS always use transformers.
        backend = os.environ.get("ALETHIA_CRISPER_BACKEND", "transformers")
        _MODEL = CrisperWhisperModel(_MODEL_NAME, backend=backend)
    return _MODEL


@app.get("/health")
def health():
    return jsonify(
        {
            "ok": True,
            "stub": _STUB,
            "model": _MODEL_NAME,
            "loaded": _STUB or _MODEL is not None,
        }
    )


def _segments_from_result(result: Any, fallback_duration_s: float) -> list[dict]:
    segs: list[dict] = []
    words = getattr(result, "words", None) or []
    if words:
        # Group into coarse segments by contiguous words when available.
        texts = []
        start = float(getattr(words[0], "start", 0.0) or 0.0)
        end = start
        for w in words:
            t = (getattr(w, "word", None) or getattr(w, "text", None) or "").strip()
            if not t:
                continue
            texts.append(t)
            end = float(getattr(w, "end", end) or end)
        if texts:
            segs.append(
                {
                    "start_ms": int(start * 1000),
                    "end_ms": max(int(end * 1000), 1),
                    "text": " ".join(texts),
                }
            )
            return segs

    # Fallback: whole text as one segment
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
        # Deterministic stub for CI / offline unit wiring.
        return jsonify(
            {
                "text": "stub transcript",
                "segments": [{"start_ms": 0, "end_ms": 1000, "text": "stub transcript"}],
                "mode": mode,
                "stub": True,
            }
        )

    model = get_model()
    with tempfile.NamedTemporaryFile(suffix=".wav", delete=True) as tmp:
        tmp.write(audio_bytes)
        tmp.flush()
        kwargs: dict[str, Any] = {
            "language": language,
            "mode": mode,
            # Word timestamps force attention paths that pull in ctranslate2
            # via hallucination.py on macOS; keep off unless explicitly requested
            # and ct2 is available.
            "word_timestamps": False,
            "hallucination_mitigation": False,
        }
        if word_ts:
            # Prefer timestamps when asked, but still disable mitigation (no ct2 on macOS).
            kwargs["word_timestamps"] = True
        try:
            result = model.transcribe(tmp.name, **kwargs)
        except ModuleNotFoundError as exc:
            # Retry without timestamps / mitigation if ct2 accidentally pulled in.
            if "ctranslate2" in str(exc):
                kwargs["word_timestamps"] = False
                kwargs["hallucination_mitigation"] = False
                result = model.transcribe(tmp.name, **kwargs)
            else:
                return jsonify({"error": str(exc), "stub": False}), 500
        except Exception as exc:  # noqa: BLE001 — surface to client
            return jsonify({"error": str(exc), "stub": False}), 500

    # Rough duration from WAV header if present
    duration_s = 1.0
    if len(audio_bytes) > 44:
        # PCM 16-bit mono @ 16k → (bytes-44)/2/16000
        duration_s = max((len(audio_bytes) - 44) / 2 / 16_000.0, 0.1)

    segments = _segments_from_result(result, duration_s)
    text = (getattr(result, "text", None) or "").strip()
    if not text and segments:
        text = " ".join(s["text"] for s in segments)

    return jsonify({"text": text, "segments": segments, "mode": mode, "stub": False})


def main():
    host = os.environ.get("ALETHIA_CRISPER_HOST", "127.0.0.1")
    port = int(os.environ.get("ALETHIA_CRISPER_PORT", "8765"))
    # Eager-load unless stub (first request otherwise is very slow).
    if not _STUB:
        print(f"Loading CrisperWhisper model={_MODEL_NAME}…", flush=True)
        get_model()
        print("Model ready.", flush=True)
    else:
        print("CrisperWhisper sidecar running in STUB mode.", flush=True)

    from waitress import serve

    print(f"Listening on http://{host}:{port}", flush=True)
    serve(app, host=host, port=port, threads=2)


if __name__ == "__main__":
    main()
