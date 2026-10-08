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

See [Installation](#installation) for what that sets up and [Decommission](#decommission-uninstall) to remove it.

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

## Streaming dictation

Instead of waiting for the whole recording to finish before transcribing, the
hotkey now records in ~2 s chunks and sends them to the server *while you are
still talking*. The server buffers them and, every time it detects a pause in
your speech, transcribes everything up to that pause and returns it, so the
text is pasted sentence by sentence as you go. When you press ⌃⌥D to stop,
only the last unfinished phrase remains to be transcribed.

How it behaves:

- Text appears while you are still speaking, after each natural pause (about
  0.3 s of silence) once at least 1.5 s has been spoken.
- For a long dictation the wait after stopping is roughly one Whisper call
  (~3 s on an Apple Silicon CPU) instead of growing with the recording length.
- Pieces are only ever cut inside a pause, never mid-speech, unless no pause
  has been found for 12 s. Each piece is transcribed with the previous text as
  context to keep punctuation and casing consistent.

Timings are written to `logs/dictation.log` (per-chunk round trips and
"stop → final text") and `logs/server.log` (per-chunk Whisper time).

Switches: `streaming = true/false` (false = transcribe once after stopping) and
`chunkSeconds` in `hammerspoon/dictation.lua`; `WHISPER_STREAM_MIN_SECONDS`,
`WHISPER_STREAM_MAX_SECONDS` and `WHISPER_STREAM_PAUSE_SECONDS` on the server
(defaults 1.5 / 12 / 0.3). The web app is unaffected: it still uses the
one-shot `POST /transcribe`.

---

## System-wide dictation (⌃⌥D)

`install-dictation.sh` turns the transcriber into a macOS dictation tool that
works in any app:

1. Press **⌃⌥D** (Control + Option + D). You hear a short chime and the menu-bar
   mic turns into a red **● 0:03** timer.
2. Speak.
3. Press **⌃⌥D** again. The audio goes to the local server, the text is copied
   to your clipboard and pasted at your cursor. A small toast at the top of the
   screen confirms what was pasted (can be turned off from the menu).

Press **Esc** while recording to cancel. Recordings that are silent, or where
Whisper only produced one of its well-known "noise" phrases, are discarded
instead of pasted.

### The menu-bar indicator

A small monochrome microphone that follows the menu bar's light/dark style:

| Indicator            | Meaning                                                  |
|----------------------|----------------------------------------------------------|
| mic                  | Server running, model loaded — ready to dictate          |
| mic, dimmed          | Server starting, Whisper model still loading             |
| mic with a slash     | Server not running (click → **Start server**)            |
| red **● 0:07**       | Recording. Press ⌃⌥D to stop, Esc to cancel              |
| mic followed by …    | Transcribing                                             |

Click it for the language picker, an "auto-paste" toggle (off = clipboard
only), the on-screen confirmation toggle, the web app, the transcripts folder,
the server log, and server restart.

### Installation

**Prerequisites**

- macOS (tested on macOS 26/27, Apple Silicon). The hotkey layer is macOS-only;
  the web app itself runs anywhere.
- The base app installed first: `./install.sh` (creates `.venv`, installs
  ffmpeg and Whisper, downloads the model).
- [Homebrew](https://brew.sh) if Hammerspoon is not yet installed — the script
  uses it to install Hammerspoon.
- About 1.5 GB of RAM while idle: the server keeps the `turbo` model loaded so
  dictation starts instantly.

**Steps**

```bash
cd open-llm-transcriber
./install-dictation.sh
```

The script is idempotent — re-run it after moving the folder, changing the
port, or pulling an update. It does, in order:

| # | What                                                                                     | Where                                                           |
|---|------------------------------------------------------------------------------------------|-----------------------------------------------------------------|
| 1 | Checks `.venv` and ffmpeg                                                                | this folder                                                     |
| 2 | Installs **Hammerspoon** if missing (`brew install --cask hammerspoon`)                  | `/Applications/Hammerspoon.app`                                 |
| 3 | Writes a **launchd agent** that runs `server.py` at login and keeps it alive            | `~/Library/LaunchAgents/com.openllmtranscriber.server.plist`    |
| 4 | Loads the agent now (`launchctl bootstrap`)                                              | server log → `logs/server.log`                                  |
| 5 | Adds one `dofile(".../hammerspoon/dictation.lua")` line                                  | `~/.hammerspoon/init.lua`                                       |
| 6 | Launches (or restarts) Hammerspoon so the 🎙 icon appears                                | menu bar                                                        |

Environment variables set when you run the installer are baked into the agent:
`WHISPER_PORT=9000 WHISPER_MODEL=small ./install-dictation.sh`.

**One-time macOS permissions** (macOS prompts for both):

1. **Accessibility** → System Settings → Privacy & Security → Accessibility →
   enable *Hammerspoon*. Needed to press ⌘V for you. Without it the text still
   lands on the clipboard, it just isn't pasted.
2. **Microphone** → approve the prompt the first time you press ⌃⌥D. (It is
   attributed to Hammerspoon, which launches ffmpeg.)

**Verify**

- The menu bar shows a dimmed mic while the model loads (~5 s), then a solid
  mic. Hover it: "Ready — press ⌃⌥D to dictate".
- `curl http://localhost:8765/health` → `{"ready": true, "model": "turbo"}`.
- Click into any text field, press ⌃⌥D, say a sentence, press ⌃⌥D. The text
  should appear where your cursor is.
- Something off? `logs/server.log` and `logs/dictation.log` have the story, and
  the mic menu has **Show server log** and **Hammerspoon console**.

**Day-to-day**

- The server starts automatically at login; Hammerspoon too (set on first run).
- **Restart server** / **Start server** in the mic menu use `launchctl kickstart`.
  Equivalent from a shell:
  ```bash
  launchctl kickstart -k gui/$(id -u)/com.openllmtranscriber.server   # restart
  launchctl bootout   gui/$(id -u)/com.openllmtranscriber.server      # stop until next login
  launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.openllmtranscriber.server.plist  # start again
  ```
- After `git pull`: **Restart server** (Python changes) and **Reload Hammerspoon
  config** (Lua changes) from the mic menu. Re-run `./install-dictation.sh`
  only if the folder moved or the plist format changed.
- To change the hotkey, sounds or languages, edit the `config` table at the top
  of `hammerspoon/dictation.lua`, then **Reload Hammerspoon config**.
- `./start.sh` still works: if the agent already owns the port it simply opens
  the browser.

### Decommission (uninstall)

```bash
./install-dictation.sh --uninstall
```

This reverses everything the installer did, and nothing else:

| Removed                                                                 | Kept (on purpose)                                   |
|-------------------------------------------------------------------------|-----------------------------------------------------|
| The launchd agent is stopped and unloaded; the plist is deleted         | `Hammerspoon.app` (you may use it for other things) |
| The `dofile(...)` hook is removed from `~/.hammerspoon/init.lua` (the file itself if it is then empty) | Hammerspoon's Accessibility / Microphone permissions |
| Hammerspoon is restarted without the hook, or quit if no config remains | `transcripts/`, `logs/`, the `.venv`, the model cache |
| Leftover temp recordings (`olt-dictation-*`, `olt-stream-*`)            | The web app — `./start.sh` keeps working            |

The script is safe to run even if only part of the setup exists (it reports
what it could not find instead of failing).

**Complete removal**, if you also want the rest gone:

```bash
brew uninstall --cask hammerspoon        # Hammerspoon itself
rm -rf ~/.hammerspoon                    # its config dir (only if you don't use it otherwise)
rm -rf ~/.cache/whisper                  # downloaded Whisper model (~1.5 GB)
rm -rf logs transcripts                  # your transcripts and logs
cd .. && rm -rf open-llm-transcriber     # the project, including .venv
```

Then, optionally, remove Hammerspoon from System Settings → Privacy & Security →
Accessibility / Microphone, and from Login Items.

**Manual uninstall** (if the script is unavailable, e.g. the folder was deleted
first):

```bash
launchctl bootout gui/$(id -u)/com.openllmtranscriber.server
rm ~/Library/LaunchAgents/com.openllmtranscriber.server.plist
# then delete the "Open LLM Transcriber" dofile line from ~/.hammerspoon/init.lua
# and restart Hammerspoon (or quit it).
```

**Going back to an older version** instead of removing it:

```bash
git tag                          # list versions: v1.1-dictation, v1.2-streaming, …
git checkout v1.1-dictation      # e.g. dictation without streaming
git checkout main                # back to the latest
```

then **Restart server** and **Reload Hammerspoon config** from the mic menu —
both load code from this folder, so whatever is checked out is what runs.

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
