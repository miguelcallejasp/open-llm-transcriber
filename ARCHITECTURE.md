# Architecture

Whisper Local is deliberately small. It is two moving parts — a static
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

## Request lifecycle (`POST /transcribe`)

1. Browser sends raw WebM audio bytes with an `X-Language` header
   (`auto`, `en`, `es`, …).
2. Server validates `Content-Length` (rejects empty / oversized requests).
3. Bytes are written to a temporary `.webm` file.
4. `MODEL.transcribe(path, fp16=False[, language=code])` runs. Whisper invokes
   **ffmpeg** internally to decode the audio.
5. The result text is trimmed and written to
   `transcripts/<YYYY-MM-DD_HH-MM-SS>.txt`.
6. Server responds `{ "text", "language", "saved" }`; on error it responds with
   a JSON `{ "error" }` and an appropriate status code.

## Configuration & extension points

| What        | Where                                    | Default     |
|-------------|------------------------------------------|-------------|
| Host        | `WHISPER_HOST` env var                    | `127.0.0.1` |
| Port        | `WHISPER_PORT` env var                    | `8765`      |
| Model       | `WHISPER_MODEL` env var                   | `turbo`     |
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
