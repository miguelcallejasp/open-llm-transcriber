#!/usr/bin/env python
"""Local Whisper transcription server.

A tiny, dependency-light HTTP server that powers a fully-local voice
transcription app. It serves the static front-end from ``web/`` and exposes a
single ``POST /transcribe`` endpoint that accepts a recorded audio blob, runs it
through OpenAI Whisper (loaded once at startup and kept warm), saves a
timestamped transcript, and returns the text as JSON.

Everything runs on your own machine — audio is never uploaded anywhere.

The same endpoint powers the system-wide dictation hotkey (see
``hammerspoon/dictation.lua``), which records a WAV with ffmpeg and posts it
here. ``GET /health`` reports whether the model has finished loading so the
menu-bar indicator can show "ready" vs "starting".

Configuration (environment variables, all optional):
    WHISPER_HOST   Interface to bind to                     (default: 127.0.0.1)
    WHISPER_PORT   Port to listen on                        (default: 8765)
    WHISPER_MODEL  Whisper model to load                    (default: turbo)
    WHISPER_HALLUCINATION_SILENCE_THRESHOLD
                   Seconds of silence used to reject likely
                   hallucinations                              (default: 2.0)
    WHISPER_SILENCE_DBFS
                   Loudness floor for speech, in dBFS. If even the
                   loudest tenth of a recording (100 ms windows)
                   stays below this, it is treated as silence and
                   returns empty text instead of letting Whisper
                   invent words. Lower it (e.g. -40) if quiet
                   speech is being dropped                      (default: -32)

Run:
    ./start.sh                 (recommended on macOS)
    .venv/bin/python server.py
"""

from __future__ import annotations

import datetime
import http.server
import json
import logging
import os
import shutil
import socketserver
import sys
import tempfile
import re
import threading

import numpy as np
import whisper

# --- Configuration -----------------------------------------------------------
HOST = os.environ.get("WHISPER_HOST", "127.0.0.1")
PORT = int(os.environ.get("WHISPER_PORT", "8765"))
MODEL_NAME = os.environ.get("WHISPER_MODEL", "turbo")
HALLUCINATION_SILENCE_THRESHOLD = float(
    os.environ.get("WHISPER_HALLUCINATION_SILENCE_THRESHOLD", "2.0")
)
SILENCE_DBFS = float(os.environ.get("WHISPER_SILENCE_DBFS", "-32"))

# Whisper (especially `turbo`) confidently invents a handful of stock phrases
# when fed silence or room noise — subtitle credits, "Thank you." and so on.
# If the *entire* result is one of these, it is noise, not dictation.
HALLUCINATION_PHRASES = re.compile(
    r"^(?:"
    r"thank you\.?|thanks for watching\.?|thank you for watching\.?|"
    r"subtitles? by .*|subtitled by .*|"
    r"субтитры сделал .*|субтитры .*|"
    r"字幕.*|ご視聴ありがとうございました.*|"
    r"you\.?|bye\.?|\.+"
    r")$",
    re.IGNORECASE,
)

HERE = os.path.dirname(os.path.abspath(__file__))
WEB_DIR = os.path.join(HERE, "web")
TRANSCRIPTS_DIR = os.path.join(HERE, "transcripts")

# Reject absurdly large uploads outright (audio blobs are small). 200 MB is far
# more than any reasonable recording yet still guards against a bad request.
MAX_UPLOAD_BYTES = 200 * 1024 * 1024

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(levelname)-7s %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger("whisper-server")

MODEL: "whisper.Whisper | None" = None
MODEL_READY = threading.Event()

# Map the client's Content-Type to a file suffix so ffmpeg gets a sensible hint.
# The browser sends application/octet-stream (WebM); the dictation hotkey sends
# audio/wav. Anything unknown falls back to .webm, which is what we always
# assumed before.
AUDIO_SUFFIXES = {
    "audio/wav": ".wav",
    "audio/x-wav": ".wav",
    "audio/wave": ".wav",
    "audio/webm": ".webm",
    "audio/ogg": ".ogg",
    "audio/mp4": ".m4a",
    "audio/x-m4a": ".m4a",
    "audio/mpeg": ".mp3",
    "audio/flac": ".flac",
}

# The server has no authentication by design — it is meant to be reached only
# from this machine. To keep it that way we accept requests whose Host/Origin
# resolve to localhost (plus whatever address we were told to bind to). This
# blocks DNS-rebinding and cross-site POSTs from other pages in the browser.
ALLOWED_HOSTS = {"127.0.0.1", "localhost", "::1", HOST}

# Whisper's transcribe() is not safe to call concurrently on a shared model, and
# ThreadingTCPServer can dispatch overlapping requests, so serialize them.
TRANSCRIBE_LOCK = threading.Lock()


def _host_only(value: str) -> str:
    """Return just the hostname from a Host or Origin header value.

    Strips any scheme, path, and ``:port`` (handling ``[::1]:8765`` too).
    """
    value = value.strip()
    if "://" in value:               # Origin carries a scheme
        value = value.split("://", 1)[1]
    value = value.split("/", 1)[0]   # drop any path
    if value.startswith("["):        # bracketed IPv6, e.g. [::1]:8765
        return value[1:].split("]", 1)[0]
    if ":" in value:                 # strip :port
        value = value.rsplit(":", 1)[0]
    return value


def _check_ffmpeg() -> None:
    """Exit early with an actionable message if ffmpeg is unavailable.

    Whisper shells out to ffmpeg to decode audio; without it transcription fails
    deep inside the request with a cryptic error, so we check up front.
    """
    if shutil.which("ffmpeg") is None:
        log.error("ffmpeg was not found on your PATH.")
        log.error("Whisper needs ffmpeg to decode audio. Install it with:")
        log.error("    macOS:         brew install ffmpeg")
        log.error("    Debian/Ubuntu: sudo apt install ffmpeg")
        sys.exit(1)


def _load_model() -> None:
    """Load the model and flip MODEL_READY. Runs in a background thread so the
    server can answer /health (and tell clients to wait) while loading."""
    global MODEL
    log.info("Loading Whisper '%s' model (this can take a few seconds)...", MODEL_NAME)
    try:
        MODEL = whisper.load_model(MODEL_NAME)
    except Exception:  # noqa: BLE001 - surface the real error, then give up
        log.exception("Failed to load the Whisper model")
        os._exit(1)
    MODEL_READY.set()
    log.info("Model ready. Open http://%s:%s in your browser.", HOST, PORT)


def _speech_level_dbfs(audio: "np.ndarray", sample_rate: int = 16000) -> float:
    """Loudness of the *loud parts* of a recording, in dBFS.

    The signal is cut into 100 ms windows and the 90th-percentile window RMS is
    returned. This ignores pauses between sentences (which drag the overall RMS
    down) while still reading low for steady room noise, which is what makes it
    a usable "was anything actually said?" test. 0 dBFS is full scale.
    """
    if audio.size == 0:
        return -120.0
    win = max(1, sample_rate // 10)
    usable = audio[: (audio.size // win) * win]
    if usable.size == 0:                      # shorter than one window
        usable = audio
    frames = usable.reshape(-1, win) if usable.size >= win else usable.reshape(1, -1)
    rms = np.sqrt(np.mean(np.square(frames, dtype=np.float64), axis=1))
    return 20.0 * np.log10(max(float(np.percentile(rms, 90)), 1e-6))


def _is_silent(audio: "np.ndarray") -> bool:
    return _speech_level_dbfs(audio) < SILENCE_DBFS


def _looks_hallucinated(text: str) -> bool:
    return bool(HALLUCINATION_PHRASES.match(text.strip()))


def _audio_suffix(content_type: str) -> str:
    """Pick a temp-file suffix from a Content-Type header (see AUDIO_SUFFIXES)."""
    mime = content_type.split(";", 1)[0].strip().lower()
    return AUDIO_SUFFIXES.get(mime, ".webm")


def _transcribe_options(language: str) -> dict[str, object]:
    options: dict[str, object] = {
        "fp16": False,
        "word_timestamps": True,
        "hallucination_silence_threshold": HALLUCINATION_SILENCE_THRESHOLD,
    }
    if language and language != "auto":
        options["language"] = language
    return options


class Handler(http.server.SimpleHTTPRequestHandler):
    """Serves the static front-end and handles transcription requests."""

    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=WEB_DIR, **kwargs)

    def log_message(self, fmt, *args):  # noqa: A003 - silence default access log
        # Keep the console quiet except for our own structured logging.
        pass

    def _send_json(self, status: int, payload: dict) -> None:
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:  # noqa: N802 - required by BaseHTTPRequestHandler
        if self.path == "/health":
            self._send_json(200, {"ready": MODEL_READY.is_set(), "model": MODEL_NAME})
            return
        super().do_GET()

    def do_POST(self) -> None:  # noqa: N802 - required by BaseHTTPRequestHandler
        if self.path != "/transcribe":
            self._send_json(404, {"error": "Not found"})
            return

        if not MODEL_READY.is_set():
            self._send_json(503, {"error": "The Whisper model is still loading — try again shortly."})
            return

        # Only accept requests that originate from this machine (see ALLOWED_HOSTS).
        host = _host_only(self.headers.get("Host", ""))
        if host and host not in ALLOWED_HOSTS:
            self._send_json(403, {"error": "Forbidden"})
            return
        origin = self.headers.get("Origin")
        if origin and _host_only(origin) not in ALLOWED_HOSTS:
            self._send_json(403, {"error": "Forbidden"})
            return

        # Validate the upload size before reading the body.
        try:
            length = int(self.headers.get("Content-Length", 0))
        except (TypeError, ValueError):
            self._send_json(400, {"error": "Invalid Content-Length header"})
            return
        if length <= 0:
            self._send_json(400, {"error": "Empty request body"})
            return
        if length > MAX_UPLOAD_BYTES:
            self._send_json(413, {"error": "Audio upload too large"})
            return

        language = self.headers.get("X-Language", "auto")
        suffix = _audio_suffix(self.headers.get("Content-Type", ""))
        audio = self.rfile.read(length)

        # Persist the raw recording to a temp file for ffmpeg/whisper to read.
        with tempfile.NamedTemporaryFile(suffix=suffix, delete=False) as tmp:
            tmp.write(audio)
            audio_path = tmp.name

        try:
            # Decode once (ffmpeg) so we can measure loudness before spending
            # time on Whisper; the same array is then transcribed directly.
            samples = whisper.load_audio(audio_path)
            level = _speech_level_dbfs(samples)
            if _is_silent(samples):
                log.info("Skipped: recording is silent (%.1f dBFS)", level)
                self._send_json(200, {"text": "", "language": language, "saved": None})
                return

            kwargs = _transcribe_options(language)
            log.info("Transcribing (%s, %.1f dBFS)...", language, level)
            with TRANSCRIBE_LOCK:
                result = MODEL.transcribe(samples, **kwargs)
            text = result["text"].strip()
            detected = result.get("language", language)

            if _looks_hallucinated(text):
                log.info("Skipped: likely hallucination %r", text)
                self._send_json(200, {"text": "", "language": detected, "saved": None})
                return

            stamp = datetime.datetime.now().strftime("%Y-%m-%d_%H-%M-%S")
            out_path = os.path.join(TRANSCRIPTS_DIR, f"{stamp}.txt")
            with open(out_path, "w", encoding="utf-8") as f:
                f.write(text + "\n")
            log.info("Done -> %s", out_path)

            self._send_json(200, {"text": text, "language": detected, "saved": out_path})
        except Exception:  # noqa: BLE001 - never leak internals to the page
            log.exception("Transcription failed")
            self._send_json(500, {"error": "Transcription failed — see server logs."})
        finally:
            os.unlink(audio_path)


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


def main() -> None:
    _check_ffmpeg()
    os.makedirs(TRANSCRIPTS_DIR, exist_ok=True)
    # Bind first, then load the model in the background: /health answers
    # immediately with ready=false, and /transcribe returns 503 until ready.
    threading.Thread(target=_load_model, name="load-model", daemon=True).start()
    with Server((HOST, PORT), Handler) as httpd:
        log.info("Listening on http://%s:%s (model loading in background)", HOST, PORT)
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            log.info("Shutting down.")


if __name__ == "__main__":
    main()
