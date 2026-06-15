# Open LLM Transcriber 🎙️

A tiny, fully-local voice transcription app. Record from your microphone in the
browser, transcribe it on your own machine with OpenAI's
[Whisper](https://github.com/openai/whisper), and get clean text ready to copy —
**nothing ever leaves your computer.**

- 🎙️ One-click record with a live microphone visualizer
- 🧠 Whisper running 100% locally — no cloud, no API keys, **$0**
- 🌐 Plain `index.html` front-end + a small Python server (stdlib only)
- 🌍 Language picker (Auto-detect / English / Spanish — easy to extend)
- 💾 Every transcription auto-saved to `transcripts/` with a timestamp
- 🖥️ Optional one-click macOS Dock app

---

## Quick start (macOS)

One line — clone and run the installer:

```bash
git clone https://github.com/miguelcallejasp/open-llm-transcriber.git && cd open-llm-transcriber && ./install.sh
```

`install.sh` checks your tools, installs **ffmpeg** if needed, creates a virtual
environment, installs dependencies, and builds the **Open LLM Transcriber** Dock app.
When it finishes, drag `Open LLM Transcriber.app` onto your Dock — from then on a single
click launches the server and opens the app in your browser.

> Prefer to do it by hand, or on Linux? See [Manual install](#manual-install).

---

## Requirements

| Requirement | Details |
|-------------|---------|
| **OS**      | macOS for the one-click installer/Dock app. The server itself runs anywhere. |
| **Python**  | 3.9 – 3.12 (3.11 recommended — see `.python-version`). |
| **ffmpeg**  | Required — Whisper uses it to decode audio. `brew install ffmpeg` |
| **Whisper** | `openai-whisper==20250625` (pinned in `requirements.txt`). |
| **Port**    | **8765** on `127.0.0.1` (localhost only). Override with `WHISPER_PORT`. |
| **Browser** | Any modern browser (Chrome, Safari, Firefox, Edge). |

---

## How it works

The browser can't run shell commands, so a thin local server sits in the middle:

```
[ web/index.html ]  --record audio-->  POST /transcribe  -->  [ server.py ]
    (browser)                                                      |
        ^                                                       whisper
        |                                                          |
        +---------------- JSON { text } <---------------------------+
                                                  (also writes transcripts/<timestamp>.txt)
```

`server.py` loads the model **once** at startup and keeps it warm, so every
recording after the first is fast. For a deeper dive see
**[ARCHITECTURE.md](ARCHITECTURE.md)**.

---

## Using it

1. Pick a language (or leave it on Auto-detect).
2. Click **Record** (or press **Spacebar**) → speak → click **Stop**.
3. Click **Send** to transcribe.
4. **Copy** the result — it's also saved to `transcripts/<timestamp>.txt`.

---

## Manual install

```bash
# 1. Clone
git clone https://github.com/miguelcallejasp/open-llm-transcriber.git
cd open-llm-transcriber

# 2. Install ffmpeg (Whisper needs it to decode audio)
brew install ffmpeg            # macOS
# sudo apt install ffmpeg      # Debian/Ubuntu

# 3. Create the virtual environment
python3 -m venv .venv
source .venv/bin/activate

# 4. Install dependencies
pip install -r requirements.txt
```

The Whisper model (~1.5 GB for `turbo`) downloads automatically on first run and
is cached in `~/.cache/whisper`. To pre-download it:

```bash
.venv/bin/python -c "import whisper; whisper.load_model('turbo')"
```

### Run

```bash
./start.sh          # starts the server and opens your browser (macOS)
```

Or run the server directly (any OS):

```bash
.venv/bin/python server.py
# then open http://localhost:8765/
```

Stop it with `Ctrl+C`.

---

## Configuration

All optional, via environment variables:

| Variable        | Default     | Purpose                          |
|-----------------|-------------|----------------------------------|
| `WHISPER_HOST`  | `127.0.0.1` | Interface to bind to             |
| `WHISPER_PORT`  | `8765`      | Port to listen on                |
| `WHISPER_MODEL` | `turbo`     | Whisper model (see table below)  |

```bash
WHISPER_MODEL=small WHISPER_PORT=9000 .venv/bin/python server.py
```

Available models — bigger is more accurate but slower and larger:

| Model    | Params | Approx size | Notes                                   |
|----------|--------|-------------|-----------------------------------------|
| `tiny`   | 39M    | ~75 MB      | Fastest, least accurate                 |
| `base`   | 74M    | ~140 MB     | Light                                   |
| `small`  | 244M   | ~480 MB     | Good balance                            |
| `medium` | 769M   | ~1.5 GB     | Strong, esp. for non-English            |
| `large`  | 1550M  | ~3 GB       | Best accuracy                           |
| `turbo`  | 809M   | ~1.5 GB     | **Default** — near-large quality, ~8× faster |

To add languages, add `<option>`s to the `#language` dropdown in
`web/index.html` using [ISO 639-1 codes](https://en.wikipedia.org/wiki/List_of_ISO_639_language_codes)
(e.g. `<option value="fr">French</option>`).

---

## The macOS Dock app

`install.sh` builds it for you, or rebuild it any time:

```bash
./build-app.sh      # creates "Open LLM Transcriber.app"
```

Then drag `Open LLM Transcriber.app` onto your Dock. Clicking it opens a Terminal
running the server and pops your browser at the app.

> On first launch macOS asks for permission to control Terminal — click OK.
> Stop the server with `Ctrl+C` in the Terminal window it opens.

---

## Project layout

```
.
├── server.py            # local HTTP server + Whisper transcription
├── start.sh             # launch the server + open the browser (macOS)
├── install.sh           # one-line macOS installer
├── build-app.sh         # (re)build the macOS Dock app + icon
├── requirements.txt     # pinned Python dependencies
├── .python-version      # recommended Python version
├── web/                 # the front-end
│   ├── index.html
│   ├── css/styles.css
│   ├── js/app.js
│   └── fonts/
├── icon/                # Dock app icon artwork
├── transcripts/         # saved transcriptions (git-ignored)
├── ARCHITECTURE.md      # how it all fits together
└── LICENSE              # MIT
```

---

## Privacy

Everything runs locally. Audio is sent only to `127.0.0.1` (your own machine),
transcribed offline, and never uploaded anywhere. Saved transcripts in
`transcripts/` are git-ignored so they're never committed.

---

## Troubleshooting

- **`ffmpeg not found`** → `brew install ffmpeg` (macOS) or
  `sudo apt install ffmpeg` (Debian/Ubuntu).
- **`CERTIFICATE_VERIFY_FAILED` on first model download** (python.org Python on
  macOS) → run the bundled certificate installer, e.g.
  `/Applications/Python\ 3.11/Install\ Certificates.command`.
- **Port already in use** → something is on `8765`; set `WHISPER_PORT` to a free
  port (and update the URL in `start.sh` if you use it).
- **Dock icon not updating** → macOS caches icons aggressively. Try
  `sudo rm -rf /Library/Caches/com.apple.iconservices.store && sudo killall Dock Finder`.

---

## License

[MIT](LICENSE) © 2026 Miguel Callejas.
