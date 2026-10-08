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
  -- Stream ~2 s chunks to the server while recording and paste
  -- each finished phrase as soon as it is transcribed, instead of waiting
  -- for the whole recording. false = classic one-shot mode.
  streaming     = true,
  chunkSeconds  = 2,
  pollSeconds   = 0.5,
  -- System sounds (see /System/Library/Sounds). The start chime must be short:
  -- the mic opens only after `startSoundDelay`, so the chime isn't recorded.
  startSound      = "Pop",
  startSoundDelay = 0.3,
  stopSound       = "Morse",
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

local LOG_FILE = ROOT .. "/logs/dictation.log"
local function log(fmt, ...)
  local line = string.format("[dictation] " .. fmt, ...)
  print(line)
  local f = io.open(LOG_FILE, "a")
  if f then
    f:write(os.date("%H:%M:%S "), line, "\n")
    f:close()
  end
end

-- Run fn, logging a traceback instead of dying silently inside a callback.
local function guarded(name, fn)
  return function(...)
    local ok, err = xpcall(fn, debug.traceback, ...)
    if not ok then log("ERROR in %s: %s", name, tostring(err)) end
  end
end

local function playSound(name)
  if not name or name == "" then return end
  local ok, s = pcall(hs.sound.getByName, name)
  if ok and s then s:play() end
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
  playSound(M.config.stopSound)
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

-- --- Streaming experiment ---------------------------------------------------
-- ffmpeg writes chunk-0000.wav, chunk-0001.wav, … into a per-recording temp
-- dir. A poll timer posts every *finished* chunk (all but the newest file,
-- which ffmpeg is still writing) to /stream/chunk, strictly in order, one
-- request in flight at a time. Text that comes back is pasted immediately.
-- When ffmpeg exits, the remaining files are posted and a final empty request
-- flushes whatever the server still has buffered.
M.stream = nil  -- { id, dir, sent = {}, queue = {}, inflight, ffmpegDone, stoppedAt, firstPasteAt }

local function pasteText(text)
  hs.pasteboard.setContents(text .. " ")
  hs.timer.doAfter(0.05, function() hs.eventtap.keyStroke({ "cmd" }, "v", 0) end)
end

local function streamCleanup()
  local st = M.stream
  if not st then return end
  if M.timers.poll then M.timers.poll:stop(); M.timers.poll = nil end
  if st.dir then
    for f in hs.fs.dir(st.dir) do
      if f ~= "." and f ~= ".." then os.remove(st.dir .. f) end
    end
    hs.fs.rmdir(st.dir)
  end
  M.stream = nil
end

local function streamFinish(data)
  local st = M.stream
  local full = (data and data.full or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if st and st.stoppedAt then
    log("stream: stop -> final text %.2fs (first paste %s after start)",
      hs.timer.secondsSinceEpoch() - st.stoppedAt,
      st.firstPasteAt and string.format("%.1fs", st.firstPasteAt - M.recordingStarted) or "never")
  end
  streamCleanup()
  setState("ready")
  if full == "" then
    toast("Nothing heard", 1.2)
    return
  end
  -- Leave the whole dictation on the clipboard, like classic mode does.
  hs.pasteboard.setContents(full .. " ")
  if not M.autoPaste then
    hs.timer.doAfter(0.05, function() hs.eventtap.keyStroke({ "cmd" }, "v", 0) end)
  end
  local snippet = full
  if #snippet > 80 then snippet = snippet:sub(1, 77) .. "…" end
  toast("Done: " .. snippet, 1.8)
end

local streamProcessQueue  -- forward declaration

local function streamSend(item)
  local st = M.stream
  local args = {
    "-sS", "--max-time", "600",
    "-H", "Content-Type: audio/wav",
    "-H", "X-Language: " .. M.language,
    "-H", "X-Session: " .. st.id,
    "-H", "X-Final: " .. (item.final and "1" or "0"),
  }
  if item.path then
    args[#args + 1] = "--data-binary"; args[#args + 1] = "@" .. item.path
  else
    args[#args + 1] = "-X"; args[#args + 1] = "POST"
    args[#args + 1] = "-H"; args[#args + 1] = "Content-Length: 0"
  end
  args[#args + 1] = "-w"; args[#args + 1] = "\n%{http_code}"
  args[#args + 1] = M.config.serverURL .. "/stream/chunk"

  local t0 = hs.timer.secondsSinceEpoch()
  local t = hs.task.new(M.config.curl, guarded("stream curl callback", function(code, out, err)
    if not M.stream or M.stream ~= st then return end  -- cancelled meanwhile
    st.inflight = false
    local body, httpCode = (out or ""):match("^(.*)\n(%d+)%s*$")
    local ok, data = pcall(hs.json.decode, body or "")
    if code ~= 0 or httpCode ~= "200" or not ok or type(data) ~= "table" then
      local msg = (ok and type(data) == "table" and data.error) or err or ("HTTP " .. tostring(httpCode))
      log("stream: chunk failed: %s", tostring(msg))
      if item.final then
        notify("Dictation failed", tostring(msg))
        streamCleanup()
        setState("ready")
        pollHealth()
      else
        streamProcessQueue()
      end
      return
    end
    local text = (data.text or ""):gsub("^%s+", ""):gsub("%s+$", "")
    log("stream: %s -> %q (%.2fs, %.1fs buffered)", item.path and item.path:match("[^/]+$") or "final",
      text, hs.timer.secondsSinceEpoch() - t0, tonumber(data.buffered_seconds) or -1)
    if text ~= "" and M.autoPaste then
      if not st.firstPasteAt then st.firstPasteAt = hs.timer.secondsSinceEpoch() end
      pasteText(text)
    end
    if item.final then
      streamFinish(data)
    else
      streamProcessQueue()
    end
  end), args)
  st.inflight = true
  if not t:start() then
    st.inflight = false
    log("stream: could not start curl")
  end
end

streamProcessQueue = function()
  local st = M.stream
  if not st or st.inflight or #st.queue == 0 then return end
  streamSend(table.remove(st.queue, 1))
end

local function streamScan()
  local st = M.stream
  if not st then return end
  local names = {}
  for f in hs.fs.dir(st.dir) do
    if f:match("^chunk%-%d+%.wav$") then names[#names + 1] = f end
  end
  table.sort(names)
  -- The newest file is still being written unless ffmpeg has exited.
  local complete = st.ffmpegDone and #names or (#names - 1)
  for i = 1, complete do
    local f = names[i]
    if not st.sent[f] then
      st.sent[f] = true
      st.queue[#st.queue + 1] = { path = st.dir .. f, final = false }
    end
  end
  if st.ffmpegDone and not st.finalQueued then
    st.finalQueued = true
    st.queue[#st.queue + 1] = { path = nil, final = true }
    if M.timers.poll then M.timers.poll:stop(); M.timers.poll = nil end
  end
  streamProcessQueue()
end

local function streamStart()
  local mic = micDeviceName()
  local id = string.format("%d-%04d", os.time(), math.random(0, 9999))
  local dir = string.format("%solt-stream-%s/", hs.fs.temporaryDirectory(), id)
  hs.fs.mkdir(dir)
  M.stream = { id = id, dir = dir, sent = {}, queue = {}, inflight = false, ffmpegDone = false }
  local args = {
    "-hide_banner", "-loglevel", "error", "-nostdin", "-y",
    "-f", "avfoundation", "-i", ":" .. (mic or "0"),
    "-t", tostring(M.config.maxSeconds),
    "-ac", "1", "-ar", "16000",
    "-f", "segment", "-segment_time", tostring(M.config.chunkSeconds),
    "-reset_timestamps", "1", "-segment_format", "wav",
    dir .. "chunk-%04d.wav",
  }
  M.task = hs.task.new(M.ffmpeg, guarded("stream ffmpeg exit", function(_code, _out, stderr)
    stopRecordingTimer()
    M.task = nil
    local st = M.stream
    if not st then return end
    if M.cancelled then
      M.cancelled = false
      streamCleanup()
      setState("ready")
      toast("Dictation cancelled", 1)
      return
    end
    if stderr and stderr ~= "" then log("ffmpeg: %s", stderr) end
    st.ffmpegDone = true
    st.stoppedAt = st.stoppedAt or hs.timer.secondsSinceEpoch()
    setState("transcribing")
    playSound(M.config.stopSound)
    streamScan()
  end), args)
  if not M.task:start() then
    M.task = nil
    streamCleanup()
    stopRecordingTimer()
    setState("ready")
    notify("Dictation failed", "Could not start ffmpeg.")
    return
  end
  M.timers.poll = hs.timer.doEvery(M.config.pollSeconds, guarded("stream scan", streamScan))
  log("stream: started session %s (%ss chunks)", id, tostring(M.config.chunkSeconds))
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
  -- stop, not a second start; ffmpeg itself launches once the chime is done
  -- (after startSoundDelay), so the chime never ends up in the recording.
  M.recordingStarted = hs.timer.secondsSinceEpoch()
  M.cancelled = false
  setState("recording")
  M.timers.recording = hs.timer.doEvery(1, refreshTitle)
  if M.escKey then M.escKey:enable() end

  playSound(M.config.startSound)
  hs.timer.doAfter(M.config.startSoundDelay, function()
    if M.state ~= "recording" or M.cancelled then  -- stopped/cancelled during the chime
      stopRecordingTimer()
      M.cancelled = false
      setState("ready")
      return
    end
    if M.config.streaming then
      streamStart()
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
    M.task = hs.task.new(M.ffmpeg, guarded("ffmpeg exit", onRecordingDone), args)
    if not M.task:start() then
      M.task = nil
      cleanupTmp()
      stopRecordingTimer()
      setState("ready")
      notify("Dictation failed", "Could not start ffmpeg.")
    end
  end)
end

-- ffmpeg normally exits within ~100 ms of SIGINT. If it does not, escalate:
-- SIGTERM after 2 s, SIGKILL after 4 s. The exit callback then runs as usual
-- (segment files written so far are already finalized, so nothing is lost).
local function armStopWatchdog(task)
  if M.timers.watchdog then M.timers.watchdog:stop() end
  M.timers.watchdog = hs.timer.doAfter(2, function()
    if M.task == task and task:isRunning() then
      log("ffmpeg still running 2s after SIGINT — sending SIGTERM")
      task:terminate()
      M.timers.watchdog = hs.timer.doAfter(2, function()
        if M.task == task and task:isRunning() then
          log("ffmpeg still running — SIGKILL")
          hs.execute("kill -9 " .. tostring(task:pid()))
        end
      end)
    end
  end)
end

function M.stopRecording()
  if M.task and M.task:isRunning() then
    if M.stream then M.stream.stoppedAt = hs.timer.secondsSinceEpoch() end
    M.task:interrupt()  -- SIGINT lets ffmpeg finalize the WAV header
    armStopWatchdog(M.task)
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
