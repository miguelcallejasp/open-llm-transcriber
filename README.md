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
- ⌨️ **System-wide dictation**: press **⌃⌥D** in any app, speak, press again —
  the text is pasted where your cursor is, with a 🎙 menu-bar indicator

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

Want it everywhere, not just in the browser? Add the dictation hotkey:

```bash
./install-dictation.sh
```

See [System-wide dictation](#system-wide-dictation-d) for what that sets up.

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

## System-wide dictation (⌃⌥D)

`install-dictation.sh` turns the transcriber into a macOS dictation tool that
works in any app:

1. Press **⌃⌥D** (Control + Option + D). You hear a short chime and the menu-bar
   mic turns into a red **● 0:03** timer.
2. Speak.
3. Press **⌃⌥D** again. The audio goes to the local server, the text is copied
   to your clipboard and pasted at your cursor. A small overlay shows what was
   pasted.

Press **Esc** while recording to cancel. Recordings that are silent, or where
Whisper only produced one of its well-known "noise" phrases, are discarded
instead of pasted.

### The menu-bar indicator

| Icon        | Meaning                                                    |
|-------------|------------------------------------------------------------|
| 🎙          | Server running, model loaded — ready to dictate            |
| 🎙 ⏳       | Server starting, Whisper model still loading               |
| 🎙 off      | Server not running (click → **Start server**)              |
| ● 0:07      | Recording (red). Press ⌃⌥D to stop, Esc to cancel          |
| 🎙 ✍️       | Transcribing                                               |

Click it for the language picker, an "auto-paste" toggle (off = clipboard
only), the web app, the transcripts folder, the server log, and server restart.

### What the installer sets up

- **A launchd agent** (`~/Library/LaunchAgents/com.openllmtranscriber.server.plist`)
  that starts `server.py` at login and keeps it running, so the model is always
  warm. Logs go to `logs/server.log`. The web app at `http://localhost:8765/`
  keeps working as before — same server.
- **[Hammerspoon](https://www.hammerspoon.org)** (installed via Homebrew if
  missing), a free, open-source macOS automation tool. It provides the global
  hotkey and the menu-bar item by loading `hammerspoon/dictation.lua`; the
  installer adds one `dofile(...)` line to `~/.hammerspoon/init.lua`.
- Recording is done by **ffmpeg** from your default input device; the result is
  posted to the same `POST /transcribe` endpoint the browser uses.

Two one-time macOS permissions are needed, and macOS prompts for both:
**Accessibility** for Hammerspoon (to press ⌘V for you) and **Microphone**
(the first time you record).

To change the hotkey or languages, edit the `config` table at the top of
`hammerspoon/dictation.lua` and pick **Reload Hammerspoon config** from the 🎙
menu. To remove everything: `./install-dictation.sh --uninstall`.

> If you run `./start.sh` while the agent is running, it simply opens the
> browser — the agent already owns the port.

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

| Variable                                   | Default     | Purpose                                      |
|--------------------------------------------|-------------|----------------------------------------------|
| `WHISPER_HOST`                             | `127.0.0.1` | Interface to bind to                         |
| `WHISPER_PORT`                             | `8765`      | Port to listen on                            |
| `WHISPER_MODEL`                            | `turbo`     | Whisper model (see table below)              |
| `WHISPER_HALLUCINATION_SILENCE_THRESHOLD`  | `2.0`       | Silence seconds used to reject hallucinations |
| `WHISPER_SILENCE_DBFS`                     | `-32`       | Loudness floor (dBFS) below which a recording counts as silence |

```bash
WHISPER_MODEL=small WHISPER_PORT=9000 .venv/bin/python server.py
```

Whisper uses word timestamps to discard improbable text after silent periods.
Lower the hallucination threshold if trailing text persists; raise it if valid
speech after a pause is omitted.

Whisper also tends to *invent* text for pure silence ("Thank you.", subtitle
credits, …). The server measures the loudest tenth of each recording and skips
Whisper entirely when it stays under `WHISPER_SILENCE_DBFS`, returning empty
text. If quiet speech is being dropped, lower it (e.g. `-40`); if noise still
produces words, raise it (e.g. `-28`). The level of every request is logged.
For the launchd agent, set it in the plist's `EnvironmentVariables` or re-run
`WHISPER_SILENCE_DBFS=-40 ./install-dictation.sh`.

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
├── install-dictation.sh # system-wide ⌃⌥D dictation: launchd agent + Hammerspoon
├── hammerspoon/
│   └── dictation.lua    # hotkey, menu-bar indicator, record → transcribe → paste
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
├── logs/                # server.log from the launchd agent (git-ignored)
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
- **⌃⌥D copies but doesn't paste** → Hammerspoon needs Accessibility: System
  Settings → Privacy & Security → Accessibility → enable Hammerspoon.
- **Menu bar shows 🎙 off** → the launchd agent isn't running. Click the icon →
  **Start server**, or check `logs/server.log`. Re-run `./install-dictation.sh`
  if the plist is missing.
- **Nothing recorded / "Nothing heard"** → check the Microphone permission for
  Hammerspoon, and that your default input device is the one you expect
  (System Settings → Sound → Input). The server log shows each recording's level.
- **Two menu-bar icons from Hammerspoon** → the hammer icon is Hammerspoon's
  own; `dictation.lua` hides it on first run, or toggle it in Hammerspoon's
  preferences.

---

## Credits & third-party licenses

This project's own code is MIT-licensed (below). It also relies on third-party
components that retain their own licenses:

- **[OpenAI Whisper](https://github.com/openai/whisper)** — the speech model and
  library, MIT License.
- **[ffmpeg](https://ffmpeg.org)** — system dependency you install yourself
  (not bundled); used by Whisper to decode audio.
- **[Cascadia Code](https://github.com/microsoft/cascadia-code)** — the bundled
  UI font (`web/fonts/`), © Microsoft, licensed under the SIL Open Font License
  1.1. See [`web/fonts/Cascadia-Code-LICENSE.txt`](web/fonts/Cascadia-Code-LICENSE.txt).

---

## License

[MIT](LICENSE) © 2026 Miguel Callejas.
