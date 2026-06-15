#!/bin/bash
# Whisper Local — one-line installer (macOS).
#
# Verifies prerequisites, installs ffmpeg if needed, creates a virtual
# environment, installs Python dependencies, and builds the Dock app.
#
#   git clone <repo> && cd Whisper && ./install.sh
set -e
cd "$(dirname "$0")"

bold()  { printf "\033[1m%s\033[0m\n" "$1"; }
ok()    { printf "  \033[32m✓\033[0m %s\n" "$1"; }
warn()  { printf "  \033[33m!\033[0m %s\n" "$1"; }
fail()  { printf "  \033[31m✗\033[0m %s\n" "$1"; exit 1; }

bold "Whisper Local — installer"
echo

# --- 1. Platform ------------------------------------------------------------
if [ "$(uname)" != "Darwin" ]; then
  warn "This installer targets macOS. On other systems, follow the"
  warn "'Manual install' steps in README.md instead."
  exit 1
fi
ok "macOS detected"

# --- 2. Python --------------------------------------------------------------
if ! command -v python3 >/dev/null 2>&1; then
  fail "python3 not found. Install Python 3.9–3.12 from https://python.org"
fi
PYV="$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])')"
ok "python3 found (version $PYV)"

# --- 3. ffmpeg --------------------------------------------------------------
if command -v ffmpeg >/dev/null 2>&1; then
  ok "ffmpeg found"
elif command -v brew >/dev/null 2>&1; then
  bold "Installing ffmpeg via Homebrew…"
  brew install ffmpeg
  ok "ffmpeg installed"
else
  fail "ffmpeg not found and Homebrew is unavailable. Install Homebrew
     (https://brew.sh) then run: brew install ffmpeg"
fi

# --- 4. Virtual environment + dependencies ----------------------------------
if [ ! -d ".venv" ]; then
  bold "Creating virtual environment (.venv)…"
  python3 -m venv .venv
fi
ok "virtual environment ready"

bold "Installing Python dependencies (this can take a few minutes)…"
.venv/bin/python -m pip install --upgrade pip >/dev/null
.venv/bin/python -m pip install -r requirements.txt
ok "dependencies installed"

# --- 5. Pre-download the model (optional but nice) --------------------------
MODEL="${WHISPER_MODEL:-turbo}"
bold "Downloading the Whisper '$MODEL' model (cached in ~/.cache/whisper)…"
.venv/bin/python -c "import whisper; whisper.load_model('$MODEL')" \
  && ok "model ready" \
  || warn "model download skipped — it will download on first run"

# --- 6. Build the Dock app --------------------------------------------------
bold "Building the macOS Dock app…"
if ./build-app.sh; then
  ok "Whisper Local.app built"
else
  warn "Dock app build failed — you can still run ./start.sh manually"
fi

echo
bold "All set! 🎉"
echo "  • Drag \"Whisper Local.app\" onto your Dock for one-click access, or"
echo "  • run ./start.sh to launch right now."
