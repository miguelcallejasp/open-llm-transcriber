#!/bin/bash
# Start the local Whisper transcription server and open it in the browser.
cd "$(dirname "$0")"

PORT="${WHISPER_PORT:-8765}"
URL="http://localhost:${PORT}/"

# Open the URL in the user's default browser (Chrome if present, else default).
open_browser() {
  if [ -d "/Applications/Google Chrome.app" ]; then
    open -a "Google Chrome" "$URL"
  else
    open "$URL"
  fi
}

# If the server is already running, just open the browser and exit.
if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  open_browser
  exit 0
fi

# Otherwise: once the port is actually listening (model finished loading),
# open the browser at the address.
(
  for _ in $(seq 1 120); do
    if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
      open_browser
      break
    fi
    sleep 0.5
  done
) &

exec .venv/bin/python server.py
