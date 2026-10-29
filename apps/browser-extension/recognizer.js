// Geometric ASL recognizer — a faithful JS port of the backend
// GeometricAslRecognizer (backend/services/sign_service.py). It turns a burst of
// MediaPipe hand-landmark frames into a sign token (letter / digit / phrase),
// entirely on-device. Keeping the exact same geometry here means the browser
// extension and the app's backend agree on what a handshape means.
//
// MediaPipe Hands layout: 21 landmarks/hand, index 0 = wrist, 4 = thumb tip,
// 8/12/16/20 = finger tips, 6/10/14/18 = PIP joints, 9 = middle MCP (scale ref).

const WRIST = 0;
const MIDDLE_MCP = 9;
const INDEX_MCP = 5;
const THUMB_TIP = 4;
const THUMB_IP = 3;
const TIPS = { index: 8, middle: 12, ring: 16, pinky: 20 };
const PIPS = { index: 6, middle: 10, ring: 14, pinky: 18 };

// (thumb,index,middle,ring,pinky) extended-pattern → [letter, digit, confidence].
// Matches _PATTERNS in the backend exactly.
const PATTERNS = new Map([
  ['0,0,0,0,0', ['A', '0', 0.70]],
  ['1,0,0,0,0', ['A', '10', 0.68]],
  ['0,1,0,0,0', ['D', '1', 0.90]],
  ['0,1,1,0,0', ['V', '2', 0.90]],
  ['1,1,1,0,0', ['3', '3', 0.82]],
  ['0,1,1,1,0', ['W', '3', 0.88]],
  ['0,1,1,1,1', ['B', '4', 0.90]],
  ['1,1,1,1,1', ['5', '5', 0.92]],
  ['1,1,0,0,0', ['L', 'L', 0.93]],
  ['1,0,0,0,1', ['Y', 'Y', 0.92]],
  ['0,0,0,0,1', ['I', 'I', 0.90]],
  ['0,1,0,0,1', ['ILY', 'ILY', 0.80]],
  ['1,1,0,0,1', ['ILY', 'ILY', 0.90]],
]);

export const PHRASE_CATALOG = [
  { token: 'ILY', text: 'I love you', auto: true },
  { token: 'HELLO', text: 'Hello', auto: false },
  { token: 'THANK_YOU', text: 'Thank you', auto: false },
  { token: 'YES', text: 'Yes', auto: false },
  { token: 'NO', text: 'No', auto: false },
  { token: 'PLEASE', text: 'Please', auto: false },
  { token: 'SORRY', text: 'Sorry', auto: false },
  { token: 'HELP', text: 'Help', auto: false },
  { token: 'STOP', text: 'Stop', auto: false },
  { token: 'NAME', text: 'My name is', auto: false },
  { token: 'WHERE', text: 'Where', auto: false },
  { token: 'HOW_MUCH', text: 'How much', auto: false },
  { token: 'WATER', text: 'Water', auto: false },
  { token: 'FOOD', text: 'Food', auto: false },
];

function dist(a, b) {
  const dz = (a.z || 0) - (b.z || 0);
  return Math.sqrt((a.x - b.x) ** 2 + (a.y - b.y) ** 2 + dz * dz);
}

function fingerExtended(hand, tip, pip, wrist, scale) {
  if (scale <= 1e-6) return false;
  return dist(hand[tip], wrist) - dist(hand[pip], wrist) > 0.12 * scale;
}

function thumbExtended(hand, wrist, scale) {
  if (scale <= 1e-6) return false;
  const farther = dist(hand[THUMB_TIP], wrist) - dist(hand[THUMB_IP], wrist) > 0.03 * scale;
  const away = dist(hand[THUMB_TIP], hand[INDEX_MCP]) > 0.55 * scale;
  return farther && away;
}

// Classify a single hand (21 landmarks) → {token,label,confidence,kind} or null.
export function classifyHand(hand, alphabet = 'letters') {
  if (!hand || hand.length < 21) return null;
  const wrist = hand[WRIST];
  const scale = dist(wrist, hand[MIDDLE_MCP]);
  if (scale <= 1e-6) return null;
  const pat = [
    thumbExtended(hand, wrist, scale) ? 1 : 0,
    fingerExtended(hand, TIPS.index, PIPS.index, wrist, scale) ? 1 : 0,
    fingerExtended(hand, TIPS.middle, PIPS.middle, wrist, scale) ? 1 : 0,
    fingerExtended(hand, TIPS.ring, PIPS.ring, wrist, scale) ? 1 : 0,
    fingerExtended(hand, TIPS.pinky, PIPS.pinky, wrist, scale) ? 1 : 0,
  ].join(',');
  const match = PATTERNS.get(pat);
  if (!match) return null;
  const [letter, digit, conf] = match;
  if (letter === 'ILY') return { token: 'ILY', label: 'I love you', confidence: conf, kind: 'phrase' };
  const token = alphabet === 'digits' ? digit : letter;
  return { token, label: token, confidence: conf, kind: alphabet === 'digits' ? 'digit' : 'letter' };
}

// Vote a token across a burst of per-frame classifications (array of the objects
// returned by classifyHand, nulls skipped). Returns the best candidate with a
// blended confidence + a `stable` flag, or null when nothing was recognized.
export function voteBurst(perFrame, total) {
  const seen = perFrame.filter(Boolean);
  if (seen.length === 0) return null;
  const counts = new Map();
  for (const c of seen) counts.set(c.token, (counts.get(c.token) || 0) + 1);
  let best = null;
  let bestN = 0;
  for (const [token, n] of counts) {
    if (n > bestN) { bestN = n; best = token; }
  }
  const sample = seen.find((c) => c.token === best);
  const denom = total || seen.length;
  const share = bestN / denom;
  const blended = Math.round((0.5 * sample.confidence + 0.5 * Math.min(1, share)) * 1000) / 1000;
  return {
    token: best,
    label: sample.label,
    kind: sample.kind,
    confidence: blended,
    stable: bestN / seen.length >= 0.6,
  };
}
