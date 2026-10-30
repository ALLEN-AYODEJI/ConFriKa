import { HandLandmarker, HolisticLandmarker, FilesetResolver } from './vendor/vision_bundle.mjs';
import { classifyHand, PHRASE_CATALOG } from './recognizer.js';

const API_BASE = 'https://confrika-backend.fly.dev';
const EXT_VERSION = (chrome.runtime?.getManifest && chrome.runtime.getManifest().version) || '';

// ── DOM ──────────────────────────────────────────────────────────────────────
const $ = (id) => document.getElementById(id);
const video = $('video');
const liveEl = $('live');
const liveText = $('liveText');
const tokenEl = $('token');
const hintEl = $('hint');
const msgEl = $('msg');
const capEl = $('cap');
const errEl = $('err');

// ── State ─────────────────────────────────────────────────────────────────────
let handLandmarker = null;
let holisticLandmarker = null;
let stream = null;
let running = false;
let rafId = 0;
let busy = false;

let mode = 'spell';      // 'spell' (fingerspelling) | 'words' (trained model)
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
const WORD_BREAK = 12;   // frames with no hand → end the current fingerspelled word

// Word-mode (whole-sign) collection.
const wordFrames = [];        // buffered holistic frames for the current sign
let collecting = false;
let wordBusy = false;         // a recognize-word request is in flight
const WORD_MIN_FRAMES = 5;    // too-short bursts are ignored
const WORD_MAX_FRAMES = 150;  // ~5s cap at 30fps
const WORD_SEND_MAX = 64;     // downsample before sending (model resamples anyway)
const WORD_BREAK_W = 7;       // frames with no hands → the sign is finished
const WORD_SPEAK_MIN = 0.35;  // speak the top word at/above this confidence
const WORD_SHOW_MIN = 0.12;   // below this, treat as "nothing recognized"

// ── Voices ────────────────────────────────────────────────────────────────────
let voices = [];
let voiceFilter = 'any';
let selectedVoiceURI = '';
const voiceSel = $('voiceSel');

const AFRICAN_LANG_BASES = ['af', 'zu', 'xh', 'st', 'tn', 'ts', 'ss', 'nr', 've', 'nso',
  'sw', 'am', 'ha', 'yo', 'ig', 'so', 'rw', 'rn', 'sn', 'ny', 'lg', 'om', 'ti', 'wo',
  'ff', 'kg', 'ln', 'mg', 'sg', 'aa', 'ber', 'kab'];
const AFRICAN_REGIONS = ['ZA', 'NG', 'KE', 'GH', 'TZ', 'UG', 'ZW', 'ET', 'SN', 'CI', 'CM',
  'CD', 'ML', 'EG', 'MA', 'DZ', 'TN', 'LY', 'AO', 'MZ', 'RW', 'SO', 'BF', 'BJ', 'BW',
  'ZM', 'MW', 'NA', 'SD', 'NE', 'TD', 'GN', 'SL', 'LR', 'TG'];
const AFRICAN_NAME_RE = /africa|zulu|xhosa|afrikaans|swahili|amharic|hausa|yoruba|igbo|nigeria|kenya|ghana|ethiop|somali|tswana|sotho/i;
const FEMALE_RE = /female|woman|\bzira\b|samantha|victoria|karen|moira|tessa|fiona|amelie|anna|aria|jenny|michelle|libby|sonia|catherine|serena|google (uk|us) english female|female\b/i;
const MALE_RE = /\bmale\b|\bman\b|david|daniel|\balex\b|fred|rishi|george|ryan|\bguy\b|eric|arthur|thabo|google (uk|us) english male/i;

function voiceLang(v) { return (v.lang || '').replace('_', '-'); }
function isAfricanVoice(v) {
  const l = voiceLang(v);
  const base = l.split('-')[0].toLowerCase();
  const region = (l.split('-')[1] || '').toUpperCase();
  return AFRICAN_LANG_BASES.includes(base) || AFRICAN_REGIONS.includes(region)
    || AFRICAN_NAME_RE.test(v.name || '');
}
function voiceGender(v) {
  const n = (v.name || '').toLowerCase();
  if (FEMALE_RE.test(n)) return 'female';
  if (MALE_RE.test(n)) return 'male';
  return 'unknown';
}
function matchesFilter(v) {
  if (voiceFilter === 'any') return true;
  if (voiceFilter === 'african') return isAfricanVoice(v);
  return voiceGender(v) === voiceFilter;
}
function selectedVoice() {
  return voices.find((v) => v.voiceURI === selectedVoiceURI) || null;
}
function populateVoiceOptions() {
  if (!voiceSel) return;
  let list = voices.filter(matchesFilter);
  let note = '';
  if (list.length === 0) { list = voices.slice(); note = ' (none matched — showing all)'; }
  // Keep the current selection if still visible; otherwise pick the first.
  if (!list.some((v) => v.voiceURI === selectedVoiceURI)) {
    selectedVoiceURI = list.length ? list[0].voiceURI : '';
  }
  voiceSel.innerHTML = '';
  if (list.length === 0) {
    const o = document.createElement('option');
    o.textContent = 'No voices available in this browser';
    o.disabled = true;
    voiceSel.appendChild(o);
    return;
  }
  for (const v of list) {
    const o = document.createElement('option');
    o.value = v.voiceURI;
    o.textContent = `${v.name} · ${voiceLang(v)}`;
    if (v.voiceURI === selectedVoiceURI) o.selected = true;
    voiceSel.appendChild(o);
  }
  if (note) voiceSel.options[0].textContent += note;
  try { localStorage.setItem('cf_vfilter', voiceFilter); } catch (e) { /* ignore */ }
}
function loadVoices() {
  if (!('speechSynthesis' in window)) return;
  voices = speechSynthesis.getVoices() || [];
  if (!voices.length) return;
  try {
    const savedFilter = localStorage.getItem('cf_vfilter');
    if (savedFilter) voiceFilter = savedFilter;
    const savedURI = localStorage.getItem('cf_voiceURI');
    if (savedURI && voices.some((v) => v.voiceURI === savedURI)) selectedVoiceURI = savedURI;
  } catch (e) { /* ignore */ }
  // Reflect the saved filter in the segmented control.
  const vfilter = $('vfilter');
  if (vfilter) [...vfilter.children].forEach((b) => b.classList.toggle('on', b.dataset.v === voiceFilter));
  if (!selectedVoiceURI) {
    const en = voices.find((v) => /^en/i.test(voiceLang(v)));
    selectedVoiceURI = (en || voices[0]).voiceURI;
  }
  populateVoiceOptions();
}

// ── Message helpers ─────────────────────────────────────────────────────────
function render() {
  const full = (text + word).replace(/\s+$/, '');
  msgEl.textContent = full || (mode === 'words'
    ? 'Start the camera and sign a word…'
    : 'Start the camera and sign…');
  msgEl.classList.toggle('empty', full.length === 0);
}
function speak(t) {
  const s = (t || '').trim();
  if (!s || !('speechSynthesis' in window)) return;
  try {
    speechSynthesis.cancel();
    const u = new SpeechSynthesisUtterance(s);
    const v = selectedVoice();
    if (v) { u.voice = v; u.lang = v.lang; } else { u.lang = 'en-US'; }
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
function commitWord(label) {
  const w = (label || '').trim();
  if (!w) return;
  finalizeWord();
  text += w + ' ';
  render();
  if (autoSpeak) speak(w);
}

// ── Fingerspelling recognition ────────────────────────────────────────────────
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
function spellFrame() {
  const res = handLandmarker.detectForVideo(video, performance.now());
  const hand = res.landmarks && res.landmarks[0];
  if (!hand) {
    noHandFrames++;
    unrecFrames = 0;
    push(null);
    tokenEl.textContent = '·';
    if (noHandFrames === WORD_BREAK && (word || lastCommitted)) {
      finalizeWord();
      lastCommitted = null;
      render();
    }
    return;
  }
  noHandFrames = 0;
  const cand = classifyHand(hand, alphabet);
  if (!cand) {
    unrecFrames++;
    push(null);
    tokenEl.textContent = '…';
    if (unrecFrames >= 4) lastCommitted = null;
    return;
  }
  unrecFrames = 0;
  push(cand.token);
  tokenEl.textContent = cand.kind === 'phrase' ? '🤟' : cand.token;
  const dom = dominant();
  if (dom.token === cand.token && dom.share >= COMMIT_SHARE && cand.token !== lastCommitted) {
    commit(cand);
  }
}

// ── Whole-word recognition (holistic landmarks → backend model) ────────────────
function flattenPart(arr) {
  // tasks-vision may return NormalizedLandmark[] or NormalizedLandmark[][].
  if (!Array.isArray(arr) || arr.length === 0) return [];
  return Array.isArray(arr[0]) ? arr[0] : arr;
}
function toLm(p) { return { x: p.x, y: p.y, z: (p.z || 0) }; }

function wordsFrame() {
  if (!holisticLandmarker) { tokenEl.textContent = '…'; return; }
  const res = holisticLandmarker.detectForVideo(video, performance.now());
  const face = flattenPart(res.faceLandmarks).slice(0, 468);
  const pose = flattenPart(res.poseLandmarks);
  const left = flattenPart(res.leftHandLandmarks);
  const right = flattenPart(res.rightHandLandmarks);
  const handsPresent = left.length > 0 || right.length > 0;

  if (handsPresent) {
    noHandFrames = 0;
    collecting = true;
    wordFrames.push({
      face: face.map(toLm),
      pose: pose.map(toLm),
      left_hand: left.map(toLm),
      right_hand: right.map(toLm),
    });
    if (wordFrames.length > WORD_MAX_FRAMES) wordFrames.shift();
    tokenEl.textContent = '●';
    hintEl.textContent = `Reading your sign… (${wordFrames.length})`;
    return;
  }

  // No hands in view.
  tokenEl.textContent = wordBusy ? '…' : '·';
  if (collecting) {
    noHandFrames++;
    if (noHandFrames >= WORD_BREAK_W) {
      collecting = false;
      if (wordFrames.length >= WORD_MIN_FRAMES && !wordBusy) {
        sendWord(wordFrames.splice(0, wordFrames.length));
      } else {
        wordFrames.length = 0;
      }
    }
  }
}

function downsample(frames, max) {
  if (frames.length <= max) return frames;
  const step = frames.length / max;
  const out = [];
  for (let i = 0; i < max; i++) out.push(frames[Math.floor(i * step)]);
  return out;
}

async function sendWord(frames) {
  wordBusy = true;
  hintEl.textContent = 'Recognizing…';
  tokenEl.textContent = '…';
  try {
    const payload = { frames: downsample(frames, WORD_SEND_MAX), sign_language: 'ASL', top_k: 3 };
    const r = await fetch(`${API_BASE}/api/v1/sign/recognize-word`, {
      method: 'POST',
      headers: authHeaders(),
      body: JSON.stringify(payload),
    });
    if (!r.ok) throw new Error(`HTTP ${r.status}`);
    const out = await r.json();
    extEvent('recognize'); // count a word-recognition use (attributed if signed in)
    const conf = (out && typeof out.confidence === 'number') ? out.confidence : 0;
    if (out && out.token && conf >= WORD_SPEAK_MIN) {
      // Confident enough — insert + speak it.
      tokenEl.textContent = '🤟';
      commitWord(out.label || out.token);
      hintEl.textContent = `“${out.label}” · ${Math.round(conf * 100)}%`;
    } else if (out && out.token && conf >= WORD_SHOW_MIN) {
      // Uncertain — show the best guesses but don't speak a likely-wrong word.
      tokenEl.textContent = '🤔';
      const alts = (out.candidates || []).slice(0, 3).map((c) => c.label).join(', ');
      hintEl.textContent = `Maybe: ${alts || out.label}. Sign again, bigger and centered.`;
    } else {
      tokenEl.textContent = '·';
      hintEl.textContent = (out && out.note) || 'No sign recognized — stand back so your hands + face show, then sign.';
    }
  } catch (e) {
    console.warn('ConFriKa Sign: recognize-word failed —', e);
    hintEl.textContent = 'Could not reach the sign recognizer. Check your connection.';
  } finally {
    wordBusy = false;
    noHandFrames = 0;
  }
}

// ── Main loop ──────────────────────────────────────────────────────────────────
function onFrame() {
  if (!running) return;
  rafId = requestAnimationFrame(onFrame);
  if (busy || video.readyState < 2) return;
  busy = true;
  try {
    if (mode === 'words') wordsFrame();
    else spellFrame();
  } catch (e) {
    // transient inference hiccup — keep going
  } finally {
    busy = false;
  }
}

// ── Camera + models ─────────────────────────────────────────────────────────────
async function ensureFileset() {
  if (!ensureFileset._fs) ensureFileset._fs = await FilesetResolver.forVisionTasks('vendor/wasm');
  return ensureFileset._fs;
}
async function ensureHandModel() {
  if (handLandmarker) return;
  liveText.textContent = 'Loading…';
  const fileset = await ensureFileset();
  handLandmarker = await HandLandmarker.createFromOptions(fileset, {
    baseOptions: { modelAssetPath: 'vendor/hand_landmarker.task' },
    numHands: 1,
    runningMode: 'VIDEO',
  });
}
async function ensureHolisticModel() {
  if (holisticLandmarker) return;
  liveText.textContent = 'Loading word model…';
  const fileset = await ensureFileset();
  holisticLandmarker = await HolisticLandmarker.createFromOptions(fileset, {
    baseOptions: { modelAssetPath: 'vendor/holistic_landmarker.task' },
    runningMode: 'VIDEO',
    // Lower detection/presence thresholds so hands are picked up more readily
    // (default 0.5 drops a lot of real signing frames).
    minFaceDetectionConfidence: 0.3,
    minPoseDetectionConfidence: 0.3,
    minHandLandmarksConfidence: 0.3,
  });
}
async function ensureModel() {
  if (mode === 'words') await ensureHolisticModel();
  else await ensureHandModel();
}

const CAM_CONSTRAINTS = { video: { facingMode: 'user', width: 640, height: 480 }, audio: false };

// Open the permission-bridge popup and resolve once the camera has been granted
// (or the window is closed). Returns true if a grant message was received.
function requestCameraViaWindow() {
  return new Promise((resolve) => {
    let settled = false;
    const done = (ok) => { if (settled) return; settled = true; chrome.runtime.onMessage.removeListener(onMsg); resolve(ok); };
    function onMsg(m) {
      if (m && m.type === 'cf-camera-granted') done(true);
      else if (m && m.type === 'cf-camera-denied') done(false);
    }
    chrome.runtime.onMessage.addListener(onMsg);
    try {
      chrome.windows.create(
        { url: chrome.runtime.getURL('permission.html'), type: 'popup', width: 420, height: 320 },
        (win) => {
          if (chrome.runtime.lastError || !win) { done(false); return; }
          const id = win.id;
          const check = setInterval(() => {
            chrome.windows.get(id, () => {
              if (chrome.runtime.lastError) { clearInterval(check); done(false); }
            });
          }, 700);
        },
      );
    } catch (e) { done(false); }
  });
}

async function openCamera() {
  stream = await navigator.mediaDevices.getUserMedia(CAM_CONSTRAINTS);
  video.srcObject = stream;
  await video.play();
}

async function startCamera() {
  errEl.textContent = '';
  liveText.textContent = 'Starting…';
  try {
    await ensureModel();
    try {
      await openCamera();
    } catch (e1) {
      if (e1 && (e1.name === 'NotAllowedError' || e1.name === 'NotReadableError' || e1.name === 'NotFoundError')) {
        console.warn('ConFriKa Sign: direct getUserMedia failed, trying permission window —', e1);
        liveText.textContent = 'Allow camera in the pop-up…';
        const granted = await requestCameraViaWindow();
        if (!granted) throw e1;
        await openCamera();
      } else {
        throw e1;
      }
    }
    running = true;
    liveEl.classList.add('on');
    liveText.textContent = mode === 'words' ? 'Reading whole signs' : 'Reading your signs';
    $('camBtn').textContent = 'Stop camera';
    rafId = requestAnimationFrame(onFrame);
  } catch (e) {
    console.error('ConFriKa Sign: startCamera failed —', e);
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
  collecting = false;
  wordFrames.length = 0;
  $('camBtn').textContent = 'Start camera';
}
function describeError(e) {
  const n = e && e.name;
  const detail = (e && e.message) ? ` (${e.message})` : '';
  if (n === 'NotAllowedError') return 'Camera blocked. Click the camera icon in the address bar (or chrome://settings/content/camera), allow it, then press Start again.';
  if (n === 'NotFoundError') return 'No camera found. Plug in a webcam and try again.';
  if (n === 'NotReadableError') return 'The camera is in use by another app (e.g. the call itself). Close it there and retry.';
  if (String(e).includes('vendor') || String(e).includes('wasm') || String(e).includes('.task')) {
    return 'Sign model failed to load. Reinstall the extension or run fetch-vendor.sh (see README).';
  }
  return `Could not start the camera or model${detail}. See the console for details.`;
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

// ── Typing (for users who prefer to type) ──────────────────────────────────────
function addTyped() {
  const box = $('typeBox');
  const v = (box.value || '').trim();
  if (!v) return;
  commitWord(v);
  box.value = '';
  box.focus();
}

// ── Mode switching ──────────────────────────────────────────────────────────────
function setModeHint() {
  hintEl.textContent = mode === 'words'
    ? 'Stand back so your head + both hands show. Sign one word clearly, then lower your hands. (beta · 250 ASL signs)'
    : 'Sign a letter and hold briefly. Lower your hand to end a word.';
  $('alpha').style.display = mode === 'words' ? 'none' : '';
}
async function setMode(next) {
  if (next === mode) return;
  mode = next;
  // Reset per-mode state so one mode's buffers don't leak into the other.
  buffer.length = 0; wordFrames.length = 0;
  word = ''; lastCommitted = null; collecting = false; noHandFrames = 0; unrecFrames = 0;
  setModeHint();
  render();
  if (running) {
    try {
      await ensureModel();
      liveText.textContent = mode === 'words' ? 'Reading whole signs' : 'Reading your signs';
    } catch (e) {
      errEl.textContent = describeError(e);
    }
  }
}

// ── Account + install tracking ─────────────────────────────────────────────
// A stable per-install id lets the admin count installs; signing in attaches
// the usage to the user's account. Sign-in is optional — signing stays usable
// logged-out (accessibility).
let installId = null;
let authToken = null;
let authEmail = null;

const storageGet = (keys) => new Promise((res) => {
  try { chrome.storage.local.get(keys, res); } catch (e) { res({}); }
});
const storageSet = (obj) => new Promise((res) => {
  try { chrome.storage.local.set(obj, res); } catch (e) { res(); }
});

function authHeaders(extra) {
  const h = Object.assign({ 'Content-Type': 'application/json' }, extra || {});
  if (authToken) h['Authorization'] = `Bearer ${authToken}`;
  return h;
}

async function extEvent(event) {
  if (!installId) return;
  try {
    await fetch(`${API_BASE}/api/v1/metrics/ext`, {
      method: 'POST', headers: authHeaders(), keepalive: true,
      body: JSON.stringify({ install_id: installId, event, version: EXT_VERSION }),
    });
  } catch (e) { /* fire-and-forget */ }
}

function renderAccount() {
  const info = $('acctInfo');
  if (authEmail) {
    info.textContent = `Signed in · ${authEmail}`;
    $('signInBtn').hidden = true;
    $('signOutBtn').hidden = false;
  } else {
    info.textContent = 'Not signed in';
    $('signInBtn').hidden = false;
    $('signOutBtn').hidden = true;
  }
}

async function doLogin() {
  const email = $('loginEmail').value.trim();
  const pass = $('loginPass').value;
  const le = $('loginErr');
  le.textContent = '';
  if (!email || !pass) { le.textContent = 'Enter your email and password.'; return; }
  $('loginSubmit').disabled = true;
  try {
    const r = await fetch(`${API_BASE}/api/v1/auth/login`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ email_or_username: email, password: pass }),
    });
    if (!r.ok) {
      const j = await r.json().catch(() => ({}));
      throw new Error(j.detail || `Sign-in failed (${r.status})`);
    }
    const data = await r.json();
    authToken = data.access_token;
    authEmail = (data.user && data.user.email) || email;
    await storageSet({ cf_token: authToken, cf_email: authEmail });
    $('login').hidden = true;
    $('loginPass').value = '';
    renderAccount();
    extEvent('open'); // re-report so this install is now attributed to the user
  } catch (e) {
    le.textContent = e.message || 'Sign-in failed.';
  } finally {
    $('loginSubmit').disabled = false;
  }
}

function doLogout() {
  authToken = null;
  authEmail = null;
  storageSet({ cf_token: '', cf_email: '' });
  renderAccount();
}

async function initAccount() {
  const st = await storageGet(['cf_install_id', 'cf_token', 'cf_email']);
  installId = st.cf_install_id || null;
  let firstRun = false;
  if (!installId) {
    installId = (self.crypto?.randomUUID && self.crypto.randomUUID())
      || `${Date.now()}-${Math.random().toString(16).slice(2)}`;
    await storageSet({ cf_install_id: installId });
    firstRun = true;
  }
  authToken = st.cf_token || null;
  authEmail = st.cf_email || null;
  renderAccount();
  if (firstRun) extEvent('register');
  // One "open" per browser session.
  let newSession = true;
  try {
    if (sessionStorage.getItem('cf_ext_open')) newSession = false;
    else sessionStorage.setItem('cf_ext_open', '1');
  } catch (e) { /* ignore */ }
  if (newSession) extEvent('open');
}

// ── Wire up UI ───────────────────────────────────────────────────────────────
$('signInBtn').addEventListener('click', () => { $('login').hidden = false; $('loginEmail').focus(); });
$('signOutBtn').addEventListener('click', doLogout);
$('loginSubmit').addEventListener('click', doLogin);
$('loginCancel').addEventListener('click', () => { $('login').hidden = true; $('loginErr').textContent = ''; });
$('loginPass').addEventListener('keydown', (e) => { if (e.key === 'Enter') { e.preventDefault(); doLogin(); } });
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
$('mode').addEventListener('click', (e) => {
  const b = e.target.closest('button');
  if (!b) return;
  [...e.currentTarget.children].forEach((c) => c.classList.toggle('on', c === b));
  setMode(b.dataset.m);
});
$('vfilter').addEventListener('click', (e) => {
  const b = e.target.closest('button');
  if (!b) return;
  voiceFilter = b.dataset.v;
  [...e.currentTarget.children].forEach((c) => c.classList.toggle('on', c === b));
  populateVoiceOptions();
});
voiceSel.addEventListener('change', () => {
  selectedVoiceURI = voiceSel.value;
  try { localStorage.setItem('cf_voiceURI', selectedVoiceURI); } catch (e) { /* ignore */ }
});
$('listenBtn').addEventListener('click', toggleListen);
$('typeAdd').addEventListener('click', addTyped);
$('typeBox').addEventListener('keydown', (e) => { if (e.key === 'Enter') { e.preventDefault(); addTyped(); } });

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

// Voices load asynchronously in most browsers.
if ('speechSynthesis' in window) {
  loadVoices();
  speechSynthesis.addEventListener('voiceschanged', loadVoices);
}
setModeHint();
render();
initAccount();
