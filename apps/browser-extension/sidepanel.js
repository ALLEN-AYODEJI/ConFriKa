import { HandLandmarker, FilesetResolver } from './vendor/vision_bundle.mjs';
import { classifyHand, PHRASE_CATALOG } from './recognizer.js';

// Reach metric: count one extension open per browser session (fire-and-forget).
try {
  if (!sessionStorage.getItem('cf_ext')) {
    sessionStorage.setItem('cf_ext', '1');
    fetch('https://confrika-backend.fly.dev/api/v1/metrics/hit?kind=ext_open',
      { method: 'POST', mode: 'no-cors', keepalive: true }).catch(() => {});
  }
} catch (e) { /* ignore */ }

// ── DOM ──────────────────────────────────────────────────────────────────────
const $ = (id) => document.getElementById(id);
const video = $('video');
const liveEl = $('live');
const liveText = $('liveText');
const tokenEl = $('token');
const msgEl = $('msg');
const capEl = $('cap');
const errEl = $('err');

// ── State ─────────────────────────────────────────────────────────────────────
let landmarker = null;
let stream = null;
let running = false;
let rafId = 0;
let busy = false;

let alphabet = 'letters';
let autoSpeak = true;

let text = '';          // finalized words, each followed by a space
let word = '';          // in-progress fingerspelled letters
let lastCommitted = null;
let unrecFrames = 0;
let noHandFrames = 0;
const buffer = [];       // last N recognized tokens (or null)
const BUFFER = 10;
const COMMIT_SHARE = 0.6;
const WORD_BREAK = 12;   // frames with no hand → end the current word

// ── Message helpers ─────────────────────────────────────────────────────────
function render() {
  const full = (text + word).replace(/\s+$/, '');
  msgEl.textContent = full || 'Start the camera and sign…';
  msgEl.classList.toggle('empty', full.length === 0);
}
function speak(t) {
  const s = (t || '').trim();
  if (!s || !('speechSynthesis' in window)) return;
  try {
    speechSynthesis.cancel();
    const u = new SpeechSynthesisUtterance(s);
    u.lang = 'en-US';
    u.rate = 0.95;
    speechSynthesis.speak(u);
  } catch (e) { /* ignore */ }
}
function finalizeWord() {
  if (word) {
    text += word + ' ';
    if (autoSpeak) speak(word);
    word = '';
  }
}
function commit(cand) {
  if (cand.kind === 'phrase') {
    finalizeWord();
    text += cand.label + ' ';
    if (autoSpeak) speak(cand.label);
  } else {
    word += cand.token;
  }
  lastCommitted = cand.token;
  render();
}

// ── Recognition loop ──────────────────────────────────────────────────────────
function push(tok) {
  buffer.push(tok);
  if (buffer.length > BUFFER) buffer.shift();
}
function dominant() {
  const counts = new Map();
  for (const t of buffer) if (t) counts.set(t, (counts.get(t) || 0) + 1);
  let best = null, n = 0;
  for (const [t, c] of counts) if (c > n) { n = c; best = t; }
  return { token: best, share: n / BUFFER };
}

function onFrame() {
  if (!running) return;
  rafId = requestAnimationFrame(onFrame);
  if (busy || video.readyState < 2) return;
  busy = true;
  try {
    const res = landmarker.detectForVideo(video, performance.now());
    const hand = res.landmarks && res.landmarks[0];
    if (!hand) {
      // No hand in view.
      noHandFrames++;
      unrecFrames = 0;
      push(null);
      tokenEl.textContent = '·';
      if (noHandFrames === WORD_BREAK && (word || lastCommitted)) {
        finalizeWord();
        lastCommitted = null;
        render();
      }
    } else {
      noHandFrames = 0;
      const cand = classifyHand(hand, alphabet);
      if (!cand) {
        unrecFrames++;
        push(null);
        tokenEl.textContent = '…';
        if (unrecFrames >= 4) lastCommitted = null; // allow re-signing the same letter
      } else {
        unrecFrames = 0;
        push(cand.token);
        tokenEl.textContent = cand.kind === 'phrase' ? '🤟' : cand.token;
        const dom = dominant();
        if (dom.token === cand.token && dom.share >= COMMIT_SHARE && cand.token !== lastCommitted) {
          commit(cand);
        }
      }
    }
  } catch (e) {
    // transient inference hiccup — keep going
  } finally {
    busy = false;
  }
}

// ── Camera + model ─────────────────────────────────────────────────────────────
async function ensureModel() {
  if (landmarker) return;
  liveText.textContent = 'Loading…';
  const fileset = await FilesetResolver.forVisionTasks('vendor/wasm');
  landmarker = await HandLandmarker.createFromOptions(fileset, {
    baseOptions: { modelAssetPath: 'vendor/hand_landmarker.task' },
    numHands: 1,
    runningMode: 'VIDEO',
  });
}
async function startCamera() {
  errEl.textContent = '';
  try {
    await ensureModel();
    stream = await navigator.mediaDevices.getUserMedia({
      video: { facingMode: 'user', width: 640, height: 480 },
      audio: false,
    });
    video.srcObject = stream;
    await video.play();
    running = true;
    liveEl.classList.add('on');
    liveText.textContent = 'Reading your signs';
    $('camBtn').textContent = 'Stop camera';
    rafId = requestAnimationFrame(onFrame);
  } catch (e) {
    errEl.textContent = describeError(e);
    liveText.textContent = 'Camera off';
  }
}
function stopCamera() {
  running = false;
  cancelAnimationFrame(rafId);
  if (stream) stream.getTracks().forEach((t) => t.stop());
  stream = null;
  video.srcObject = null;
  liveEl.classList.remove('on');
  liveText.textContent = 'Camera off';
  tokenEl.textContent = '·';
  $('camBtn').textContent = 'Start camera';
}
function describeError(e) {
  const n = e && e.name;
  if (n === 'NotAllowedError') return 'Camera permission denied. Allow camera access and try again.';
  if (n === 'NotFoundError') return 'No camera found.';
  if (String(e).includes('vendor')) return 'Sign model missing. Run fetch-vendor.sh (see README).';
  return 'Could not start the camera or model. See the console for details.';
}

// ── Speech-to-text (what they say) ──────────────────────────────────────────────
let recog = null;
let listening = false;
function toggleListen() {
  const SR = window.SpeechRecognition || window.webkitSpeechRecognition;
  if (!SR) { capEl.textContent = 'Speech recognition is not available in this browser.'; return; }
  if (listening) { recog && recog.stop(); return; }
  recog = new SR();
  recog.continuous = true;
  recog.interimResults = true;
  recog.lang = 'en-US';
  let finalText = '';
  recog.onresult = (ev) => {
    let interim = '';
    for (let i = ev.resultIndex; i < ev.results.length; i++) {
      const r = ev.results[i];
      if (r.isFinal) finalText += r[0].transcript + ' ';
      else interim += r[0].transcript;
    }
    capEl.classList.remove('empty');
    capEl.textContent = (finalText + interim).trim() || '…';
  };
  recog.onend = () => {
    listening = false;
    $('listenBtn').classList.remove('on');
    $('listenBtn').textContent = '🎧 Listen to them';
  };
  recog.onerror = () => { /* onend will reset UI */ };
  recog.start();
  listening = true;
  $('listenBtn').classList.add('on');
  $('listenBtn').textContent = '⏹ Stop listening';
  capEl.classList.remove('empty');
  capEl.textContent = '…';
}

// ── Wire up UI ───────────────────────────────────────────────────────────────
$('camBtn').addEventListener('click', () => (running ? stopCamera() : startCamera()));
$('speakBtn').addEventListener('click', () => speak(text + word));
$('spaceBtn').addEventListener('click', () => { finalizeWord(); render(); });
$('backBtn').addEventListener('click', () => {
  if (word) word = word.slice(0, -1);
  else text = text.trimEnd().slice(0, -1);
  render();
});
$('clearBtn').addEventListener('click', () => { text = ''; word = ''; lastCommitted = null; render(); });
$('autoSpeak').addEventListener('click', (e) => {
  autoSpeak = !autoSpeak;
  e.currentTarget.classList.toggle('on', autoSpeak);
});
$('alpha').addEventListener('click', (e) => {
  const b = e.target.closest('button');
  if (!b) return;
  alphabet = b.dataset.a;
  [...e.currentTarget.children].forEach((c) => c.classList.toggle('on', c === b));
});
$('listenBtn').addEventListener('click', toggleListen);

// Phrase palette.
const phrasesEl = $('phrases');
for (const p of PHRASE_CATALOG) {
  const b = document.createElement('button');
  b.className = 'chip';
  b.textContent = p.text;
  b.addEventListener('click', () => {
    finalizeWord();
    text += p.text + ' ';
    if (autoSpeak) speak(p.text);
    render();
  });
  phrasesEl.appendChild(b);
}

render();
