#!/bin/bash
# Open LLM Transcriber — system-wide dictation installer (macOS).
#
# Sets up:
#   1. A launchd agent that keeps server.py running (and the Whisper model
#      warm) from login onward, logging to logs/server.log.
#   2. Hammerspoon, which provides the ⌃⌥D global hotkey and the 🎙 menu-bar
#      indicator (hammerspoon/dictation.lua).
#
# Run ./install.sh first (creates .venv, installs ffmpeg + Whisper).
#
#   ./install-dictation.sh              install / update
#   ./install-dictation.sh --uninstall  remove the agent + Hammerspoon hook
#
# See README.md → "Installation" and "Decommission" for the full picture.
set -e
cd "$(dirname "$0")"
ROOT="$PWD"

bold()  { printf "\033[1m%s\033[0m\n" "$1"; }
ok()    { printf "  \033[32m✓\033[0m %s\n" "$1"; }
warn()  { printf "  \033[33m!\033[0m %s\n" "$1"; }
fail()  { printf "  \033[31m✗\033[0m %s\n" "$1"; exit 1; }

LABEL="com.openllmtranscriber.server"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
HS_DIR="$HOME/.hammerspoon"
HS_INIT="$HS_DIR/init.lua"
HOOK="dofile(\"$ROOT/hammerspoon/dictation.lua\")"
PORT="${WHISPER_PORT:-8765}"
UID_NUM="$(id -u)"

[ "$(uname)" = "Darwin" ] || fail "This installer is for macOS."

# Restart Hammerspoon so it picks up config changes. (A plain relaunch is more
# reliable than the `hs` IPC client, which can wedge if a previous call hung.)
restart_hammerspoon() {
  if pgrep -xq Hammerspoon; then
    killall Hammerspoon 2>/dev/null || true
    sleep 1
  fi
  open -a Hammerspoon
}

# --- Uninstall ----------------------------------------------------------------
if [ "$1" = "--uninstall" ]; then
  bold "Removing system-wide dictation…"
  pkill -INT -f "olt-(dictation|stream)" 2>/dev/null || true   # any in-flight recording
  if launchctl bootout "gui/$UID_NUM/$LABEL" 2>/dev/null; then
    ok "server agent stopped and unloaded"
  else
    warn "server agent was not loaded"
  fi
  if [ -f "$PLIST" ]; then rm -f "$PLIST"; ok "removed $PLIST"; fi
  if [ -f "$HS_INIT" ] && grep -qF "$HOOK" "$HS_INIT"; then
    grep -vF "$HOOK" "$HS_INIT" | grep -vF -- "-- Open LLM Transcriber: ⌃⌥D dictation + menu-bar indicator" > "$HS_INIT.tmp"
    mv "$HS_INIT.tmp" "$HS_INIT"
    ok "removed hook from $HS_INIT"
    if [ ! -s "$HS_INIT" ] || ! grep -q '[^[:space:]]' "$HS_INIT"; then
      rm -f "$HS_INIT"
      rmdir "$HS_DIR" 2>/dev/null || true
      ok "removed empty $HS_INIT"
    fi
    if pgrep -xq Hammerspoon; then
      if [ -f "$HS_INIT" ]; then
        restart_hammerspoon; ok "Hammerspoon restarted without the dictation hook"
      else
        killall Hammerspoon 2>/dev/null || true; ok "Hammerspoon quit (no config left)"
      fi
    fi
  else
    warn "no Hammerspoon hook found in $HS_INIT"
  fi
  rm -rf "${TMPDIR:-/tmp}"/olt-dictation-* "${TMPDIR:-/tmp}"/olt-stream-* 2>/dev/null || true
  echo
  echo "Done. Left in place on purpose:"
  echo "  • Hammerspoon.app            → brew uninstall --cask hammerspoon"
  echo "  • Hammerspoon permissions    → System Settings → Privacy & Security (Accessibility, Microphone)"
  echo "  • transcripts/ and logs/     → delete if you don't want to keep them"
  echo "  • the web app (./start.sh) still works; it never depended on this."
  exit 0
fi

bold "Open LLM Transcriber — system-wide dictation installer"
echo

# --- 1. Prerequisites ---------------------------------------------------------
[ -x ".venv/bin/python" ] || fail ".venv not found. Run ./install.sh first."
ok "virtual environment found"
command -v ffmpeg >/dev/null 2>&1 || fail "ffmpeg not found. Run ./install.sh first."
ok "ffmpeg found"

# --- 2. Hammerspoon -----------------------------------------------------------
if [ -d "/Applications/Hammerspoon.app" ]; then
  ok "Hammerspoon found"
elif command -v brew >/dev/null 2>&1; then
  bold "Installing Hammerspoon via Homebrew…"
  brew install --cask hammerspoon
  ok "Hammerspoon installed"
else
  fail "Hammerspoon not found and Homebrew is unavailable. Install it from https://www.hammerspoon.org"
fi

# --- 3. launchd agent for the server -----------------------------------------
mkdir -p logs "$HOME/Library/LaunchAgents"

# If someone started the server by hand (./start.sh), the agent can't bind the
# port. Tell them rather than let launchd fight over it.
if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1 \
   && ! launchctl print "gui/$UID_NUM/$LABEL" >/dev/null 2>&1; then
  warn "Something is already listening on port $PORT (a ./start.sh session?)."
  warn "Stop it (Ctrl+C in that Terminal) and re-run this script so launchd can own it."
fi

MODEL_LINE=""
if [ -n "$WHISPER_MODEL" ]; then
  MODEL_LINE="    <key>WHISPER_MODEL</key><string>$WHISPER_MODEL</string>"
fi

cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$ROOT/.venv/bin/python</string>
    <string>$ROOT/server.py</string>
  </array>
  <key>WorkingDirectory</key><string>$ROOT</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
    <key>HOME</key><string>$HOME</string>
    <key>WHISPER_PORT</key><string>$PORT</string>
$MODEL_LINE
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>30</integer>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardOutPath</key><string>$ROOT/logs/server.log</string>
  <key>StandardErrorPath</key><string>$ROOT/logs/server.log</string>
</dict>
</plist>
PLIST
plutil -lint "$PLIST" >/dev/null || fail "generated plist is invalid: $PLIST"
ok "wrote $PLIST"

launchctl bootout "gui/$UID_NUM/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$UID_NUM" "$PLIST"
ok "server agent loaded (logs → $ROOT/logs/server.log)"

# --- 4. Hammerspoon hook ------------------------------------------------------
mkdir -p "$HS_DIR"
touch "$HS_INIT"
if grep -qF "$HOOK" "$HS_INIT"; then
  ok "Hammerspoon hook already present in $HS_INIT"
else
  {
    echo ""
    echo "-- Open LLM Transcriber: ⌃⌥D dictation + menu-bar indicator"
    echo "$HOOK"
  } >> "$HS_INIT"
  ok "added hook to $HS_INIT"
fi

if pgrep -xq Hammerspoon; then
  restart_hammerspoon
  ok "Hammerspoon restarted with the new config"
else
  open -a Hammerspoon
  ok "Hammerspoon launched"
fi

echo
bold "Almost done — two one-time macOS permissions:"
echo "  1. Accessibility: System Settings → Privacy & Security → Accessibility → enable Hammerspoon."
echo "     (Needed to paste the text where your cursor is. macOS should prompt you.)"
echo "  2. Microphone: approve the prompt the first time you press ⌃⌥D."
echo
echo "Then watch the menu bar: 🎙 ⏳ while the Whisper model loads, 🎙 when ready."
echo "Press ⌃⌥D to start recording, ⌃⌥D again to transcribe and paste."
