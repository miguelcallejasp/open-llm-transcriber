// Whisper Local — front-end behaviour.
// Recording, the mic visualizer, transcription and copy. The DOM contract
// (element IDs + state classes) matches what styles.css and server.py expect.

const recordBtn = document.getElementById("recordBtn");
const recordLabel = document.getElementById("recordLabel");
const sendBtn = document.getElementById("sendBtn");
const languageSel = document.getElementById("language");
const timerEl = document.getElementById("timer");
const statusEl = document.getElementById("status");
const output = document.getElementById("output");
const meta = document.getElementById("meta");
const copyBtn = document.getElementById("copyBtn");
const copyLabel = document.getElementById("copyLabel");
const viz = document.getElementById("viz");
const vizCanvas = document.getElementById("vizCanvas");
const vizCtx = vizCanvas.getContext("2d");

let mediaRecorder = null;
let chunks = [];
let stream = null;
let recording = false;
let timerInterval = null;
let startedAt = 0;
let recordedBlob = null;

// Web Audio plumbing for the voice-reactive visualizer.
let audioCtx = null;
let analyser = null;
let vizRAF = null;

function setStatus(text, spinning = false) {
  statusEl.innerHTML = "";
  if (spinning) {
    const s = document.createElement("span");
    s.className = "spinner";
    statusEl.appendChild(s);
  }
  statusEl.appendChild(document.createTextNode(text));
}

function fmt(ms) {
  const total = Math.floor(ms / 1000);
  const m = String(Math.floor(total / 60)).padStart(2, "0");
  const s = String(total % 60).padStart(2, "0");
  return `${m}:${s}`;
}

function startTimer() {
  startedAt = performance.now();
  timerEl.textContent = "00:00";
  timerInterval = setInterval(() => {
    timerEl.textContent = fmt(performance.now() - startedAt);
  }, 250);
}
function stopTimer() {
  clearInterval(timerInterval);
  timerInterval = null;
}

// ---- voice-reactive visualizer (the "mic is working" indicator) ----
function startViz() {
  audioCtx = new (window.AudioContext || window.webkitAudioContext)();
  const source = audioCtx.createMediaStreamSource(stream);
  analyser = audioCtx.createAnalyser();
  analyser.fftSize = 64;          // -> 32 frequency bins, chunky bars
  analyser.smoothingTimeConstant = 0.75;
  source.connect(analyser);

  viz.classList.add("active");
  const bins = analyser.frequencyBinCount;
  const data = new Uint8Array(bins);

  function draw() {
    vizRAF = requestAnimationFrame(draw);
    analyser.getByteFrequencyData(data);

    const dpr = window.devicePixelRatio || 1;
    const w = vizCanvas.clientWidth, h = vizCanvas.clientHeight;
    if (vizCanvas.width !== w * dpr || vizCanvas.height !== h * dpr) {
      vizCanvas.width = w * dpr;
      vizCanvas.height = h * dpr;
    }
    vizCtx.setTransform(dpr, 0, 0, dpr, 0, 0);
    vizCtx.clearRect(0, 0, w, h);

    // center mirror line
    vizCtx.strokeStyle = "rgba(255,255,255,.12)";
    vizCtx.lineWidth = 1;
    vizCtx.beginPath(); vizCtx.moveTo(0, h / 2); vizCtx.lineTo(w, h / 2); vizCtx.stroke();

    const gap = 5;
    const barW = (w - gap * (bins - 1)) / bins;
    for (let i = 0; i < bins; i++) {
      const v = data[i] / 255;                 // 0..1
      const barH = Math.max(3, v * (h - 12));
      const x = i * (barW + gap);
      const y = (h - barH) / 2;
      // hue: electric blue when quiet -> red when loud
      const hue = 228 - v * 228;
      vizCtx.fillStyle = `hsl(${hue} 95% 62%)`;
      const r = Math.min(barW / 2, 3);
      vizCtx.beginPath();
      vizCtx.roundRect(x, y, barW, barH, r);
      vizCtx.fill();
    }
  }
  draw();
}

function stopViz() {
  if (vizRAF) cancelAnimationFrame(vizRAF);
  vizRAF = null;
  viz.classList.remove("active");
  if (audioCtx) { audioCtx.close(); audioCtx = null; }
  analyser = null;
}

async function startRecording() {
  try {
    stream = await navigator.mediaDevices.getUserMedia({ audio: true });
  } catch (err) {
    setStatus("Microphone access denied or unavailable.");
    return;
  }
  chunks = [];
  recordedBlob = null;
  sendBtn.disabled = true;
  mediaRecorder = new MediaRecorder(stream);
  mediaRecorder.ondataavailable = (e) => { if (e.data.size) chunks.push(e.data); };
  mediaRecorder.onstop = handleStop;
  mediaRecorder.start();

  recording = true;
  recordBtn.classList.add("recording");
  recordLabel.textContent = "Stop";
  setStatus("Recording…");
  startTimer();
  startViz();
}

function stopRecording() {
  if (mediaRecorder && mediaRecorder.state !== "inactive") {
    mediaRecorder.stop();
  }
  stream && stream.getTracks().forEach((t) => t.stop());
  recording = false;
  recordBtn.classList.remove("recording");
  recordLabel.textContent = "Record";
  stopTimer();
  stopViz();
}

// Just stash the recording; transcription waits for the Send button.
function handleStop() {
  recordedBlob = new Blob(chunks, { type: "audio/webm" });
  if (!recordedBlob.size) { setStatus("No audio captured."); return; }
  sendBtn.disabled = false;
  setStatus(`Captured ${timerEl.textContent || ""} — press Send to transcribe.`);
}

async function transcribe() {
  if (!recordedBlob) return;
  setStatus("Transcribing…", true);
  sendBtn.disabled = true;
  recordBtn.disabled = true;
  try {
    const res = await fetch("/transcribe", {
      method: "POST",
      headers: {
        "Content-Type": "application/octet-stream",
        "X-Language": languageSel.value,
      },
      body: recordedBlob,
    });
    const data = await res.json();
    if (!res.ok || data.error) throw new Error(data.error || "Server error");

    output.value = data.text;
    copyBtn.disabled = false;
    meta.textContent = `lang: ${data.language} · saved → ${data.saved.split("/").pop()}`;
    setStatus("Done.");
  } catch (err) {
    setStatus("Error: " + err.message);
    sendBtn.disabled = false;   // allow retry
  } finally {
    recordBtn.disabled = false;
  }
}

recordBtn.addEventListener("click", () => {
  recording ? stopRecording() : startRecording();
});

sendBtn.addEventListener("click", transcribe);

copyBtn.addEventListener("click", async () => {
  await navigator.clipboard.writeText(output.value);
  copyLabel.textContent = "Copied!";
  copyBtn.classList.add("copied");
  setTimeout(() => {
    copyLabel.textContent = "Copy";
    copyBtn.classList.remove("copied");
  }, 1500);
});

// Spacebar toggles recording (unless typing in the textarea).
document.addEventListener("keydown", (e) => {
  if (e.code === "Space" && document.activeElement !== output) {
    e.preventDefault();
    recordBtn.click();
  }
});
