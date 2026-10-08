-- Open LLM Transcriber — system-wide dictation for Hammerspoon.
--
-- Press ⌃⌥D anywhere on your Mac: the menu-bar mic turns red and starts
-- recording. Press ⌃⌥D again: the audio is sent to the local Whisper server
-- (server.py), the text lands on your clipboard and is pasted where your
-- cursor is. The menu-bar item always shows whether the server is ready.
--
-- Installed by ./install-dictation.sh, which adds one line to
-- ~/.hammerspoon/init.lua:   dofile("<repo>/hammerspoon/dictation.lua")
--
-- Everything stays on this machine: audio goes to 127.0.0.1 only.

require("hs.ipc")  -- enables the `hs` command-line tool so the installer can reload us

local M = {}

-- --- Configuration ---------------------------------------------------------
local HERE = debug.getinfo(1, "S").source:match("^@(.*)/[^/]+$") or "."
local ROOT = HERE:match("^(.*)/hammerspoon$") or HERE

M.config = {
  hotkey        = { mods = { "ctrl", "alt" }, key = "d" },
  hotkeyLabel   = "⌃⌥D",
  serverURL     = "http://127.0.0.1:" .. (os.getenv("WHISPER_PORT") or "8765"),
  launchdLabel  = "com.openllmtranscriber.server",
  maxSeconds    = 300,    -- hard stop so a forgotten recording can't run forever
  minBytes      = 4000,   -- ~0.1 s of 16 kHz mono PCM; anything smaller is "nothing recorded"
  healthEvery   = 5,      -- seconds between /health polls
  curl          = "/usr/bin/curl",
  languages     = {
    { code = "auto", label = "Auto-detect" },
    { code = "en",   label = "English" },
    { code = "es",   label = "Spanish" },
  },
}

local function setting(key, default)
  local v = hs.settings.get("olt." .. key)
  if v == nil then return default end
  return v
end
local function saveSetting(key, value) hs.settings.set("olt." .. key, value) end

M.language  = setting("language", "auto")
M.autoPaste = setting("autoPaste", true)
M.showToast = setting("showToast", true)

-- Find ffmpeg: Homebrew (Apple Silicon / Intel), then whatever the login shell knows.
local function findFfmpeg()
  for _, p in ipairs({ "/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg" }) do
    if hs.fs.attributes(p) then return p end
  end
  local out = hs.execute("command -v ffmpeg", true)
  out = out and out:gsub("%s+$", "")
  if out and out ~= "" then return out end
  return nil
end
M.ffmpeg = findFfmpeg()

-- --- State -----------------------------------------------------------------
-- offline | loading | ready | recording | transcribing
M.state = "offline"
M.serverModel = nil
M.task = nil
M.tmpFile = nil
M.recordingStarted = nil
M.timers = {}

local function log(fmt, ...) print(string.format("[dictation] " .. fmt, ...)) end

-- Play a system sound; `andThen` (optional) runs once it has finished.
-- Recording must not start until the start chime is over, otherwise the mic
-- picks the chime up and it ends up in the audio sent to Whisper.
local function playSound(name, andThen)
  local ok, s = pcall(hs.sound.getByName, name)
  if not ok or not s then
    if andThen then andThen() end
    return
  end
  if andThen then
    local fired = false
    local function once() if not fired then fired = true; andThen() end end
    s:setCallback(once)
    hs.timer.doAfter(0.6, once)  -- safety net if the callback never fires
  end
  s:play()
end

local function notify(title, text)
  hs.notify.new({ title = title, informativeText = text or "", withdrawAfter = 6 }):send()
end

-- A small, understated toast at the top edge of the screen (Hammerspoon's
-- default hs.alert is a huge centered box). Used for quick feedback only;
-- real errors go through native notifications via notify().
local TOAST_STYLE = {
  textSize        = 13,
  textFont        = ".AppleSystemUIFont",
  textColor       = { white = 1, alpha = 0.95 },
  fillColor       = { white = 0.12, alpha = 0.88 },
  strokeWidth     = 0,
  strokeColor     = { white = 1, alpha = 0 },
  radius          = 8,
  padding         = 10,
  atScreenEdge    = 1,      -- 1 = top of screen
  fadeInDuration  = 0.1,
  fadeOutDuration = 0.3,
}
local function toast(text, seconds)
  if not M.showToast then return end
  hs.alert.show(text, TOAST_STYLE, hs.screen.mainScreen(), seconds or 1.2)
end

-- --- Menu bar --------------------------------------------------------------
M.menubar = hs.menubar.new()

local RED = { red = 0.95, green = 0.25, blue = 0.25 }

-- Draw a minimal microphone glyph (capsule, cradle, stem, base) as a template
-- image: macOS then renders it in the menu-bar foreground colour, so it looks
-- like the system's own monochrome icons in both light and dark mode.
local function micImage(opts)
  opts = opts or {}
  local ink = { white = 0, alpha = opts.alpha or 1 }
  local c = hs.canvas.new({ x = 0, y = 0, w = 18, h = 18 })
  c[#c + 1] = {
    type = "rectangle", action = "fill", fillColor = ink,
    frame = { x = 6.5, y = 1.5, w = 5, h = 9.5 },
    roundedRectRadii = { xRadius = 2.5, yRadius = 2.5 },
  }
  c[#c + 1] = {
    type = "arc", action = "stroke", strokeColor = ink, strokeWidth = 1.5, arcRadii = false,
    center = { x = 9, y = 8 }, radius = 5.25, startAngle = 90, endAngle = 270,
  }
  c[#c + 1] = {
    type = "segments", action = "stroke", strokeColor = ink, strokeWidth = 1.5,
    coordinates = { { x = 9, y = 13.25 }, { x = 9, y = 16.25 } },
  }
  c[#c + 1] = {
    type = "segments", action = "stroke", strokeColor = ink, strokeWidth = 1.5, strokeCapStyle = "round",
    coordinates = { { x = 5.75, y = 16.25 }, { x = 12.25, y = 16.25 } },
  }
  if opts.slash then
    c[#c + 1] = {
      type = "segments", action = "stroke", strokeColor = ink, strokeWidth = 1.5, strokeCapStyle = "round",
      coordinates = { { x = 3.5, y = 15 }, { x = 14.5, y = 3 } },
    }
  end
  local img = c:imageFromCanvas()
  c:delete()
  img:template(true)
  return img
end

local ICONS = {
  ready   = micImage(),
  loading = micImage({ alpha = 0.35 }),
  offline = micImage({ slash = true }),
}

local function elapsed()
  if not M.recordingStarted then return "0:00" end
  local s = math.floor(hs.timer.secondsSinceEpoch() - M.recordingStarted)
  return string.format("%d:%02d", s // 60, s % 60)
end

local function refreshTitle()
  local st = M.state
  if st == "recording" then
    -- Text only: a red dot and the elapsed time.
    M.menubar:setIcon(nil)
    M.menubar:setTitle(hs.styledtext.new("● " .. elapsed(), { color = RED }))
    M.menubar:setTooltip("Recording — press " .. M.config.hotkeyLabel .. " to stop")
  elseif st == "transcribing" then
    M.menubar:setIcon(ICONS.ready)
    M.menubar:setTitle("…")
    M.menubar:setTooltip("Transcribing…")
  elseif st == "ready" then
    M.menubar:setIcon(ICONS.ready)
    M.menubar:setTitle(nil)
    M.menubar:setTooltip("Ready — press " .. M.config.hotkeyLabel .. " to dictate")
  elseif st == "loading" then
    M.menubar:setIcon(ICONS.loading)
    M.menubar:setTitle(nil)
    M.menubar:setTooltip("Whisper model is loading…")
  else
    M.menubar:setIcon(ICONS.offline)
    M.menubar:setTitle(nil)
    M.menubar:setTooltip("Transcription server is not running")
  end
end

local function setState(st)
  if M.state ~= st then
    log("state: %s -> %s", M.state, st)
    M.state = st
  end
  refreshTitle()
end

local function statusLine()
  local k = M.config.hotkeyLabel
  return ({
    offline      = "Server offline",
    loading      = "Server starting — loading Whisper model…",
    ready        = "Ready — press " .. k .. " to dictate",
    recording    = "Recording… press " .. k .. " to stop",
    transcribing = "Transcribing…",
  })[M.state]
end

local function uid()
  local out = hs.execute("id -u")
  return (out or ""):gsub("%s+$", "")
end

local function restartServer()
  local target = "gui/" .. uid() .. "/" .. M.config.launchdLabel
  -- kickstart -k restarts if running, starts if not (as long as the agent is loaded)
  hs.task.new("/bin/launchctl", function(code, _, err)
    if code ~= 0 then
      notify("Open LLM Transcriber", "Could not start the server via launchd. Run ./install-dictation.sh again.")
      log("launchctl kickstart failed (%s): %s", tostring(code), err or "")
    end
  end, { "kickstart", "-k", target }):start()
  setState("loading")
end

local function buildMenu()
  local items = {
    { title = statusLine(), disabled = true },
    { title = "-" },
  }

  if M.state == "recording" then
    items[#items + 1] = { title = "Stop & transcribe\t" .. M.config.hotkeyLabel, fn = function() M.toggle() end }
    items[#items + 1] = { title = "Cancel recording\tesc", fn = function() M.cancel() end }
  else
    items[#items + 1] = {
      title = "Start dictation\t" .. M.config.hotkeyLabel,
      fn = function() M.toggle() end,
      disabled = (M.state ~= "ready"),
    }
  end

  local langMenu = {}
  for _, l in ipairs(M.config.languages) do
    langMenu[#langMenu + 1] = {
      title = l.label,
      checked = (M.language == l.code),
      fn = function()
        M.language = l.code
        saveSetting("language", l.code)
      end,
    }
  end
  items[#items + 1] = { title = "Language", menu = langMenu }
  items[#items + 1] = {
    title = "Paste automatically after transcribing",
    checked = M.autoPaste,
    fn = function()
      M.autoPaste = not M.autoPaste
      saveSetting("autoPaste", M.autoPaste)
    end,
  }
  items[#items + 1] = {
    title = "Show on-screen confirmation",
    checked = M.showToast,
    fn = function()
      M.showToast = not M.showToast
      saveSetting("showToast", M.showToast)
    end,
  }

  items[#items + 1] = { title = "-" }
  items[#items + 1] = { title = "Open web app", fn = function() hs.urlevent.openURL(M.config.serverURL .. "/") end }
  items[#items + 1] = { title = "Open transcripts folder", fn = function() hs.open(ROOT .. "/transcripts") end }
  items[#items + 1] = {
    title = (M.state == "offline") and "Start server" or "Restart server",
    fn = restartServer,
  }
  items[#items + 1] = { title = "Show server log", fn = function() hs.open(ROOT .. "/logs/server.log") end }
  items[#items + 1] = { title = "-" }
  items[#items + 1] = { title = "Hammerspoon console", fn = function() hs.openConsole() end }
  items[#items + 1] = { title = "Reload Hammerspoon config", fn = function() hs.reload() end }
  return items
end
M.menubar:setMenu(buildMenu)

-- --- Health polling --------------------------------------------------------
local function pollHealth()
  hs.http.asyncGet(M.config.serverURL .. "/health", nil, function(status, body)
    -- Never clobber an in-flight recording/transcription with a health result.
    if M.state == "recording" or M.state == "transcribing" then return end
    if status == 200 then
      local ok, data = pcall(hs.json.decode, body)
      if ok and type(data) == "table" then
        M.serverModel = data.model
        setState(data.ready and "ready" or "loading")
        return
      end
    end
    setState("offline")
  end)
end

-- --- Recording -------------------------------------------------------------
local function micDeviceName()
  local dev = hs.audiodevice.defaultInputDevice()
  return dev and dev:name() or nil
end

local function cleanupTmp()
  if M.tmpFile then
    os.remove(M.tmpFile)
    M.tmpFile = nil
  end
end

local function stopRecordingTimer()
  if M.timers.recording then
    M.timers.recording:stop()
    M.timers.recording = nil
  end
  if M.escKey then M.escKey:disable() end
end

local function deliver(text)
  hs.pasteboard.setContents(text .. " ")
  if M.autoPaste then
    -- Tiny delay so the pasteboard write is visible to the frontmost app.
    hs.timer.doAfter(0.05, function() hs.eventtap.keyStroke({ "cmd" }, "v", 0) end)
  end
  local snippet = text
  if #snippet > 80 then snippet = snippet:sub(1, 77) .. "…" end
  toast((M.autoPaste and "Pasted: " or "Copied: ") .. snippet, 1.8)
end

local function transcribe(path)
  setState("transcribing")
  playSound("Pop")
  local args = {
    "-sS", "--max-time", "600",
    "-H", "Content-Type: audio/wav",
    "-H", "X-Language: " .. M.language,
    "--data-binary", "@" .. path,
    "-w", "\n%{http_code}",
    M.config.serverURL .. "/transcribe",
  }
  local t = hs.task.new(M.config.curl, function(code, out, err)
    cleanupTmp()
    if code ~= 0 then
      notify("Dictation failed", "Could not reach the transcription server. " .. (err or ""))
      pollHealth()
      setState("offline")
      return
    end
    local body, httpCode = out:match("^(.*)\n(%d+)%s*$")
    local ok, data = pcall(hs.json.decode, body or "")
    if httpCode == "200" and ok and type(data) == "table" and data.text then
      local text = data.text:gsub("^%s+", ""):gsub("%s+$", "")
      setState("ready")
      if text == "" then
        toast("Nothing heard", 1.2)
      else
        deliver(text)
      end
    else
      local msg = (ok and type(data) == "table" and data.error) or ("HTTP " .. tostring(httpCode))
      notify("Dictation failed", msg)
      setState("ready")
      pollHealth()
    end
  end, args)
  if not t:start() then
    cleanupTmp()
    notify("Dictation failed", "Could not run curl.")
    setState("ready")
  end
end

local function onRecordingDone(_exitCode, _stdout, stderr)
  -- ffmpeg exits 255 when interrupted with SIGINT, which is our normal stop
  -- path, so judge success by the file it left behind rather than the code.
  stopRecordingTimer()
  M.task = nil
  local path = M.tmpFile
  local attrs = path and hs.fs.attributes(path)
  if M.cancelled then
    M.cancelled = false
    cleanupTmp()
    setState("ready")
    toast("Dictation cancelled", 1)
    return
  end
  if not attrs or attrs.size < M.config.minBytes then
    cleanupTmp()
    setState("ready")
    toast("Nothing recorded", 1.2)
    if stderr and stderr ~= "" then log("ffmpeg: %s", stderr) end
    return
  end
  transcribe(path)
end

function M.startRecording()
  if M.state ~= "ready" then
    if M.state == "offline" then
      notify("Transcription server offline", "Start it from the 🎙 menu, or run ./install-dictation.sh.")
    elseif M.state == "loading" then
      toast("Whisper is still loading…", 1.2)
    end
    return
  end
  if not M.ffmpeg then
    notify("ffmpeg not found", "Install it with: brew install ffmpeg")
    return
  end

  -- Flip to "recording" right away so a second ⌃⌥D during the chime is a
  -- stop, not a second start; ffmpeg itself launches once the chime is done.
  M.recordingStarted = hs.timer.secondsSinceEpoch()
  M.cancelled = false
  setState("recording")
  M.timers.recording = hs.timer.doEvery(1, refreshTitle)
  if M.escKey then M.escKey:enable() end

  playSound("Tink", function()
    if M.state ~= "recording" or M.cancelled then  -- stopped/cancelled during the chime
      stopRecordingTimer()
      M.cancelled = false
      setState("ready")
      return
    end
    local mic = micDeviceName()
    M.tmpFile = string.format("%solt-dictation-%d.wav", hs.fs.temporaryDirectory(), os.time())
    local args = {
      "-hide_banner", "-loglevel", "error", "-nostdin", "-y",
      "-f", "avfoundation", "-i", ":" .. (mic or "0"),
      "-t", tostring(M.config.maxSeconds),
      "-ac", "1", "-ar", "16000",
      M.tmpFile,
    }
    M.task = hs.task.new(M.ffmpeg, onRecordingDone, args)
    if not M.task:start() then
      M.task = nil
      cleanupTmp()
      stopRecordingTimer()
      setState("ready")
      notify("Dictation failed", "Could not start ffmpeg.")
    end
  end)
end

function M.stopRecording()
  if M.task and M.task:isRunning() then
    M.task:interrupt()  -- SIGINT lets ffmpeg finalize the WAV header
  elseif M.state == "recording" and not M.task then
    -- Stopped during the start chime: nothing was recorded yet.
    M.cancelled = true
  end
end

function M.cancel()
  if M.state ~= "recording" then return end
  M.cancelled = true
  M.stopRecording()
end

function M.toggle()
  if M.state == "recording" then
    M.stopRecording()
  elseif M.state == "transcribing" then
    toast("Still transcribing…", 1)
  else
    M.startRecording()
  end
end

-- --- Wiring ----------------------------------------------------------------
M.hotkey = hs.hotkey.bind(M.config.hotkey.mods, M.config.hotkey.key, M.toggle)
M.escKey = hs.hotkey.new({}, "escape", M.cancel)  -- only enabled while recording

M.timers.health = hs.timer.doEvery(M.config.healthEvery, pollHealth)
refreshTitle()
pollHealth()

-- First run only: hide Hammerspoon's own hammer icon and Dock icon so this
-- behaves like a single menu-bar utility, and make sure it starts at login.
-- (Both are reversible from the Hammerspoon preferences.)
if not setting("configured", false) then
  hs.menuIcon(false)
  hs.dockIcon(false)
  hs.autoLaunch(true)
  saveSetting("configured", true)
end

-- Pasting via simulated ⌘V needs Accessibility; this prompts if not granted.
hs.accessibilityState(true)

log("loaded. root=%s ffmpeg=%s server=%s", ROOT, tostring(M.ffmpeg), M.config.serverURL)
_G.oltDictation = M  -- handy from the Hammerspoon console / `hs` CLI: oltDictation.toggle()
return M
