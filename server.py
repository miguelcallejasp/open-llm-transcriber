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

    WHISPER_STREAM_MIN_SECONDS / WHISPER_STREAM_MAX_SECONDS /
    WHISPER_STREAM_PAUSE_SECONDS
                   Tuning for the experimental streaming endpoint
                   (see "Streaming" below)              (default: 1.5 / 12 / 0.3)

EXPERIMENT — streaming (``POST /stream/chunk``):
    The dictation hotkey can send audio *while* recording, in ~2 s WAV
    chunks tagged with an ``X-Session`` id. The server appends them to a
    per-session buffer and, whenever it sees a pause in speech, transcribes
    everything up to that pause and returns it immediately, so text can be
    pasted piece by piece instead of after the whole recording. ``X-Final: 1``
    flushes what is left and closes the session.

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
import re
import sys
import tempfile
import threading
import time

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

# --- Streaming experiment knobs ---
SAMPLE_RATE = 16000
# Never commit a piece shorter than this (gives Whisper enough context).
STREAM_MIN_SECONDS = float(os.environ.get("WHISPER_STREAM_MIN_SECONDS", "1.5"))
# If no pause is found for this long, cut at the quietest recent point anyway.
STREAM_MAX_SECONDS = float(os.environ.get("WHISPER_STREAM_MAX_SECONDS", "12"))
# How long speech must drop out for it to count as a pause worth cutting at.
STREAM_PAUSE_SECONDS = float(os.environ.get("WHISPER_STREAM_PAUSE_SECONDS", "0.3"))
STREAM_SESSION_TTL = 600  # seconds of inactivity before a session is dropped

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


# --- Streaming experiment ----------------------------------------------------
class StreamSession:
    """Audio buffered for one in-progress dictation (keyed by X-Session)."""

    def __init__(self, language: str) -> None:
        self.language = language
        self.buffer = np.zeros(0, dtype=np.float32)
        self.committed: list[str] = []
        self.touched = time.monotonic()
        self.lock = threading.Lock()


SESSIONS: dict[str, StreamSession] = {}
SESSIONS_LOCK = threading.Lock()


def _session(sid: str, language: str) -> StreamSession:
    now = time.monotonic()
    with SESSIONS_LOCK:
        for key in [k for k, v in SESSIONS.items() if now - v.touched > STREAM_SESSION_TTL]:
            log.info("Stream %s expired", key)
            del SESSIONS[key]
        sess = SESSIONS.get(sid)
        if sess is None:
            sess = SESSIONS[sid] = StreamSession(language)
        sess.touched = now
        return sess


def _window_db(audio: "np.ndarray", win: int = SAMPLE_RATE // 10) -> "np.ndarray":
    """Per-100 ms-window RMS in dBFS (empty array if shorter than one window)."""
    n = audio.size // win
    if n == 0:
        return np.zeros(0)
    frames = audio[: n * win].reshape(n, win)
    rms = np.sqrt(np.mean(np.square(frames, dtype=np.float64), axis=1))
    return 20.0 * np.log10(np.maximum(rms, 1e-6))


def _find_split(audio: "np.ndarray") -> "int | None":
    """Pick a sample index to cut the buffer at, or None to keep waiting.

    Preferred: the middle of the *last* pause (>= STREAM_PAUSE_SECONDS of quiet
    windows) that begins after STREAM_MIN_SECONDS of audio — so we commit as
    much finished speech as possible and keep only the in-progress tail.
    Fallback: once the buffer exceeds STREAM_MAX_SECONDS, cut at the quietest
    window of the last 3 s so a long run-on sentence still flows out.
    """
    win = SAMPLE_RATE // 10
    db = _window_db(audio, win)
    n = db.size
    min_win = int(STREAM_MIN_SECONDS * 10)
    if n <= min_win:
        return None

    # "Quiet" is relative to how loud the speech in this buffer is, but never
    # louder than the global silence floor.
    loud = float(np.percentile(db, 90))
    floor = min(SILENCE_DBFS, loud - 15.0)
    quiet = db < floor
    need = max(1, int(round(STREAM_PAUSE_SECONDS * 10)))

    best = None
    start = None
    for i in range(n + 1):
        is_quiet = i < n and quiet[i]
        if is_quiet and start is None:
            start = i
        elif not is_quiet and start is not None:
            if i - start >= need and start >= min_win:
                best = (start, i)
            start = None
    if best is not None:
        a, b = best
        return ((a + b) // 2) * win

    if n >= int(STREAM_MAX_SECONDS * 10):
        lo = max(min_win, n - 30)
        idx = lo + int(np.argmin(db[lo:]))
        return idx * win
    return None


def _transcribe_piece(sess: StreamSession, piece: "np.ndarray") -> str:
    """Run Whisper on one committed piece, using earlier text as context."""
    if _is_silent(piece):
        return ""
    options = _transcribe_options(sess.language)
    context = " ".join(sess.committed)[-200:]
    if context:
        options["initial_prompt"] = context
    with TRANSCRIBE_LOCK:
        result = MODEL.transcribe(piece, **options)
    text = result["text"].strip()
    if not text or _looks_hallucinated(text):
        return ""
    sess.committed.append(text)
    return text


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
        if self.path == "/transcribe":
            self._handle_transcribe()
        elif self.path == "/stream/chunk":
            self._handle_stream_chunk()
        else:
            self._send_json(404, {"error": "Not found"})

    def _local_only(self) -> bool:
        """True if the request comes from this machine (see ALLOWED_HOSTS)."""
        host = _host_only(self.headers.get("Host", ""))
        if host and host not in ALLOWED_HOSTS:
            return False
        origin = self.headers.get("Origin")
        if origin and _host_only(origin) not in ALLOWED_HOSTS:
            return False
        return True

    def _read_body(self, allow_empty: bool = False) -> "bytes | None":
        """Validate Content-Length and read the body; sends the error itself."""
        try:
            length = int(self.headers.get("Content-Length", 0))
        except (TypeError, ValueError):
            self._send_json(400, {"error": "Invalid Content-Length header"})
            return None
        if length <= 0:
            if allow_empty:
                return b""
            self._send_json(400, {"error": "Empty request body"})
            return None
        if length > MAX_UPLOAD_BYTES:
            self._send_json(413, {"error": "Audio upload too large"})
            return None
        return self.rfile.read(length)

    def _handle_stream_chunk(self) -> None:
        """EXPERIMENT: append a chunk to a session; return any newly final text."""
        if not self._local_only():
            self._send_json(403, {"error": "Forbidden"})
            return
        if not MODEL_READY.is_set():
            self._send_json(503, {"error": "The Whisper model is still loading — try again shortly."})
            return
        sid = self.headers.get("X-Session", "").strip()
        if not sid or len(sid) > 64:
            self._send_json(400, {"error": "Missing or invalid X-Session header"})
            return
        final = self.headers.get("X-Final", "0").strip() == "1"
        language = self.headers.get("X-Language", "auto")
        body = self._read_body(allow_empty=final)
        if body is None:
            return

        samples = np.zeros(0, dtype=np.float32)
        if body:
            suffix = _audio_suffix(self.headers.get("Content-Type", ""))
            with tempfile.NamedTemporaryFile(suffix=suffix, delete=False) as tmp:
                tmp.write(body)
                audio_path = tmp.name
            try:
                samples = whisper.load_audio(audio_path)
            except Exception:  # noqa: BLE001
                log.exception("Could not decode stream chunk")
                self._send_json(400, {"error": "Could not decode audio chunk"})
                return
            finally:
                os.unlink(audio_path)

        sess = _session(sid, language)
        t0 = time.monotonic()
        try:
            with sess.lock:
                sess.buffer = np.concatenate([sess.buffer, samples])
                pieces: list[np.ndarray] = []
                if final:
                    pieces.append(sess.buffer)
                    sess.buffer = np.zeros(0, dtype=np.float32)
                else:
                    cut = _find_split(sess.buffer)
                    if cut:
                        pieces.append(sess.buffer[:cut])
                        sess.buffer = sess.buffer[cut:]
                texts = [t for t in (_transcribe_piece(sess, p) for p in pieces) if t]
                text = " ".join(texts)
                buffered = sess.buffer.size / SAMPLE_RATE
                payload: dict[str, object] = {
                    "text": text, "final": final, "buffered_seconds": round(buffered, 2),
                }
                if final:
                    full = " ".join(sess.committed)
                    payload["full"] = full
                    payload["saved"] = None
                    if full:
                        stamp = datetime.datetime.now().strftime("%Y-%m-%d_%H-%M-%S")
                        out_path = os.path.join(TRANSCRIPTS_DIR, f"{stamp}.txt")
                        with open(out_path, "w", encoding="utf-8") as f:
                            f.write(full + "\n")
                        payload["saved"] = out_path
                    with SESSIONS_LOCK:
                        SESSIONS.pop(sid, None)
            log.info(
                "Stream %s: +%.1fs%s -> %d piece(s) %r, %.1fs buffered, took %.2fs",
                sid[-6:], samples.size / SAMPLE_RATE, " FINAL" if final else "",
                len(pieces), text[:60], buffered, time.monotonic() - t0,
            )
            self._send_json(200, payload)
        except Exception:  # noqa: BLE001
            log.exception("Stream chunk failed")
            self._send_json(500, {"error": "Transcription failed — see server logs."})

    def _handle_transcribe(self) -> None:

        if not MODEL_READY.is_set():
            self._send_json(503, {"error": "The Whisper model is still loading — try again shortly."})
            return
        if not self._local_only():
            self._send_json(403, {"error": "Forbidden"})
            return
        audio = self._read_body()
        if audio is None:
            return

        language = self.headers.get("X-Language", "auto")
        suffix = _audio_suffix(self.headers.get("Content-Type", ""))

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
