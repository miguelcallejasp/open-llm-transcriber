#!/bin/bash
# Build the "Whisper Local.app" macOS launcher with its custom icon.
# Safe to re-run; it rebuilds from scratch.
set -e
cd "$(dirname "$0")"
ROOT="$PWD"
APP="Whisper Local.app"

CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
if [ -x "$CHROME" ]; then
  echo "==> Rendering icon PNG (Google Chrome)…"
  "$CHROME" --headless=new --disable-gpu --hide-scrollbars \
    --default-background-color=00000000 \
    --screenshot="$ROOT/icon/icon_1024.png" --window-size=1024,1024 \
    "file://$ROOT/icon/icon.html" 2>/dev/null
else
  echo "==> Google Chrome not found — using the committed icon/icon_1024.png."
fi

echo "==> Building .icns…"
rm -rf icon/icon.iconset && mkdir icon/icon.iconset
for e in 16:icon_16x16 32:icon_16x16@2x 32:icon_32x32 64:icon_32x32@2x \
         128:icon_128x128 256:icon_128x128@2x 256:icon_256x256 \
         512:icon_256x256@2x 512:icon_512x512 1024:icon_512x512@2x; do
  px="${e%%:*}"; name="${e##*:}"
  sips -z "$px" "$px" icon/icon_1024.png --out "icon/icon.iconset/${name}.png" >/dev/null
done
iconutil -c icns icon/icon.iconset -o icon/icon.icns

echo "==> Compiling AppleScript launcher…"
cat > /tmp/whisper_launcher.applescript <<EOF
on run
	tell application "Terminal"
		activate
		do script "clear; '$ROOT/start.sh'"
	end tell
end run
EOF
rm -rf "$APP"
osacompile -o "$APP" /tmp/whisper_launcher.applescript

echo "==> Applying icon + re-signing…"
cp icon/icon.icns "$APP/Contents/Resources/applet.icns"
codesign --force --deep --sign - "$APP"

echo "==> Done. Drag '$APP' onto your Dock."
