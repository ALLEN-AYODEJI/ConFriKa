"""Sign-language recognition core.

ConFriKa's accessibility feature for Deaf and non-speaking users. Every client
(the mobile app's camera, the browser extension's MediaPipe-JS, a future
on-device model) produces the same thing — **hand landmarks** — and sends them
here; this module turns a short burst of landmark frames into a *sign token*
(a letter, a digit, or a curated phrase). One recognizer, many front-ends.

Design notes / honesty:
  * Hand landmarks follow the MediaPipe Hands layout: 21 points per hand,
    index 0 = wrist, 4 = thumb tip, 8 = index tip, 12 = middle tip,
    16 = ring tip, 20 = pinky tip (see ``_FINGER_TIPS``/``_FINGER_PIPS``).
  * The v1 recognizer (``GeometricAslRecognizer``) is **deterministic geometry**,
    not a trained model. It reliably separates the ASL fingerspelling letters
    and digits whose *static handshape* is geometrically distinct (how many
    fingers are extended + thumb position). Letters that differ only by subtle
    thumb placement or motion (M/N/S/T, J, Z) are intentionally NOT guessed —
    they collapse to their nearest separable neighbour at low confidence rather
    than inventing a confident wrong answer.
  * Full continuous sign-language *translation* (grammatical sentences, facial
    markers, spatial reference) is a different, unsolved problem. The
    ``SignRecognizer`` interface below is the seam where a learned TFLite/cloud
    model can be dropped in later as a labelled "beta" mode — exactly the
    stub→live pattern used for NLLB and the voice service.

No third-party dependency is added: the geometry is pure Python/stdlib ``math``.
"""
from __future__ import annotations

import math
from abc import ABC, abstractmethod
from collections import Counter
from typing import List, Optional

from pydantic import BaseModel, Field

# ── MediaPipe Hands landmark indices ────────────────────────────────────────
_WRIST = 0
_MIDDLE_MCP = 9  # used as the hand-size / palm-centre reference
_FINGER_TIPS = {"index": 8, "middle": 12, "ring": 16, "pinky": 20}
_FINGER_PIPS = {"index": 6, "middle": 10, "ring": 14, "pinky": 18}
_THUMB_TIP = 4
_THUMB_IP = 3
_INDEX_MCP = 5


# ── Wire models (shared by the mobile app and the browser extension) ─────────
class Landmark(BaseModel):
    x: float
    y: float
    z: float = 0.0


class SignFrame(BaseModel):
    """One video frame's worth of detected hands (0, 1, or 2 hands)."""

    hands: List[List[Landmark]] = Field(default_factory=list)


class RecognizeRequest(BaseModel):
    # A short burst of frames (e.g. ~0.3–1s of video). Recognising over a burst
    # instead of a single frame is what makes the result stable.
    frames: List[SignFrame] = Field(..., min_length=1, max_length=180)
    sign_language: str = "ASL"
    alphabet: str = "letters"  # 'letters' | 'digits'


class Candidate(BaseModel):
    token: str
    label: str
    confidence: float
    kind: str  # 'letter' | 'digit' | 'phrase'


class RecognizeResponse(BaseModel):
    token: Optional[str]  # best guess, or None when nothing reliable was seen
    label: str
    confidence: float
    kind: str  # 'letter' | 'digit' | 'phrase' | 'none'
    stable: bool  # True when the same token held across most of the burst
    candidates: List[Candidate]
    sign_language: str
    beta: bool = False
    note: Optional[str] = None


# ── Geometry helpers ─────────────────────────────────────────────────────────
def _dist(a: Landmark, b: Landmark) -> float:
    return math.sqrt((a.x - b.x) ** 2 + (a.y - b.y) ** 2 + (a.z - b.z) ** 2)


def _finger_extended(hand: List[Landmark], tip: int, pip: int, wrist: Landmark, scale: float) -> bool:
    """A finger is extended when its tip sits clearly farther from the wrist
    than its middle (PIP) joint. Using distance-from-wrist (not raw y) keeps
    this rotation-tolerant, so it holds whether the hand is upright or tilted."""
    if scale <= 1e-6:
        return False
    tip_d = _dist(hand[tip], wrist)
    pip_d = _dist(hand[pip], wrist)
    return (tip_d - pip_d) > 0.12 * scale


def _thumb_extended(hand: List[Landmark], wrist: Landmark, scale: float) -> bool:
    if scale <= 1e-6:
        return False
    # Thumb is "out" when the tip is both farther from the wrist than its IP
    # joint AND held away from the index knuckle (so a thumb folded across the
    # palm reads as tucked).
    farther = _dist(hand[_THUMB_TIP], wrist) - _dist(hand[_THUMB_IP], wrist) > 0.03 * scale
    away = _dist(hand[_THUMB_TIP], hand[_INDEX_MCP]) > 0.55 * scale
    return farther and away


# Extended-finger pattern → (letter, digit, confidence, kind-hint).
# The tuple is (thumb, index, middle, ring, pinky) as booleans. Confidence
# reflects how uniquely that handshape maps to the glyph; shapes that several
# ASL letters share are scored lower on purpose.
_PATTERNS = {
    #  T  I  M  R  P          letter  digit  conf
    (False, False, False, False, False): ("A", "0", 0.70),  # fist (also S/E/M/N/T)
    (True,  False, False, False, False): ("A", "10", 0.68),  # thumb out / thumbs-up
    (False, True,  False, False, False): ("D", "1", 0.90),  # index only
    (False, True,  True,  False, False): ("V", "2", 0.90),  # index+middle (V / "2")
    (True,  True,  True,  False, False): ("3", "3", 0.82),  # thumb+index+middle ("3")
    (False, True,  True,  True,  False): ("W", "3", 0.88),  # three fingers (W)
    (False, True,  True,  True,  True):  ("B", "4", 0.90),  # four fingers, thumb tucked
    (True,  True,  True,  True,  True):  ("5", "5", 0.92),  # open hand ("5" / B-with-thumb)
    (True,  True,  False, False, False): ("L", "L", 0.93),  # L shape
    (True,  False, False, False, True):  ("Y", "Y", 0.92),  # thumb + pinky (Y)
    (False, False, False, False, True):  ("I", "I", 0.90),  # pinky only
    (False, True,  False, False, True):  ("ILY", "ILY", 0.80),  # horns → handled as phrase
    (True,  True,  False, False, True):  ("ILY", "ILY", 0.90),  # I-Love-You handshape
}

# Curated phrase catalogue. ``auto`` marks the ones the geometric recognizer can
# spot on its own today; the rest are offered to clients as a tap-to-insert
# palette so a user is never stuck when a sign isn't auto-detected yet.
PHRASE_CATALOG = [
    {"token": "ILY", "gloss": "I-LOVE-YOU", "text": "I love you", "auto": True},
    {"token": "HELLO", "gloss": "HELLO", "text": "Hello", "auto": False},
    {"token": "THANK_YOU", "gloss": "THANK-YOU", "text": "Thank you", "auto": False},
    {"token": "YES", "gloss": "YES", "text": "Yes", "auto": False},
    {"token": "NO", "gloss": "NO", "text": "No", "auto": False},
    {"token": "PLEASE", "gloss": "PLEASE", "text": "Please", "auto": False},
    {"token": "SORRY", "gloss": "SORRY", "text": "Sorry", "auto": False},
    {"token": "HELP", "gloss": "HELP", "text": "Help", "auto": False},
    {"token": "STOP", "gloss": "STOP", "text": "Stop", "auto": False},
    {"token": "NAME", "gloss": "NAME", "text": "My name is", "auto": False},
    {"token": "WHERE", "gloss": "WHERE", "text": "Where", "auto": False},
    {"token": "HOW_MUCH", "gloss": "HOW-MUCH", "text": "How much", "auto": False},
    {"token": "WATER", "gloss": "WATER", "text": "Water", "auto": False},
    {"token": "FOOD", "gloss": "FOOD", "text": "Food", "auto": False},
]

SUPPORTED_SIGN_LANGUAGES = ["ASL"]


# ── Recognizer interface + v1 implementation ────────────────────────────────
class SignRecognizer(ABC):
    """Seam for swapping the recognition engine (geometric now, learned later)."""

    @abstractmethod
    def recognize(self, req: RecognizeRequest) -> RecognizeResponse: ...


class GeometricAslRecognizer(SignRecognizer):
    """Deterministic ASL fingerspelling/digit recognizer over hand landmarks."""

    def _classify_hand(self, hand: List[Landmark], alphabet: str) -> Optional[Candidate]:
        if len(hand) < 21:
            return None
        wrist = hand[_WRIST]
        scale = _dist(wrist, hand[_MIDDLE_MCP])
        if scale <= 1e-6:
            return None
        pattern = (
            _thumb_extended(hand, wrist, scale),
            _finger_extended(hand, _FINGER_TIPS["index"], _FINGER_PIPS["index"], wrist, scale),
            _finger_extended(hand, _FINGER_TIPS["middle"], _FINGER_PIPS["middle"], wrist, scale),
            _finger_extended(hand, _FINGER_TIPS["ring"], _FINGER_PIPS["ring"], wrist, scale),
            _finger_extended(hand, _FINGER_TIPS["pinky"], _FINGER_PIPS["pinky"], wrist, scale),
        )
        match = _PATTERNS.get(pattern)
        if match is None:
            return None
        letter, digit, conf = match
        if letter == "ILY":
            return Candidate(token="ILY", label="I love you", confidence=conf, kind="phrase")
        token = digit if alphabet == "digits" else letter
        kind = "digit" if alphabet == "digits" else "letter"
        return Candidate(token=token, label=token, confidence=conf, kind=kind)

    def recognize(self, req: RecognizeRequest) -> RecognizeResponse:
        if req.sign_language.upper() not in SUPPORTED_SIGN_LANGUAGES:
            return RecognizeResponse(
                token=None, label="", confidence=0.0, kind="none", stable=False,
                candidates=[], sign_language=req.sign_language, beta=True,
                note=f"{req.sign_language} is not supported yet; only {', '.join(SUPPORTED_SIGN_LANGUAGES)}.",
            )

        # Classify every frame's primary (first) hand, then vote. A token that
        # holds across most of the burst is "stable" and earns a confidence
        # boost; a flickering burst stays low-confidence.
        per_frame: List[Candidate] = []
        for frame in req.frames:
            if not frame.hands:
                continue
            cand = self._classify_hand(frame.hands[0], req.alphabet)
            if cand is not None:
                per_frame.append(cand)

        if not per_frame:
            return RecognizeResponse(
                token=None, label="", confidence=0.0, kind="none", stable=False,
                candidates=[], sign_language=req.sign_language,
                note="No recognizable handshape in this burst.",
            )

        counts = Counter(c.token for c in per_frame)
        total = len(per_frame)
        candidates: List[Candidate] = []
        for token, n in counts.most_common():
            sample = next(c for c in per_frame if c.token == token)
            share = n / total
            # Blend the handshape's intrinsic confidence with how consistently
            # it appeared across the burst.
            blended = round(0.5 * sample.confidence + 0.5 * share, 3)
            candidates.append(Candidate(token=token, label=sample.label,
                                        confidence=blended, kind=sample.kind))

        best = candidates[0]
        stable = (counts[best.token] / total) >= 0.6
        return RecognizeResponse(
            token=best.token, label=best.label, confidence=best.confidence,
            kind=best.kind, stable=stable, candidates=candidates[:4],
            sign_language=req.sign_language,
        )


# Module-level singleton (stateless; safe to share).
_recognizer: SignRecognizer = GeometricAslRecognizer()


def recognize(req: RecognizeRequest) -> RecognizeResponse:
    return _recognizer.recognize(req)
