# Architecture

Open LLM Transcriber is deliberately small. It is two moving parts — a static
browser front-end and a tiny Python server — wired together over `localhost`.
This document explains how they fit together and why the project is built the
way it is.

## Overview

```
┌──────────────────────────────────────────────────────────────────┐
│  Browser (web/index.html + app.js)                                 │
│                                                                    │
│   ┌──────────┐   getUserMedia    ┌─────────────────────────────┐   │
│   │ Record   │ ────────────────► │ MediaRecorder → WebM blob   │   │
│   │ Stop     │                   │ AnalyserNode → canvas viz   │   │
│   │ Send     │                   └──────────────┬──────────────┘   │
│   │ Copy     │                                  │                  │
│   └──────────┘                                  │ POST /transcribe │
└─────────────────────────────────────────────────┼──────────────────┘
                                                  │  (audio bytes +
                                                  │   X-Language header)
                                                  ▼
┌──────────────────────────────────────────────────────────────────┐
│  server.py  (Python stdlib http.server, 127.0.0.1:8765)            │
│                                                                    │
│   1. Write blob to a temp .webm file                               │
│   2. ffmpeg decodes the audio        ◄── system dependency         │
│   3. whisper model.transcribe(...)   ◄── loaded once, kept warm    │
│   4. Save transcripts/<timestamp>.txt                              │
│   5. Return JSON { text, language, saved }                         │
└──────────────────────────────────────────────────────────────────┘
```

Nothing leaves the machine: the browser talks only to `127.0.0.1`, and the
model runs locally.

A second, optional client — the **system-wide dictation hotkey** — reuses the
same server (see [System-wide dictation](#system-wide-dictation-macos)):

```
⌃⌥D ──► Hammerspoon (hammerspoon/dictation.lua)
          │  ffmpeg -f avfoundation  → /tmp/olt-dictation-*.wav
          │  curl POST /transcribe   (Content-Type: audio/wav)
          ▼
        server.py ──► { text } ──► clipboard ──► ⌘V into the frontmost app
```

## Components

### Front-end — `web/`
- **`index.html`** — markup only; links the stylesheet and script.
- **`css/styles.css`** — the neo-brutalist visual design.
- **`js/app.js`** — all behaviour:
  - **Recording** via the `MediaRecorder` API. Audio chunks are collected into a
    single `audio/webm` blob on stop.
  - **Mic visualizer** via the Web Audio API (`AudioContext` → `AnalyserNode`),
    drawn to a `<canvas>` on each animation frame. This doubles as the
    "your microphone is working" indicator.
  - **Transcription** via `fetch("/transcribe", …)` with the audio blob as the
    body and the selected language code in an `X-Language` header.
  - **Clipboard** via `navigator.clipboard.writeText`.
  - **Spacebar** toggles recording when focus is not in the output box.
- **`fonts/`** — self-hosted Cascadia Code so the app stays fully offline.

### Back-end — `server.py`
A subclass of `http.server.SimpleHTTPRequestHandler` served by a
`ThreadingTCPServer`:
- Static `GET` requests are served from `web/`.
- `POST /transcribe` is the only dynamic route. It validates the upload size,
  writes the bytes to a temp file, runs Whisper, persists the transcript, and
  returns JSON. The temp file is always cleaned up in a `finally` block.

### Health — `GET /health`
Returns `{ "ready": bool, "model": "<name>" }`. The server binds its port
immediately and loads the model in a background thread, so clients can tell
"starting" from "offline". `POST /transcribe` answers `503` until `ready`.

## Request lifecycle (`POST /transcribe`)

1. Client sends raw audio bytes with an `X-Language` header (`auto`, `en`,
   `es`, …). The browser sends WebM as `application/octet-stream`; the
   dictation hotkey sends `audio/wav`.
2. Server validates `Content-Length` (rejects empty / oversized requests).
3. Bytes are written to a temporary file whose suffix follows the
   `Content-Type` (`.wav`, `.webm`, …) so ffmpeg gets a good hint.
4. The file is decoded with **ffmpeg** (`whisper.load_audio`) and its loudness
   is measured. If even the loudest 10 % of 100 ms windows sit below
   `WHISPER_SILENCE_DBFS`, the request is answered with empty text and Whisper
   is never run — otherwise Whisper confidently invents stock phrases for
   silence.
5. `MODEL.transcribe(...)` runs on the decoded samples with word timestamps and
   silence-hallucination filtering enabled.
6. If the whole result is one of Whisper's well-known silence hallucinations
   (`HALLUCINATION_PHRASES`), it is dropped and empty text is returned.
7. Otherwise the text is trimmed and written to
   `transcripts/<YYYY-MM-DD_HH-MM-SS>.txt`.
8. Server responds `{ "text", "language", "saved" }` (`saved` is `null` when
   nothing was transcribed); on error it responds with a JSON `{ "error" }` and
   an appropriate status code.

## System-wide dictation (macOS)

`install-dictation.sh` adds two pieces around the unchanged server:

- **launchd agent** — `~/Library/LaunchAgents/com.openllmtranscriber.server.plist`
  runs `.venv/bin/python server.py` with `RunAtLoad` + `KeepAlive`, so the model
  is loaded once at login and stays warm. stdout/stderr go to `logs/server.log`.
  The web app keeps working against this same instance.
- **Hammerspoon** — `hammerspoon/dictation.lua` is loaded from
  `~/.hammerspoon/init.lua`. It owns:
  - the **⌃⌥D** hotkey (toggle: start / stop) and **Esc** to cancel while
    recording;
  - the **menu-bar item**, which polls `GET /health` every 5 s and shows a
    monochrome mic glyph (drawn with `hs.canvas`, exported as a template image
    so macOS tints it for light/dark menu bars): full = ready, dimmed =
    loading, slashed = offline; red `● m:ss` text while recording and `…`
    while transcribing. Its menu offers language, auto-paste and toast
    toggles, open web app, transcripts, server log, and restart server via
    `launchctl kickstart`;
  - **recording**: `ffmpeg -f avfoundation -i ":<default input device>"` to a
    16 kHz mono WAV in the temp dir. A start chime is played *first* and
    recording begins when it ends, so the chime is not captured. Stopping sends
    `SIGINT` so ffmpeg finalizes the WAV header (ffmpeg exits 255 in that case,
    so success is judged by the file, not the exit code);
  - **transcription**: `curl --data-binary @file` to `/transcribe` with
    `Content-Type: audio/wav`;
  - **delivery**: text + trailing space → pasteboard, then a simulated ⌘V
    (`hs.eventtap.keyStroke`, requires Accessibility) if auto-paste is on, and a
    small toast at the top of the screen with the pasted text (optional).

Why Hammerspoon rather than a Python menu-bar app? Global hotkeys, menu-bar
items, pasteboard and synthetic keystrokes all need a proper Cocoa app with
Accessibility entitlement; Hammerspoon is that app, is scriptable in ~400 lines
of Lua, and needs no extra Python dependencies. Why ffmpeg for capture? It is
already a hard dependency of Whisper and reads the mic directly via
AVFoundation, so no new native audio library is needed.

## Configuration & extension points

| What        | Where                                    | Default     |
|-------------|------------------------------------------|-------------|
| Host        | `WHISPER_HOST` env var                    | `127.0.0.1` |
| Port        | `WHISPER_PORT` env var                    | `8765`      |
| Model       | `WHISPER_MODEL` env var                   | `turbo`     |
| Hallucination silence | `WHISPER_HALLUCINATION_SILENCE_THRESHOLD` env var | `2.0` seconds |
| Silence floor | `WHISPER_SILENCE_DBFS` env var            | `-32` dBFS  |
| Dictation hotkey | `config.hotkey` in `hammerspoon/dictation.lua` | ⌃⌥D |
| Languages   | `<select id="language">` in `index.html`  | auto/en/es  |

Whisper models (swap via `WHISPER_MODEL`):

| Model    | Params | Approx size | Notes                                   |
|----------|--------|-------------|-----------------------------------------|
| `tiny`   | 39M    | ~75 MB      | Fastest, least accurate                 |
| `base`   | 74M    | ~140 MB     | Light                                   |
| `small`  | 244M   | ~480 MB     | Good balance                            |
| `medium` | 769M   | ~1.5 GB     | Strong, esp. for non-English            |
| `large`  | 1550M  | ~3 GB       | Best accuracy                           |
| `turbo`  | 809M   | ~1.5 GB     | **Default** — near-large quality, ~8× faster |

## Design decisions

- **Why the standard library instead of Flask/FastAPI?** The app needs exactly
  one dynamic endpoint and a static file server. `http.server` does both with
  zero extra dependencies, which keeps installs fast and the footprint tiny —
  the whole point of a $0, fully-local tool.
- **Why load the model once at startup?** Loading `turbo` takes a few seconds;
  keeping it warm in memory makes every recording after the first feel instant.
- **Why `turbo` by default?** It is near-`large` quality at roughly 8× the speed
  for transcription, which is the only thing this app does.
- **Why save every transcript?** A timestamped `transcripts/` history is a cheap
  safety net and makes the tool useful as a lightweight voice-notes log. The
  folder is git-ignored so recordings are never committed.

## Privacy & security model

- The server binds to `127.0.0.1` by default — it is not reachable from other
  machines on the network.
- Audio is processed locally and never uploaded to any third party.
- There are no API keys, accounts, or telemetry.
- Saved transcripts live under `transcripts/`, which is git-ignored.
