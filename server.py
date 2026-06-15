#!/usr/bin/env python
"""Local Whisper transcription server.

A tiny, dependency-light HTTP server that powers a fully-local voice
transcription app. It serves the static front-end from ``web/`` and exposes a
single ``POST /transcribe`` endpoint that accepts a recorded audio blob, runs it
through OpenAI Whisper (loaded once at startup and kept warm), saves a
timestamped transcript, and returns the text as JSON.

Everything runs on your own machine — audio is never uploaded anywhere.

Configuration (environment variables, all optional):
    WHISPER_HOST   Interface to bind to        (default: 127.0.0.1)
    WHISPER_PORT   Port to listen on           (default: 8765)
    WHISPER_MODEL  Whisper model to load       (default: turbo)

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

import whisper

# --- Configuration -----------------------------------------------------------
HOST = os.environ.get("WHISPER_HOST", "127.0.0.1")
PORT = int(os.environ.get("WHISPER_PORT", "8765"))
MODEL_NAME = os.environ.get("WHISPER_MODEL", "turbo")

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
    global MODEL
    log.info("Loading Whisper '%s' model (this can take a few seconds)...", MODEL_NAME)
    MODEL = whisper.load_model(MODEL_NAME)
    log.info("Model ready. Open http://%s:%s in your browser.", HOST, PORT)


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

    def do_POST(self) -> None:  # noqa: N802 - required by BaseHTTPRequestHandler
        if self.path != "/transcribe":
            self._send_json(404, {"error": "Not found"})
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
        audio = self.rfile.read(length)

        # Persist the raw recording to a temp file for ffmpeg/whisper to read.
        with tempfile.NamedTemporaryFile(suffix=".webm", delete=False) as tmp:
            tmp.write(audio)
            audio_path = tmp.name

        try:
            kwargs = {"fp16": False}
            # The UI sends ISO codes ("en", "es") or "auto" for detection.
            if language and language != "auto":
                kwargs["language"] = language
            log.info("Transcribing (%s)...", language)
            result = MODEL.transcribe(audio_path, **kwargs)
            text = result["text"].strip()
            detected = result.get("language", language)

            stamp = datetime.datetime.now().strftime("%Y-%m-%d_%H-%M-%S")
            out_path = os.path.join(TRANSCRIPTS_DIR, f"{stamp}.txt")
            with open(out_path, "w", encoding="utf-8") as f:
                f.write(text + "\n")
            log.info("Done -> %s", out_path)

            self._send_json(200, {"text": text, "language": detected, "saved": out_path})
        except Exception as exc:  # noqa: BLE001 - surface any error to the page
            log.exception("Transcription failed")
            self._send_json(500, {"error": str(exc)})
        finally:
            os.unlink(audio_path)


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


def main() -> None:
    _check_ffmpeg()
    os.makedirs(TRANSCRIPTS_DIR, exist_ok=True)
    _load_model()
    with Server((HOST, PORT), Handler) as httpd:
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            log.info("Shutting down.")


if __name__ == "__main__":
    main()
